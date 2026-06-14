import SwiftUI
import AVFoundation

/// Custom NSView that hosts the video preview layer directly
class VideoPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private var connectionObservation: NSKeyValueObservation?

    init() {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill

        // The preview connection is rebuilt asynchronously whenever the session's
        // input changes (e.g. switching cameras). Observe the layer's `connection`
        // so mirroring is re-applied every time a fresh connection appears, not
        // just on the initial updateNSView pass.
        connectionObservation = previewLayer.observe(\.connection, options: [.initial, .new]) { [weak self] _, _ in
            self?.applyMirroring()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Mirrors the preview (webcam-style). Idempotent and safe to call repeatedly.
    func applyMirroring() {
        guard let connection = previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true // Often preferred for webcams
    }
}

/// A SwiftUI wrapper for AVCaptureVideoPreviewLayer
struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    
    func makeNSView(context: Context) -> VideoPreviewView {
        let view = VideoPreviewView()
        view.previewLayer.session = session
        return view
    }
    
    func updateNSView(_ nsView: VideoPreviewView, context: Context) {
        nsView.previewLayer.session = session
        nsView.applyMirroring()
    }
}
