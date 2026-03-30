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

    // MARK: - Start Recording

    @MainActor
    func startRecording(
        microphoneEnabled: Bool,
        microphoneDeviceID: String?,
        videoWidth: Int = 1920,
        videoHeight: Int = 1080,
        fps: Int = 30
    ) async throws {
        guard !isRecording else { return }

        // Request permissions
        let hasPermission = await screenRecorder.requestPermission()
        guard hasPermission else {
            throw ScreenRecorderError.permissionDenied
        }

        // Generate output file path
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "NoCornyTracer_\(formatter.string(from: Date())).mp4"
        let outputURL = AppState.recordingsDirectory.appendingPathComponent(fileName)
        currentFileURL = outputURL

        // Create video writer with configured settings
        let writer = VideoWriter(
            outputURL: outputURL,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            fps: fps
        )
        try writer.startWriting()
        videoWriter = writer

        // Setup screen capture callbacks — check isPaused to actually pause recording
        screenRecorder.onVideoSampleBuffer = { [weak self, weak writer] sampleBuffer in
            guard let self = self, !self.isPaused else { return }
            writer?.appendVideoBuffer(sampleBuffer)
        }

        // Start screen capture with configured settings
        try await screenRecorder.startCapture(width: videoWidth, height: videoHeight, fps: fps)

        // Start microphone if enabled
        if microphoneEnabled {
            audioCaptureManager.refreshDevices()
            if let deviceID = microphoneDeviceID {
                audioCaptureManager.selectDevice(id: deviceID)
            }
            audioCaptureManager.onAudioSampleBuffer = { [weak self, weak writer] sampleBuffer in
                guard let self = self, !self.isPaused else { return }
                writer?.appendAudioBuffer(sampleBuffer)
            }
            try audioCaptureManager.startCapture()
        }

        // Start duration timer
        isRecording = true
        isPaused = false
        recordingDuration = 0
        accumulatedDuration = 0
        lastStartTime = Date()
        recordingStartTime = lastStartTime
        startTimer()
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
            isRecording = false
            return nil
        }

        let finalDuration = lastStartTime != nil ? accumulatedDuration + Date().timeIntervalSince(lastStartTime!) : accumulatedDuration
        
        let recording = Recording(
            fileURL: outputURL,
            createdAt: recordingStartTime ?? Date(),
            duration: finalDuration
        )


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

    func togglePause() async {
        // Play pause/resume sound first
        SoundManager.shared.play(.pause)
        
        // If we are currently paused, we are about to resume.
        // Wait 1.0 second so the sound doesn't get recorded.
        if isPaused {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
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
