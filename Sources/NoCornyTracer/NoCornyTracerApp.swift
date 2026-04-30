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
            MainWindowHost(
                appState: appState,
                updaterController: updaterController,
                permissionsManager: permissionsManager,
                cameraWindowManager: cameraWindowManager,
                appDelegate: appDelegate
            )
                .preferredColorScheme(appState.appTheme.colorScheme)
                .tint(Theme.Colors.brandPurple)
                .onReceive(NotificationCenter.default.publisher(for: .didReceiveURL)) { notification in
                    guard let url = notification.object as? URL else { return }
                    if url.scheme == "nocornytracer" {
                        Task {
                            await appState.tracerAPIClient.completeBrowserSignIn(url: url)
                            if appState.tracerAPIClient.isSignedIn {
                                await appState.syncDropboxFromTracer()
                                await appState.reloadRecordingsFromTracer()
                            }
                        }
                    }
                    // Dropbox is now managed entirely on the web — the app no longer
                    // listens for db-<key>:// callbacks.
                }
                .onChange(of: appState.isCameraEnabled) { _, newValue in
                    cameraWindowManager.updateVisibility(isEnabled: newValue, appState: appState)
                }
        }
        // .contentMinSize: window won't auto-resize when content changes (e.g. switching
        // tabs no longer collapses the window). The window's minimum is the content's
        // minimum (380×480), and the user can resize larger if they want.
        .defaultSize(width: 380, height: 560)
        .windowResizability(.contentMinSize)

        // Permissions Window
        Window("Permissions", id: "permissions") {
            PermissionsView(permissionsManager: permissionsManager)
                .preferredColorScheme(appState.appTheme.colorScheme)
                .tint(Theme.Colors.brandPurple)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Main Window Host

/// Thin wrapper around MainView that captures the SwiftUI `openWindow` action and
/// bridges it to the AppDelegate so the menu-bar icon can reopen the Scene after
/// it's been closed. (Before this bridge, `NSApp.windows` would be empty after the
/// user closed the window, leaving the status-item click with nothing to focus.)
private struct MainWindowHost: View {
    @Bindable var appState: AppState
    let updaterController: SPUStandardUpdaterController
    @Bindable var permissionsManager: PermissionsManager
    let cameraWindowManager: CameraWindowManager
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainView(appState: appState, updaterController: updaterController, permissionsManager: permissionsManager)
            .onAppear {
                appDelegate.updaterController = updaterController
                appDelegate.reopenMainWindow = { openWindow(id: "main") }
                cameraWindowManager.updateVisibility(isEnabled: appState.isCameraEnabled, appState: appState)
            }
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

    // Sparkle updater (set from NoCornyTracerApp)
    var updaterController: SPUStandardUpdaterController?

    /// Reopens the main window Scene. Set by MainView via `.onAppear` so that we can
    /// invoke SwiftUI's environment `openWindow` from the AppDelegate (e.g. from the
    /// menu-bar icon after the window has been closed).
    var reopenMainWindow: (() -> Void)?

    // Preloaded menu bar images
    private var normalImage: NSImage?  // Template image — macOS auto-tints for menubar
    private var recordingLightImage: NSImage?
    private var recordingDarkImage: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // URL handler for Tracer browser sign-in (nocornytracer://...).
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem?.button else { return }

        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Set initial icon
        updateStatusIcon()

        // Poll recording state and appearance to update icon (0.1s to stay in sync with RecordingManager.durationTimer)
        recordingStateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
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

        // Always update timer title (changes every second during recording)
        if isRecording {
            let duration = AppState.shared?.recordingManager.formattedDuration ?? ""
            button.title = " \(duration)"
        } else {
            button.title = ""
        }

        // Only swap image when state actually changed
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
        guard let event = NSApp.currentEvent else { return }
        let isActive = AppState.shared?.recordingManager.isRecording ?? false
        // During recording/pause: left=menu, right=app
        // When idle:              left=app,  right=menu
        let wantsMenu = isActive ? (event.type == .leftMouseUp) : (event.type == .rightMouseUp)

        if wantsMenu {
            let menu = buildContextMenu()
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            showMainWindow()
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let isRecording = AppState.shared?.recordingManager.isRecording ?? false
        let isPaused = AppState.shared?.recordingManager.isPaused ?? false

        // Recording controls
        if isRecording {
            let stopItem = NSMenuItem(title: "Stop Recording", action: #selector(toggleRecording), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)

            let pauseTitle = isPaused ? "Resume Recording" : "Pause Recording"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(togglePause), keyEquivalent: "")
            pauseItem.target = self
            menu.addItem(pauseItem)

            let abortItem = NSMenuItem(title: "Abort Recording", action: #selector(abortRecording), keyEquivalent: "")
            abortItem.target = self
            menu.addItem(abortItem)
        } else {
            let startItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "")
            startItem.target = self
            menu.addItem(startItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Navigation
        let openItem = NSMenuItem(title: "Open NoCorny Tracer", action: #selector(showMainWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let folderItem = NSMenuItem(title: "Open Recordings on Web", action: #selector(openRecordingsOnWeb), keyEquivalent: "")
        folderItem.target = self
        menu.addItem(folderItem)

        menu.addItem(NSMenuItem.separator())

        // Updates
        let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit NoCorny Tracer", action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Menu Actions

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // If a main window already exists, focus it. Deminiaturize first if it
        // was collapsed to the Dock — makeKeyAndOrderFront alone won't expand.
        if let window = NSApp.windows.first(where: { $0.title == "NoCorny Tracer" }) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Otherwise ask SwiftUI to reopen the Scene via its environment handle.
        reopenMainWindow?()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The floating camera overlay counts as a "visible window" to AppKit, which
        // breaks the default dock-click reopen. Handle it ourselves.
        showMainWindow()
        return false
    }

    @objc private func toggleRecording() {
        guard let appState = AppState.shared else { return }
        Task { @MainActor in
            if appState.recordingManager.isRecording {
                await appState.stopRecording()
            } else {
                NSApp.windows.first { $0.title == "NoCorny Tracer" }?.orderOut(nil)
                try? await appState.startRecording()
            }
        }
    }

    @objc private func togglePause() {
        guard let appState = AppState.shared else { return }
        Task { @MainActor in
            await appState.recordingManager.togglePause()
        }
    }

    @objc private func abortRecording() {
        guard let appState = AppState.shared else { return }
        Task { @MainActor in
            await appState.abortRecording()
        }
    }

    @objc private func openRecordingsOnWeb() {
        AppState.shared?.openTracerDashboard()
    }

    @objc private func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }

    // MARK: - URL Handling

    @objc func handleProcessURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString) else { return }

        NotificationCenter.default.post(name: .didReceiveURL, object: url)
    }
}
