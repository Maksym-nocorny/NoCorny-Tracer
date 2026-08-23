import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Coordinates the full recording lifecycle: screen capture + audio + writing to file
@Observable
final class RecordingManager {
    // MARK: - State
    var isRecording = false
    var isPaused = false
    /// Capture is over, but the take is still being written: the system-audio sidecar is
    /// being mixed into the file, which on a two-hour recording is minutes of export.
    ///
    /// It exists because `isRecording` goes false first, on purpose, so the UI stops showing
    /// a frozen timer - and that left a window where the app looked completely idle while a
    /// recording was still being assembled. Quitting there is the natural thing to do after a
    /// meeting.
    var isFinishing = false
    var recordingDuration: TimeInterval = 0
    var currentFileURL: URL?
    
    // MARK: - Internal Timing
    private var accumulatedDuration: TimeInterval = 0
    private var lastStartTime: Date?


    // MARK: - Sub-managers
    let screenRecorder = ScreenRecorder()
    let audioCaptureManager = AudioCaptureManager()

    // MARK: - Private
    private var videoWriter: VideoWriter?
    /// Opt-in sidecar for system audio. Nil for every recording that did not ask for it,
    /// and nil again the moment anything on that path goes wrong.
    private var systemAudioWriter: SystemAudioWriter?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    /// Set synchronously before the first await in startRecording so a double
    /// trigger during the async start can't launch a second concurrent capture.
    private var isStarting = false
    /// Guards togglePause against re-entrancy across its 0.5s resume sleep.
    private var isTogglingPause = false

    /// Optional hook fired when a recording is force-stopped because the screen
    /// stream failed mid-capture. Lets AppState surface the failure / keep the
    /// partial file. Set by the owner.
    var onInterrupted: ((Recording?) -> Void)?

    /// Optional hook fired when the writer dies mid-recording. This is now a rare,
    /// defensive path: the periodic movie-fragment flush that used to fail with
    /// MovieHeaderMaker err -16341 (and killed recordings mid-take) has been removed
    /// (see VideoWriter.startWriting), so a live writer should no longer flip to
    /// .failed on its own. If it still dies for another reason (disk full, encoder
    /// malfunction), the owner stops the recording — stopRecording attempts a
    /// best-effort salvage of whatever finalized — and may restart.
    var onWriterFailed: (() -> Void)?

    // MARK: - Start Recording

