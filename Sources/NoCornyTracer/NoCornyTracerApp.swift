import SwiftUI
import Sparkle

/// NoCorny Tracer — A macOS menu bar screen recording app
@main
struct NoCornyTracerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
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
        } label: {
            MenuBarLabelView(
                appState: appState,
                permissionsManager: permissionsManager,
                currentMenuBarIcon: currentMenuBarIcon
            )
            .onReceive(NotificationCenter.default.publisher(for: .didReceiveURL)) { notification in
                if let url = notification.object as? URL {
                    // Route Dropbox OAuth callback
                    appState.dropboxAuthManager.handleCallback(url)
                }
            }
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

// MARK: - App Delegate for URL Handling

extension Notification.Name {
    static let didReceiveURL = Notification.Name("didReceiveURL")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var rightClickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleProcessURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        setupRightClickContextMenu()
    }

    // MARK: - Right-click context menu on menu bar icon

    private func setupRightClickContextMenu() {
        // Use a local monitor so we catch right-clicks that fall inside the
        // app's own event stream (e.g. when the popover is open).
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            // If the click is on a status bar button, intercept it and show
            // our context menu instead of forwarding the event.
            if self?.isClickOnStatusBarButton(event) == true {
                self?.showQuitContextMenu(at: NSEvent.mouseLocation)
                return nil // swallow the event
            }
            return event
        }
    }

    /// Returns true when the right-click event landed on one of this app's
    /// NSStatusBarButton instances.
    private func isClickOnStatusBarButton(_ event: NSEvent) -> Bool {
        guard let clickedView = event.window?.contentView?.hitTest(event.locationInWindow) else {
            // No content view / hit-test failed — check class name of window
            if let w = event.window {
                let cls = String(describing: type(of: w))
                return cls.contains("StatusBar")
            }
            return false
        }
        // Walk the view hierarchy upward looking for NSStatusBarButton
        var view: NSView? = clickedView
        while let v = view {
            if v is NSStatusBarButton { return true }
            view = v.superview
        }
        return false
    }

    /// Shows the right-click context menu at the given screen-coordinate position.
    private func showQuitContextMenu(at screenLocation: NSPoint) {
        let menu = NSMenu(title: "NoCorny Tracer")

        let quitItem = NSMenuItem(
            title: "Quit NoCorny Tracer",
            action: #selector(forceQuit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        // popUp(positioning:at:in:) uses screen coordinates when `in` is nil
        menu.popUp(positioning: nil, at: screenLocation, in: nil)
    }

    /// Hard-kills the process immediately — no cleanup, no graceful shutdown.
    @objc private func forceQuit() {
        exit(0)
    }

    // MARK: - URL handling

    @objc func handleProcessURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }
        
        NotificationCenter.default.post(name: .didReceiveURL, object: url)
    }
}
