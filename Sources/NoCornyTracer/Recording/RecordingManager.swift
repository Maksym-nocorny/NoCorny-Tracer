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
    /// Internal so a test can drive a real writer headlessly and reach the normal stop path.
    /// The lowering of `isStopping` before the merge lives there, and it is the piece whose
    /// absence made every stop door a silent no-op for the length of an export.
    var videoWriter: VideoWriter?
    /// Opt-in sidecar for system audio. Nil for every recording that did not ask for it,
    /// and nil again the moment anything on that path goes wrong.
    private var systemAudioWriter: SystemAudioWriter?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    /// Set synchronously before the first await in startRecording so a double
    /// trigger during the async start can't launch a second concurrent capture.
    ///
    /// Readable (round 12) because it is also the only signal for "a take is
    /// being prepared": the screen stream starts and the writer ARMS inside this
    /// window, several awaits before `isRecording` flips, and the command bar has
    /// to be out of screen capture for all of it — otherwise the bar lands in the
    /// opening frames of every recording.
    private(set) var isStarting = false
    /// Mirror of `isStarting`. `isRecording` stays true across every await in the stop
    /// sequence - closing the writer, finishing the sidecar, finalising the file - so a
    /// second stop arriving in that window (the button, the hotkey, the menu item, the quit
    /// handler and the writer-failure path are five separate doors) walked into the same
    /// teardown and could take the sidecar out from under the first.
    private(set) var isStopping = false
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
        startMaskDelay: UInt64 = 0,
        selection: CaptureSelection = CaptureSelection()
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
                captureSystemAudio: recordSystemAudio,
                selection: selection
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
                    self.onInterrupted?(interrupted?.take)
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
    ) async -> StopOutcome? {
        guard isRecording, !isStopping else { return nil }
        isStopping = true
        // Belt and braces for the early returns below; the teardown also clears it explicitly
        // once the file is finalised, because the merge that follows is guarded separately
        // and must not block the next recording's stop for its whole duration.
        defer { isStopping = false }

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
            // `.recovered`, never `.finished`: this path returns without handing anything to
            // the caller, so the take is one nobody has seen. Marking it as already saved
            // would make the caller treat "not in the list" as "deleted" and drop the
            // recording the salvage just rescued.
            //
            return salvaged.map { StopOutcome.recovered($0) }
        }

        let finalDuration = lastStartTime != nil ? accumulatedDuration + Date().timeIntervalSince(lastStartTime!) : accumulatedDuration
        let startedAt = recordingStartTime ?? Date()

        // Clear live state BEFORE the merge below. The capture is over either way, and an
        // export that runs for a minute on a long take would otherwise leave the UI sitting
        // in "recording" with a frozen timer - a stop that looks like it did not work. It
        // also pins the values this take needs (start time, output URL) into locals, so a
        // recording started while the merge runs cannot rewrite them underneath us.
        isRecording = false
        // Down together with isRecording, and BEFORE the merge. Held across the merge it made
        // every door to stop a NEW recording a silent no-op for minutes - and a quit in that
        // state saw isRecording true, got nil back, and terminated the process on top of a
        // live, unfinalised file. The merge has isFinishing.
        isStopping = false
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

        let shouldMerge = mergeSystemAudio && systemAudio?.hasAudibleContent == true
        if systemAudio != nil && mergeSystemAudio && !shouldMerge {
            LogManager.shared.log("🔊 System audio: sidecar holds only silence - skipping the merge")
        }

        // Raised here, synchronously, rather than left to the first line of `finishTake`.
        // That call suspends, and in the hop between lowering `isStopping` and the flag going
        // up inside it, all three states read false while the take had still not been handed
        // to anybody - a quit landing exactly there terminated on a finalised file with no
        // row pointing at it. Microseconds wide, and free to close.
        isFinishing = true
        return await Self.finishTake(
            recording,
            handOver: { take in onCaptureFinished?(take) },
            markFinishing: { [weak self] busy in self?.isFinishing = busy },
            merge: {
                guard shouldMerge, let systemAudio else { return }
                _ = await SystemAudioMerger.mergeInPlace(recording: outputURL, systemAudio: systemAudio.url)
            },
            sizeOnDisk: {
                let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
                return (attrs?[.size] as? NSNumber)?.uint64Value
            }
        )
    }

    /// What a stop produced, and whether the caller has already seen it.
    ///
    /// Returned rather than left on the manager as a flag someone has to remember to read at
    /// the right moment: the caller needs "already saved" to tell a take that was never
    /// written from one that was written and then deleted while the merge ran, and a mutable
    /// field could be - and was - left unset with every test still green.
    struct StopOutcome {
        let take: Recording
        let wasHandedOver: Bool

        /// Deliberately not constructible with an arbitrary flag. There are exactly two ways
        /// a stop ends, they mean opposite things to the caller, and a boolean argument is
        /// something a careless edit can flip with every test still passing. Naming them
        /// makes the wrong one a wrong word rather than a wrong value.
        fileprivate init(take: Recording, wasHandedOver: Bool) {
            self.take = take
            self.wasHandedOver = wasHandedOver
        }

        /// The stop ran to completion and offered the take to whoever asked for it, before
        /// the merge. Callers that pass a hand-over closure have it saved by now; callers
        /// that do not - abort, writer recovery, a stream that died - never wanted it saved
        /// and do not read this.
        static func finished(_ take: Recording) -> StopOutcome {
            StopOutcome(take: take, wasHandedOver: true)
        }

        /// Recovered from a writer that died. Nobody has seen it, so the caller must add it -
        /// treating it as already saved would quietly throw the recovered recording away.
        static func recovered(_ take: Recording) -> StopOutcome {
            StopOutcome(take: take, wasHandedOver: false)
        }
    }

    /// Purely bookkeeping for a stop, in the order it has to happen.
    ///
    /// Written out as one named thing because the order is the whole point and getting it
    /// wrong is invisible: the take used to be handed over AFTER the merge, so for the
    /// minutes a long export takes there was no row anywhere, no timer, nothing on screen -
    /// and quitting in that window, which is what people do after a meeting, lost the
    /// recording outright. Steps inline in a 120-line function cannot be held by a test;
    /// this can.
    ///
    /// - `handOver` runs BEFORE the merge: the file is already complete and playable, and a
    ///   failed merge leaves it untouched, so there is nothing to wait for.
    /// - `markFinishing` brackets the merge, so a quit can wait for it rather than kill it.
    /// - `sizeOnDisk` runs AFTER, because the merge changes the file.
    static func finishTake(
        _ take: Recording,
        handOver: (Recording) -> Void,
        markFinishing: (Bool) -> Void,
        merge: () async -> Void,
        sizeOnDisk: () -> UInt64?
    ) async -> StopOutcome {
        var take = take
        handOver(take)
        markFinishing(true)
        await merge()
        markFinishing(false)
        take.fileSize = sizeOnDisk()
        // Handed over by construction: the line above is unconditional, so this is the one
        // place the answer cannot drift from the truth. Tracking it in a variable at the call
        // site instead meant a mutant could leave it false with every test still green, and
        // the caller would then treat a saved take as one it had never seen - bringing back
        // rows the user deleted while the merge ran.
        return .finished(take)
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
