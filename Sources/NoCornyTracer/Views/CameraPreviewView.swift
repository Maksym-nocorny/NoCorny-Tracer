import SwiftUI
import AVFoundation

/// Custom NSView that hosts the video preview layer directly
class VideoPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    
    init() {
        super.init(frame: .zero)
        self.wantsLayer = true
        self.layer = previewLayer
        previewLayer.videoGravity = .resizeAspectFill
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
        
        if let connection = nsView.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true // Often preferred for webcams
        }
    }
}
