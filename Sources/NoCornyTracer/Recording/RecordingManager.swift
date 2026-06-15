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

    // MARK: - Start Recording

    @MainActor
    func startRecording(
        microphoneEnabled: Bool,
        microphoneDeviceID: String?,
        videoWidth: Int = 1920,
        videoHeight: Int = 1080,
        fps: Int = 30
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

            // Create video writer sized to the capture output so frames aren't letterboxed
            let writer = VideoWriter(
                outputURL: outputURL,
                videoWidth: actualSize.width,
                videoHeight: actualSize.height,
                fps: fps
            )
            try writer.startWriting()
            videoWriter = writer

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
                try audioCaptureManager.startCapture()
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
            // Writer produced no file (disk full / encode error). Reset ALL state and
            // remove any corrupt partial, so we don't leave a phantom recording or
            // strand isPaused=true (which would drop the next recording's first frames).
            if let url = currentFileURL { try? FileManager.default.removeItem(at: url) }
            isRecording = false
            isPaused = false
            recordingDuration = 0
            accumulatedDuration = 0
            lastStartTime = nil
            videoWriter = nil
            currentFileURL = nil
            LogManager.shared.log("🔴 Recording: stop failed — writer produced no file; partial removed", type: .error)
            return nil
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
        // Wait 1.0 second so the sound doesn't get recorded.
        if isPaused {
            try? await Task.sleep(nanoseconds: 500_000_000)
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