    @MainActor
    func startRecording(
        microphoneEnabled: Bool,
        microphoneDeviceID: String?,
        reduceBackgroundNoise: Bool = false,
        recordSystemAudio: Bool = false,
        videoWidth: Int = 1920,
        videoHeight: Int = 1080,
        fps: Int = 30,
        startMaskDelay: UInt64 = 0
    ) async throws {
        // Reentrancy guard: isRecording is only set true after several awaits, so a
        // double trigger within that window used to start two concurrent captures +
        // writers and leak the first. isStarting closes the window synchronously.
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        // Request permissions
        let hasPermission = await screenRecorder.requestPermission()
        guard hasPermission else {
            throw ScreenRecorderError.permissionDenied
        }

        // Generate output file path
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "NoCornyTracer_\(formatter.string(from: Date())).mp4"
        let outputURL = AppState.recordingsDirectory.appendingPathComponent(fileName)
        currentFileURL = outputURL

        do {
            // Start screen capture first — returns the actual output size (matched to display aspect ratio)
            let actualSize = try await screenRecorder.startCapture(
                width: videoWidth,
                height: videoHeight,
                fps: fps,
                captureSystemAudio: recordSystemAudio
            )

            // Create video writer sized to the capture output so frames aren't letterboxed.
            let writer = VideoWriter(
                outputURL: outputURL,
                videoWidth: actualSize.width,
                videoHeight: actualSize.height,
                fps: fps
            )
            try writer.startWriting()
            videoWriter = writer

            // A writer that dies mid-recording would otherwise keep "recording"
            // while silently dropping every frame until the user hits stop.
            writer.onFailure = { [weak self, weak writer] error in
                LogManager.shared.log("🔴 Recording: writer failed mid-recording — \(VideoWriter.describeError(error))", type: .error)
                Task { @MainActor in
                    guard let self, self.isRecording, self.videoWriter === writer else { return }
                    self.onWriterFailed?()
                }
            }

            // Pause gating now lives inside VideoWriter (on its writing queue), so the
            // callbacks just forward — no unsynchronized cross-thread isPaused read.
            screenRecorder.onVideoSampleBuffer = { [weak writer] sampleBuffer in
                writer?.appendVideoBuffer(sampleBuffer)
            }
            // If ScreenCaptureKit kills the stream mid-recording (display unplugged,
            // permission revoked), stop instead of "recording" a frozen stream.
            screenRecorder.onStreamError = { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    LogManager.shared.log("🔴 Recording: screen stream error — stopping. \(error.localizedDescription)", type: .error)
                    let interrupted = await self.stopRecording(playSound: false)
                    self.onInterrupted?(interrupted)
                }
            }

            // System audio, when the user opted in and the stream agreed to deliver it.
            // Everything about this block is best-effort: a sidecar that refuses to open,
            // or a stream that never sends a buffer, leaves exactly the mic-only recording
            // the app made before this feature existed.
            if recordSystemAudio && screenRecorder.isCapturingSystemAudio {
                let sidecar = SystemAudioWriter(outputURL: SystemAudioWriter.sidecarURL(for: outputURL))
                do {
                    try sidecar.startWriting()
                    systemAudioWriter = sidecar
                    screenRecorder.onSystemAudioSampleBuffer = { [weak writer, weak sidecar] sampleBuffer in
                        guard let writer, let sidecar else { return }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        // The video writer owns the timeline; the sidecar only ever writes
                        // where it is told to, so the two files cannot drift apart.
                        guard let timing = writer.systemAudioTimeline(for: pts) else { return }
                        sidecar.append(sampleBuffer, presentationTime: timing.presentationTime, anchor: timing.anchor)
                    }
                    LogManager.shared.log("🔊 System audio: capturing to sidecar \(SystemAudioWriter.sidecarURL(for: outputURL).lastPathComponent)")
                } catch {
                    sidecar.cancel()
                    systemAudioWriter = nil
                    LogManager.shared.log("🔊 System audio: sidecar could not be opened (\(error.localizedDescription)) - recording the microphone only", type: .error)
                }
            }

            // Start microphone if enabled
            if microphoneEnabled {
                audioCaptureManager.refreshDevices()
                if let deviceID = microphoneDeviceID {
                    audioCaptureManager.selectDevice(id: deviceID)
                }
                audioCaptureManager.onAudioSampleBuffer = { [weak writer] sampleBuffer in
                    writer?.appendAudioBuffer(sampleBuffer)
                }
                try audioCaptureManager.startCapture(reduceBackgroundNoise: reduceBackgroundNoise)
            }
        } catch {
            // Rollback a partially-started recording: otherwise a running SCStream,
            // an open writer, and a stranded partial .mp4 leak with no way to stop
            // them (isRecording was never set, so the UI shows "Start").
            await screenRecorder.stopCapture()
            audioCaptureManager.stopCapture()
            screenRecorder.onVideoSampleBuffer = nil
            screenRecorder.onStreamError = nil
            screenRecorder.onSystemAudioSampleBuffer = nil
            audioCaptureManager.onAudioSampleBuffer = nil
            systemAudioWriter?.cancel()
            systemAudioWriter = nil
            videoWriter?.cancelWriting()
            videoWriter = nil
            currentFileURL = nil
            throw error
        }

        // Pre-roll: screen capture and the mic are now running, but the writer is NOT armed yet,
        // so everything captured so far — the start sound and the mic's voice-processing warm-up —
        // is discarded. Wait for the sound to finish and the mic to fully spin up, THEN arm, so the
        // recording begins with the microphone already capturing and the first words aren't clipped.
        if startMaskDelay > 0 {
            try? await Task.sleep(nanoseconds: startMaskDelay)
        }
        videoWriter?.arm()

