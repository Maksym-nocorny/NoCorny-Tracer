import SwiftUI

/// The circular floating camera view
struct CameraView: View {
    let cameraManager: CameraManager
    
    var body: some View {
        ZStack {
            if cameraManager.isCapturing {
                CameraPreviewView(session: cameraManager.captureSession)
            } else {
                // Fallback / loading state
                Color.black
                Image(systemName: "video.slash")
                    .foregroundColor(.white)
                    .font(.system(size: 40))
            }
        }
        // Same constant the window is sized from (round 13): since the hosting
        // view no longer drives the window, these two must agree by definition,
        // not by coincidence.
        .frame(width: CameraWindowManager.bubbleSide, height: CameraWindowManager.bubbleSide)
        .clipShape(Circle())
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 4)
        )
        // Ensure dragging the window works across the entire view
        .background(Color.black.opacity(0.01))
    }
}
