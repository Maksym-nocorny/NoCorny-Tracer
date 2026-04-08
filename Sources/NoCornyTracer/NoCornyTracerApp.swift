import SwiftUI
import Sparkle

/// NoCorny Tracer — A macOS screen recording app with Dropbox sync
@main
struct NoCornyTracerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var appState = AppState()
    @State private var cameraWindowManager = CameraWindowManager()
    @State private var permissionsManager: PermissionsManager

    // Sparkle auto-updater
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Register custom fonts from the app bundle
        Theme.Typography.registerFonts()

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
        // Main Window
        Window("NoCorny Tracer", id: "main") {
            MainView(appState: appState, updaterController: updaterController, permissionsManager: permissionsManager)
                .preferredColorScheme(appState.appTheme.colorScheme)
                .tint(Theme.Colors.brandPurple)
                .onAppear {
                    cameraWindowManager.updateVisibility(isEnabled: appState.isCameraEnabled, appState: appState)
                }
                .onReceive(NotificationCenter.default.publisher(for: .didReceiveURL)) { notification in
                    if let url = notification.object as? URL {
                        appState.dropboxAuthManager.handleCallback(url)
                    }
                }
                .onChange(of: appState.isCameraEnabled) { _, newValue in
                    cameraWindowManager.updateVisibility(isEnabled: newValue, appState: appState)
                }
        }
        .windowResizability(.contentSize)

        // Permissions Window
        Window("Permissions", id: "permissions") {
            PermissionsView(permissionsManager: permissionsManager)
                .preferredColorScheme(appState.appTheme.colorScheme)
                .tint(Theme.Colors.brandPurple)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - App Delegate

extension Notification.Name {
    static let didReceiveURL = Notification.Name("didReceiveURL")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var recordingStateTimer: Timer?
    private var lastIsRecording = false
    private var lastIsDark: Bool?

    // Preloaded menu bar images
    private var normalImage: NSImage?  // Template image — macOS auto-tints for menubar
    private var recordingLightImage: NSImage?
    private var recordingDarkImage: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // URL handler for Dropbox OAuth
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleProcessURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Load menu bar icons and setup status item
        loadMenuBarImages()
        setupStatusItem()
    }

    // MARK: - Menu Bar Images

    private func loadMenuBarImages() {
        let bundle = Bundle.appResources
        let names = [
            "menubar_normal_light",
            "menubar_recording_light",
            "menubar_recording_dark"
        ]

        for name in names {
            if let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources")
                ?? bundle.url(forResource: name, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                image.size = NSSize(width: 18, height: 18)
                if name == "menubar_normal_light" {
                    image.isTemplate = true  // macOS auto-tints for menubar appearance
                    normalImage = image
                } else {
                    image.isTemplate = false
                    switch name {
                    case "menubar_recording_light": recordingLightImage = image
                    case "menubar_recording_dark": recordingDarkImage = image
                    default: break
                    }
                }
            }
        }
    }

    // MARK: - Status Bar Icon

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.action = #selector(statusItemClicked)
        button.target = self

        // Set initial icon
        updateStatusIcon()

        // Poll recording state and appearance to update icon
        recordingStateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusIcon()
            }
        }

        // Also listen for appearance changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func appearanceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.lastIsDark = nil // Force refresh
            self?.updateStatusIcon()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let isRecording = AppState.shared?.recordingManager.isRecording ?? false
        // Use system appearance (not NSApp.effectiveAppearance which follows the app's theme)
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        // Only update if state changed
        guard isRecording != lastIsRecording || isDark != lastIsDark else { return }
        lastIsRecording = isRecording
        lastIsDark = isDark

        let image: NSImage?
        if isRecording {
            image = isDark ? recordingDarkImage : recordingLightImage
        } else {
            image = normalImage
        }

        if let image = image {
            button.image = image
        } else {
            // Fallback to SF Symbol
            let fallback = NSImage(
                systemSymbolName: isRecording ? "record.circle.fill" : "record.circle",
                accessibilityDescription: "NoCorny Tracer"
            )
            fallback?.isTemplate = true
            button.image = fallback
        }
    }

    @objc private func statusItemClicked() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            if window.title == "NoCorny Tracer" {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    // MARK: - URL Handling

    @objc func handleProcessURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }

        NotificationCenter.default.post(name: .didReceiveURL, object: url)
    }
}
