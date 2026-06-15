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

    /// Serial queue for SCStream sample delivery. A concurrent queue let two frame
    /// callbacks run simultaneously and reach the writer out of PTS order; a serial
    /// queue guarantees ordered, one-at-a-time delivery.
    private let sampleHandlerQueue = DispatchQueue(label: "com.nocorny.tracer.screenrecorder.samples", qos: .userInitiated)

    // Callback for video frames
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Fired when ScreenCaptureKit kills the stream mid-recording (display
    /// disconnected, permission revoked, WindowServer hiccup). Without this the
    /// app kept "recording" a dead stream: video frozen, audio still accumulating.
    var onStreamError: ((Error) -> Void)?

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
    @discardableResult
    func startCapture(width: Int = 1920, height: Int = 1080, fps: Int = 30) async throws -> (width: Int, height: Int) {
        // Refuse to start a second capture over a live one — that used to overwrite
        // `stream`/`streamOutput` and leak the first still-running SCStream.
        guard !isCapturing, stream == nil else {
            throw ScreenRecorderError.captureAlreadyRunning
        }
        guard let display = selectedDisplay else {
            throw ScreenRecorderError.noDisplaySelected
        }

        // Content filter for full display capture
        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Match the display's aspect ratio so the output isn't letterboxed.
        // Target the requested height; scale width proportionally and round to even pixels (H.264 requirement).
        let displayAspect = Double(display.width) / Double(display.height)
        let outHeight = height
        var outWidth = Int((Double(outHeight) * displayAspect).rounded())
        if outWidth % 2 != 0 { outWidth += 1 }

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = outWidth
        config.height = outHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA

        // Create output handler
        let output = StreamOutput()
        output.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.onVideoSampleBuffer?(sampleBuffer)
        }
        output.onStreamError = { [weak self] error in
            self?.onStreamError?(error)
        }
        streamOutput = output

        // Create and start stream
        let captureStream = SCStream(filter: filter, configuration: config, delegate: output)
        try captureStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleHandlerQueue)

        try await captureStream.startCapture()
        stream = captureStream
        isCapturing = true
        return (outWidth, outHeight)
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
    var onStreamError: ((Error) -> Void)?

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
        onStreamError?(error)
    }
}
