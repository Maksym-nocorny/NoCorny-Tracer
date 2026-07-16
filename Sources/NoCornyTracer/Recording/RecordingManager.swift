import Foundation
import AVFoundation
import ScreenCaptureKit

/// Coordinates the full recording lifecycle: screen capture + audio + writing to file
@Observable
final class RecordingManager {
    // MARK: - State
    var isRecording = false
    var isPaused = false
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
            let actualSize = try await screenRecorder.startCapture(width: videoWidth, height: videoHeight, fps: fps)

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
            audioCaptureManager.onAudioSampleBuffer = nil
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

    @MainActor
    func stopRecording(playSound: Bool = true) async -> Recording? {
        guard isRecording else { return nil }

        // Stop timer
        stopTimer()

        // Stop captures
        await screenRecorder.stopCapture()
        audioCaptureManager.stopCapture()

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
            return await salvagePartialRecording(at: partialURL, startedAt: startedAt)
        }

        let finalDuration = lastStartTime != nil ? accumulatedDuration + Date().timeIntervalSince(lastStartTime!) : accumulatedDuration

        // Read the on-disk file size now so we can pass it to the backend at
        // registration time. Without this, fileSize stays nil for fresh recordings.
        var fileSize: UInt64? = nil
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? NSNumber {
            fileSize = size.uint64Value
        }

        var recording = Recording(
            fileURL: outputURL,
            createdAt: recordingStartTime ?? Date(),
            duration: finalDuration
        )
        recording.fileSize = fileSize


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
