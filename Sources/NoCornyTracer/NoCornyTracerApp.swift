import SwiftUI
import Sparkle

/// NoCorny Tracer — A macOS menu bar screen recording app
@main
struct NoCornyTracerApp: App {
    @State private var appState = AppState()
    @State private var cameraWindowManager = CameraWindowManager()
    @Environment(\.colorScheme) var colorScheme
    @State private var permissionsManager: PermissionsManager
    
    // Sparkle auto-updater
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Initialize Sparkle updater (auto-checks for updates on launch)
        let updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.updaterController = updater
        
        let pManager = PermissionsManager(updaterController: updater)
        self._permissionsManager = State(initialValue: pManager)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState, updaterController: updaterController)
                .onAppear {
                    // Initial check on launch after view builds
                    cameraWindowManager.updateVisibility(isEnabled: appState.isCameraEnabled, appState: appState)
                }
                .onOpenURL { url in
                    // Route Dropbox OAuth callback (db-uypbk3hdc7zz4l7://oauth2callback?code=...)
                    appState.dropboxAuthManager.handleCallback(url)
                }
        } label: {
            MenuBarLabelView(
                appState: appState,
                permissionsManager: permissionsManager,
                currentMenuBarIcon: currentMenuBarIcon
            )
        }
        .menuBarExtraStyle(.window)
        .onChange(of: appState.isCameraEnabled) { _, newValue in
            cameraWindowManager.updateVisibility(isEnabled: newValue, appState: appState)
        }
        
        // Permissions Window
        Window("Permissions", id: "permissions") {
            PermissionsView(permissionsManager: permissionsManager)
        }
        .windowResizability(.contentSize)
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

/// A wrapper view for the MenuBar icon that can evaluate permissions and open windows on app launch
private struct MenuBarLabelView: View {
    @Bindable var appState: AppState
    var permissionsManager: PermissionsManager
    var currentMenuBarIcon: NSImage
    
    @Environment(\.openWindow) var openWindow

    var body: some View {
        Image(nsImage: currentMenuBarIcon)
            .onAppear {
                // Check permissions as soon as the menu bar icon appears (on app launch)
                if !permissionsManager.hasAllRequiredPermissions {
                    openWindow(id: "permissions")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}
