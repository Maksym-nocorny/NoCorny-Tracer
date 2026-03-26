import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Manages screen capture using ScreenCaptureKit
@Observable
final class ScreenRecorder: NSObject {
    // MARK: - State
    var isCapturing = false
    var availableDisplays: [SCDisplay] = []
    var selectedDisplay: SCDisplay?
    var hasPermission = false

    // MARK: - Private
    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    // Callback for video frames
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    // MARK: - Permission & Discovery

    func requestPermission() async -> Bool {
        do {
            // Requesting shareable content implicitly triggers the permission prompt
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays
            selectedDisplay = content.displays.first
            hasPermission = true
            return true
        } catch {
            print("Screen capture permission denied: \(error)")
            hasPermission = false
            return false
        }
    }

    func refreshDisplays() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            availableDisplays = content.displays
            if selectedDisplay == nil {
                selectedDisplay = content.displays.first
            }
        } catch {
            print("Failed to refresh displays: \(error)")
        }
    }

    // MARK: - Capture

    @MainActor
    func startCapture(width: Int = 1920, height: Int = 1080, fps: Int = 30) async throws {
        guard let display = selectedDisplay else {
            throw ScreenRecorderError.noDisplaySelected
        }

        // Content filter for full display capture
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Create output handler
        let output = StreamOutput()
        output.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.onVideoSampleBuffer?(sampleBuffer)
        }
        streamOutput = output

        // Create and start stream
        let captureStream = SCStream(filter: filter, configuration: config, delegate: output)
        try captureStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))

        try await captureStream.startCapture()
        stream = captureStream
        isCapturing = true
    }

    @MainActor
    func stopCapture() async {
        guard let stream = stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            print("Error stopping capture: \(error)")
        }
        self.stream = nil
        streamOutput = nil
        isCapturing = false
    }
}

// MARK: - Errors

enum ScreenRecorderError: LocalizedError {
    case noDisplaySelected
    case permissionDenied
    case captureAlreadyRunning

    var errorDescription: String? {
        switch self {
        case .noDisplaySelected: return "No display selected for recording"
        case .permissionDenied: return "Screen recording permission was denied"
        case .captureAlreadyRunning: return "A capture session is already running"
        }
    }
}

// MARK: - Stream Output Handler

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {

    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }

        // Validate frame status
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusValue),
              status == .complete else {
            return
        }

        onVideoSampleBuffer?(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
    }
}
