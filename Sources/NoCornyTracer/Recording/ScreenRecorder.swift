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

    /// True once the running stream is actually delivering system audio. Asked after
    /// `startCapture` so the caller knows whether opening a sidecar file is worth it -
    /// requesting audio and getting it are two different things.
    private(set) var isCapturingSystemAudio = false

    // MARK: - Private
    private var stream: SCStream?
    private var streamOutput: StreamOutput?

    /// Serial queue for SCStream sample delivery. A concurrent queue let two frame
    /// callbacks run simultaneously and reach the writer out of PTS order; a serial
    /// queue guarantees ordered, one-at-a-time delivery.
    private let sampleHandlerQueue = DispatchQueue(label: "com.nocorny.tracer.screenrecorder.samples", qos: .userInitiated)

    /// System audio gets its own serial queue. Audio buffers arrive several times per
    /// frame interval, and sharing the screen queue would make every one of them wait
    /// behind a frame append (and vice versa).
    private let audioSampleHandlerQueue = DispatchQueue(label: "com.nocorny.tracer.screenrecorder.audio", qos: .userInitiated)

    // Callback for video frames
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// Callback for system audio (everything the Mac plays), delivered by the same
    /// stream as the frames when `startCapture(captureSystemAudio:)` asked for it.
    var onSystemAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

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
    func startCapture(width: Int = 1920, height: Int = 1080, fps: Int = 30, captureSystemAudio: Bool = false) async throws -> (width: Int, height: Int) {
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

        // System audio rides on THIS stream instead of a second one: a second SCStream
        // over the same display pays the capture cost twice and, worse, gives audio and
        // video independent stream clocks - precisely the drift the sidecar is designed
        // to avoid.
        if captureSystemAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            // Our own start/stop chimes and anything the app itself plays would otherwise
            // be recorded as if they were part of the call.
            config.excludesCurrentProcessAudio = true
        }

        // Create output handler
        let output = StreamOutput()
        output.onVideoSampleBuffer = { [weak self] sampleBuffer in
            self?.onVideoSampleBuffer?(sampleBuffer)
        }
        output.onStreamError = { [weak self] error in
            self?.onStreamError?(error)
        }
        output.onSystemAudioSampleBuffer = { [weak self] sampleBuffer in
            self?.onSystemAudioSampleBuffer?(sampleBuffer)
        }
        streamOutput = output

        // Create and start stream
        let captureStream = SCStream(filter: filter, configuration: config, delegate: output)
        try captureStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleHandlerQueue)

        // A stream that refuses the audio output still records the screen perfectly well,
        // so a failure here downgrades the take to mic-only instead of killing it.
        var systemAudioAttached = false
        if captureSystemAudio {
            do {
                try captureStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioSampleHandlerQueue)
                systemAudioAttached = true
            } catch {
                LogManager.shared.log("🔊 System audio: stream refused the audio output (\(error.localizedDescription)) - recording the microphone only", type: .error)
            }
        }

        try await captureStream.startCapture()
        stream = captureStream
        isCapturing = true
        isCapturingSystemAudio = systemAudioAttached
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
        isCapturingSystemAudio = false
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
    var onSystemAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onStreamError: ((Error) -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            // Validate frame status
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusValue = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusValue),
                  status == .complete else {
                return
            }
            onVideoSampleBuffer?(sampleBuffer)
        case .audio:
            // Audio carries no frame-status attachment; an empty buffer is simply
            // silence and the writer decides what to do with it.
            onSystemAudioSampleBuffer?(sampleBuffer)
        default:
            // .microphone (macOS 15+) and anything Apple adds later: we do not ask for
            // them, and the mic has its own capture path.
            return
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error)")
        onStreamError?(error)
    }
}