        // Start duration timer
        isRecording = true
        isPaused = false
        recordingDuration = 0
        accumulatedDuration = 0
        lastStartTime = Date()
        recordingStartTime = lastStartTime
        startTimer()

        LogManager.shared.log("🔴 Recording Actually Started", type: .info)
    }


    // MARK: - Stop Recording

    /// - Parameter mergeSystemAudio: false when the caller is about to throw the file
    ///   away (abort), so a discarded take does not pay for an export first.
    /// - Parameter onCaptureFinished: called with the take as soon as the file is finalised,
    ///   BEFORE the system-audio merge. The caller persists it there, so a take being mixed
    ///   is already a row on disk rather than a value in flight that dies with the process.
    @MainActor
    func stopRecording(
        playSound: Bool = true,
        mergeSystemAudio: Bool = true,
        onCaptureFinished: ((Recording) -> Void)? = nil
    ) async -> Recording? {
        guard isRecording else { return nil }

        // Stop timer
        stopTimer()

        // Stop captures
        await screenRecorder.stopCapture()
        audioCaptureManager.stopCapture()
        screenRecorder.onSystemAudioSampleBuffer = nil

        // Close the sidecar before touching the MP4, so both paths below (normal finish
        // and salvage) get a finished file rather than a half-written one.
        let systemAudio = await systemAudioWriter?.finish()
        systemAudioWriter = nil

        // Finalize file
        guard let outputURL = await videoWriter?.stopWriting() else {
            // Writer produced no file (disk full / encode error / a rare writer death
            // now that the periodic fragment flush is gone). Reset ALL state so we
            // don't leave a phantom recording or strand isPaused=true (which would drop
            // the next recording's first frames) — but do NOT delete the partial: try a
            // best-effort salvage first. Without movie fragments an interrupted file is
            // usually unreadable (no moov), so this typically returns nil, but a file
            // that did finalize enough to play is still recovered rather than dropped.
            let partialURL = currentFileURL
            let startedAt = recordingStartTime
            isRecording = false
            isPaused = false
            recordingDuration = 0
            accumulatedDuration = 0
            lastStartTime = nil
            videoWriter = nil
            currentFileURL = nil
            var salvaged = await salvagePartialRecording(at: partialURL, startedAt: startedAt)
            // No merge onto a salvaged partial - it is already damaged goods and the swap
            // is the one step that could lose it. The sidecar is still handed over.
            salvaged?.systemAudioURL = systemAudio?.url
            return salvaged
        }

        let finalDuration = lastStartTime != nil ? accumulatedDuration + Date().timeIntervalSince(lastStartTime!) : accumulatedDuration
        let startedAt = recordingStartTime ?? Date()

        // Clear live state BEFORE the merge below. The capture is over either way, and an
        // export that runs for a minute on a long take would otherwise leave the UI sitting
        // in "recording" with a frozen timer - a stop that looks like it did not work. It
        // also pins the values this take needs (start time, output URL) into locals, so a
        // recording started while the merge runs cannot rewrite them underneath us.
        isRecording = false
        isPaused = false
        recordingDuration = 0
        accumulatedDuration = 0
        lastStartTime = nil
        videoWriter = nil
        currentFileURL = nil

        // Play stop sound
        if playSound {
            SoundManager.shared.play(.stop)
        }

        var recording = Recording(
            fileURL: outputURL,
            createdAt: startedAt,
            duration: finalDuration
        )
        // TODO: speaker separation will consume this track - "me" (the MP4's mic track)
        // against "everyone else" (this file) is a much stronger split than diarizing one
        // mixed mic. Nothing cleans it up yet, on purpose.
        recording.systemAudioURL = systemAudio?.url

        // Hand the take over NOW, before the merge. The file on disk is already complete and
        // playable; the merge only ever improves it, and it leaves the original untouched
        // when it fails. Persisting first is what makes the next few minutes survivable: the
        // row exists, the list shows it, and a quit in the middle costs the system-audio
        // mix rather than the whole recording.
        onCaptureFinished?(recording)

        // Mix the sidecar into the saved file. Offline, after capture, and only when
        // something was actually playing: a silent sidecar is minutes of export for a
        // file nobody would hear a difference in. On failure the merge leaves the
        // original alone, so the worst case is the mic-only recording we already had.
        if let systemAudio, systemAudio.hasAudibleContent, mergeSystemAudio {
            isFinishing = true
            _ = await SystemAudioMerger.mergeInPlace(recording: outputURL, systemAudio: systemAudio.url)
            isFinishing = false
        } else if systemAudio != nil && mergeSystemAudio {
            LogManager.shared.log("🔊 System audio: sidecar holds only silence - skipping the merge")
        }

        // Read the on-disk file size now so we can pass it to the backend at
        // registration time. Without this, fileSize stays nil for fresh recordings.
        // Read after the merge, so the size is the one the uploader will actually send.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? NSNumber {
            recording.fileSize = size.uint64Value
        }

        return recording
    }

    // MARK: - Salvage

    /// Best-effort probe of the partial .mp4 a dead writer left behind. If it happens
    /// to be readable (finalized enough to have a duration and a video track), return
    /// it as a regular Recording so the normal pipeline uploads it instead of losing
    /// the take. Returns nil (keeping the file on disk) if it can't be read — the
    /// common case for a non-fragmented file interrupted before finishWriting.
    private func salvagePartialRecording(at url: URL?, startedAt: Date?) async -> Recording? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            LogManager.shared.log("🔴 Recording: stop failed — writer produced no file", type: .error)
            return nil
        }
        // Ask for precise timing so the duration is scanned from the media rather than
        // trusted from a possibly-incomplete header.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0.5,
              let videoTracks = try? await asset.loadTracks(withMediaType: .video),
              !videoTracks.isEmpty else {
            LogManager.shared.log("🔴 Recording: stop failed — partial unreadable, kept at \(url.lastPathComponent)", type: .error)
            return nil
        }

        var recording = Recording(fileURL: url, createdAt: startedAt ?? Date(), duration: duration)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            recording.fileSize = size.uint64Value
        }
        LogManager.shared.log("🔴 Recording: writer died mid-recording — salvaged \(Int(duration))s partial \(url.lastPathComponent)", type: .error)
        return recording
    }

    // MARK: - Pause / Resume

    @MainActor
    func togglePause() async {
        // Run on the main actor (it mutates the same timing state as start/stop and
        // installs the duration Timer on RunLoop.main — both were previously done off
        // the main thread). Guard re-entrancy across the 0.5s resume sleep so two fast
        // taps can't double-toggle into a desynced state with a leaked timer.
        guard isRecording, !isTogglingPause else { return }
        isTogglingPause = true
        defer { isTogglingPause = false }

        // Play pause/resume sound first
        SoundManager.shared.play(.pause)

        // If we are currently paused, we are about to resume.
        // The "Tink" resume sound is audibly over by ~0.05s; 0.15s masks it before capture resumes.
        if isPaused {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        isPaused.toggle()

        if isPaused {
            // Pausing: save current segment duration
            if let start = lastStartTime {
                accumulatedDuration += Date().timeIntervalSince(start)
            }
            lastStartTime = nil
            videoWriter?.pause()
            stopTimer()
        } else {
            // Resuming: start new segment
            lastStartTime = Date()
            videoWriter?.resume()
            startTimer()
        }
    }


    // MARK: - Timer

    private func startTimer() {
        // Fire more frequently (0.1s) for a smooth UI, but use Date() for value
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, self.isRecording, !self.isPaused, let start = self.lastStartTime else { return }
            self.recordingDuration = self.accumulatedDuration + Date().timeIntervalSince(start)
        }
        RunLoop.main.add(timer, forMode: .common)
        durationTimer = timer
    }


    private func stopTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    // MARK: - Formatted Duration

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        let hours = Int(recordingDuration) / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes % 60, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
