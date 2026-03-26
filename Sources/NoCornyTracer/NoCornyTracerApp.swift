import SwiftUI
import Sparkle

/// NoCornyTracer — A macOS menu bar screen recording app
@main
struct NoCornyTracerApp: App {
    @State private var appState = AppState()
    @State private var cameraWindowManager = CameraWindowManager()
    
    // Sparkle auto-updater
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Initialize Sparkle updater (auto-checks for updates on launch)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updaterController: updaterController)
                .onAppear {
                    // Initial check on launch after view builds
                    cameraWindowManager.updateVisibility(isEnabled: appState.isCameraEnabled, appState: appState)
                }
        } label: {
            Image(nsImage: currentMenuBarIcon)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: appState.isCameraEnabled) { _, newValue in
            cameraWindowManager.updateVisibility(isEnabled: newValue, appState: appState)
        }
    }

    /// Returns the appropriate menu bar icon based on recording state
    private var currentMenuBarIcon: NSImage {
        if appState.recordingManager.isRecording {
            let img = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")!
            img.isTemplate = true
            return img
        }
        // Use a custom bundle locator to avoid SPM's auto-generated Bundle.module which crashes when packed in .app
        let bundleName = "NoCornyTracer_NoCornyTracer"
        let bundleURL = Bundle.main.url(forResource: bundleName, withExtension: "bundle") ??
                        Bundle.main.bundleURL.appendingPathComponent("\(bundleName).bundle")
        let appBundle = Bundle(url: bundleURL) ?? Bundle.main
        
        if let resourceURL = appBundle.url(forResource: "menubar_icon", withExtension: "png", subdirectory: "Resources") ??
                             appBundle.url(forResource: "menubar_icon", withExtension: "png"),
           let image = NSImage(contentsOf: resourceURL) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        let fallback = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "NoCornyTracer")!
        fallback.isTemplate = true
        return fallback
    }
}
