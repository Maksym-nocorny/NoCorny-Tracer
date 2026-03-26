import SwiftUI
import AppKit

/// Manages the floating, borderless camera window
@Observable
final class CameraWindowManager {
    private var window: NSWindow?
    private var appState: AppState?
    
    func setup(appState: AppState) {
        self.appState = appState
        
        // React to state changes
        Task {
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                // It's checked inside the AppState's didSet, but we can also poll here or bind.
                // An easier way is just to manually update when AppState calls it, but SwiftUI
                // can also just observe it. We'll use a direct approach in NoCornyTracerApp.
            }
        }
    }
    
    func updateVisibility(isEnabled: Bool, appState: AppState) {
        if isEnabled {
            showWindow(appState: appState)
        } else {
            hideWindow()
        }
    }
    
    private func showWindow(appState: AppState) {
        if window == nil {
            let cameraView = CameraView(cameraManager: appState.cameraManager)
            let hostingController = NSHostingController(rootView: cameraView)
            
            // Create a borderless, transparent window
            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            
            newWindow.contentViewController = hostingController
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true
            newWindow.level = .floating // Keep above normal windows
            newWindow.isMovableByWindowBackground = true // Crucial for a window without a title bar
            
            // Initial position (bottom left corner with padding)
            if let screen = NSScreen.main {
                let padding: CGFloat = 40
                let x = screen.visibleFrame.minX + padding
                let y = screen.visibleFrame.minY + padding
                newWindow.setFrameOrigin(NSPoint(x: x, y: y))
            }
            
            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            
            self.window = newWindow
        }
        
        window?.makeKeyAndOrderFront(nil)
    }
    
    private func hideWindow() {
        window?.orderOut(nil)
        window = nil // Deallocate
    }
}
