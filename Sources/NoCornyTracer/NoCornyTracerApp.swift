import SwiftUI
import Sparkle

/// NoCorny Tracer — A macOS menu bar screen recording app
@main
struct NoCornyTracerApp: App {
    @State private var appState = AppState()
    @State private var cameraWindowManager = CameraWindowManager()
    @Environment(\.colorScheme) var colorScheme
    
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

    /// Returns the appropriate menu bar icon based on recording state and system theme
    private var currentMenuBarIcon: NSImage {
        let isRecording = appState.recordingManager.isRecording
        let isDark = colorScheme == .dark
        
        let imageName: String
        if isRecording {
            imageName = isDark ? "menubar_recording_light" : "menubar_recording_dark"
        } else {
            imageName = isDark ? "menubar_normal_light" : "menubar_normal_dark"
        }
        
        let appBundle = Bundle.appResources
        
        if let resourceURL = appBundle.url(forResource: imageName, withExtension: "png", subdirectory: "Resources") ??
                             appBundle.url(forResource: imageName, withExtension: "png"),
           let image = NSImage(contentsOf: resourceURL) {
            image.isTemplate = false
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        
        // Fallback
        let fallback = NSImage(systemSymbolName: isRecording ? "record.circle.fill" : "record.circle", accessibilityDescription: "NoCorny Tracer")!
        fallback.isTemplate = true
        return fallback
    }
}
