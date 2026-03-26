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

    // MARK: - Sub-managers
    let screenRecorder = ScreenRecorder()
    let audioCaptureManager = AudioCaptureManager()

    // MARK: - Private
    private var videoWriter: VideoWriter?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    // MARK: - Start Recording

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
        let fileName = "BetterLoom_\(formatter.string(from: Date())).mp4"
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
        recordingStartTime = Date()
        startTimer()
    }

    // MARK: - Stop Recording

    func stopRecording() async -> Recording? {
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

        let recording = Recording(
            fileURL: outputURL,
            createdAt: recordingStartTime ?? Date(),
            duration: recordingDuration
        )

        isRecording = false
        isPaused = false
        videoWriter = nil
        currentFileURL = nil

        return recording
    }

    // MARK: - Pause / Resume

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            stopTimer()
        } else {
            startTimer()
        }
    }

    // MARK: - Timer

    private func startTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isPaused else { return }
            self.recordingDuration += 1.0
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
