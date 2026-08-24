import SwiftUI
import Sparkle

/// NoCorny Tracer — A macOS screen recording app with Dropbox sync
@main
struct NoCornyTracerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var appState = AppState()
    @State private var cameraWindowManager = CameraWindowManager()
    @State private var noiseSuggestionWindowManager = NoiseSuggestionWindowManager()
    @State private var permissionsManager: PermissionsManager

    // Sparkle auto-updater
    private let updaterController: SPUStandardUpdaterController
    /// Held for the lifetime of the app: Sparkle keeps its delegate weakly.
    private let updateScheduler: UpdateScheduler

    init() {
        // Register custom fonts from the app bundle
        Theme.Typography.registerFonts()

        // Initialize Sparkle updater (auto-checks for updates on launch)
        let scheduler = UpdateScheduler()
        self.updateScheduler = scheduler
        let updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: scheduler,
            userDriverDelegate: nil
        )
        self.updaterController = updater

        let pManager = PermissionsManager(updaterController: updater)
        self._permissionsManager = State(initialValue: pManager)

        // Read live rather than captured: the app almost always launches with no recording
        // running, so a captured value would always say "go ahead".
        scheduler.isRecording = { AppState.shared?.recordingManager.isRecording ?? false }
    }

    var body: some Scene {
        // Main Window
        Window("NoCorny Tracer", id: "main") {
            MainWindowHost(
                appState: appState,
                updaterController: updaterController,
                permissionsManager: permissionsManager,
                cameraWindowManager: cameraWindowManager,
                noiseSuggestionWindowManager: noiseSuggestionWindowManager,
                appDelegate: appDelegate
            )
                .preferredColorScheme(appState.appTheme.colorScheme)
                .tint(Theme.Colors.brandPurple)
                // The nocornytracer:// sign-in callback is handled in AppDelegate
                // (handleProcessURLEvent) so it works even when this window is closed.
                .onChange(of: appState.isCameraEnabled) { _, newValue in
                    cameraWindowManager.updateVisibility(isEnabled: newValue, appState: appState)
                }
        }
        // .contentSize: the window takes both its min AND max from the content, which is
        // what locks the width — MainView is a fixed 380pt wide, so 380 becomes the
        // window's max width too and the frame can't be dragged wider. Height stays
        // freely resizable because every tab's content is vertically flexible (max
        // height infinity), which also keeps switching tabs from collapsing the window.
        // Note: .contentMinSize can't lock the width — it leaves contentMaxSize
        // unbounded and re-applies that over any manual clamp.
        .defaultSize(width: 380, height: 560)
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
    let noiseSuggestionWindowManager: NoiseSuggestionWindowManager
    let appDelegate: AppDelegate

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainView(appState: appState, updaterController: updaterController, permissionsManager: permissionsManager)
            .onAppear {
                appDelegate.updaterController = updaterController
                appDelegate.reopenMainWindow = { openWindow(id: "main") }
                // The window exists, so a recovery relaunch (if one happened) worked.
                UserDefaults.standard.removeObject(forKey: AppDelegate.windowBootstrapKey)
                cameraWindowManager.updateVisibility(isEnabled: appState.isCameraEnabled, appState: appState)
                // Route toast presentation through a closure so it works while the main window is
                // hidden during recording (see AppState.presentNoiseSuggestion).
                appState.presentNoiseSuggestion = { show in
                    noiseSuggestionWindowManager.update(show: show, appState: appState)
                }

                // Route the recording permission gate through openWindow: when a Start is
                // blocked on a missing permission, bring the app forward and open the
                // Permissions window so the user can see and grant exactly what's missing.
                appState.presentPermissionsGate = { _ in
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "permissions")
                }

                // A start refusal arriving from the hotkey has no window to appear on, and
                // an alert on a closed window is "nothing at all happened" with extra steps.
                appState.presentStartFailure = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }

                appState.presentUploadFailure = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }

                // Opt the main window out of Cocoa state restoration. With
                // NSQuitAlwaysKeepsWindows enabled, quitting while the window is closed would
                // otherwise relaunch the app with no window — so MainWindowHost never appears,
                // the `reopenMainWindow` bridge stays nil, and the menu-bar / Dock click can't
                // summon the window. Disabling restoration makes the app reliably relaunch with
                // the window present and the bridge initialized.
                DispatchQueue.main.async {
                    NSApp.windows.first(where: { $0.title == "NoCorny Tracer" })?.isRestorable = false
                }
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

    /// One-shot guard so the windowless-launch recovery below cannot loop: set before the
    /// recovery relaunch, cleared the moment the window actually presents.
    static let windowBootstrapKey = "windowBootstrapRelaunchAttempted"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The app can come up with NO window at all: SwiftUI remembers the main scene was
        // closed at quit and does not re-present it, and every reopen path here runs through
        // a bridge closure that only exists once the window has appeared. Zero windows, nil
        // bridge, and every menu-bar and Dock click lands on nothing - which reached the
        // first user of 3.17.1 minutes after the update, as "the app will not open". The
        // macOS 15 scene modifiers that fix this properly are above our deployment target
        // and SceneBuilder refuses an availability branch, so: detect and relaunch, once.
        // A plain relaunch demonstrably presents the scene - that is how the incident was
        // resolved live.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.reopenMainWindow == nil,
                  !NSApp.windows.contains(where: { $0.title == "NoCorny Tracer" }) else {
                UserDefaults.standard.removeObject(forKey: Self.windowBootstrapKey)
                return
            }
            guard !UserDefaults.standard.bool(forKey: Self.windowBootstrapKey) else {
                // Relaunched once already and still windowless: stop, say so, and leave a
                // loud trace instead of a relaunch loop.
                LogManager.shared.log("🪟 Window: still no main window after a recovery relaunch — giving up", type: .error)
                return
            }
            LogManager.shared.log("🪟 Window: launched with no main window and a nil reopen bridge — relaunching once to recover", type: .error)
            UserDefaults.standard.set(true, forKey: Self.windowBootstrapKey)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        }

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
        // icon-v2 menubar set: drawn at natural 22×22 pt, shipped as @1x/@2x/@3x PNGs.
        normalImage = loadMenuBarImage(baseName: "menubar_idle_template", isTemplate: true)
        recordingLightImage = loadMenuBarImage(baseName: "menubar_rec_light", isTemplate: false)
        recordingDarkImage = loadMenuBarImage(baseName: "menubar_rec_dark", isTemplate: false)
    }

    /// Builds one NSImage out of the @1x/@2x/@3x PNG scale set so the menubar
    /// picks the right representation for the current display.
    private func loadMenuBarImage(baseName: String, isTemplate: Bool) -> NSImage? {
        let bundle = Bundle.appResources
        let pointSize = NSSize(width: 22, height: 22)
        let image = NSImage(size: pointSize)

        for suffix in ["", "@2x", "@3x"] {
            let name = baseName + suffix
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources")
                    ?? bundle.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = pointSize  // 22 pt regardless of pixel density
            image.addRepresentation(rep)
        }

        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = isTemplate  // template = macOS auto-tints for menubar appearance
        return image
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

        // A nil bridge means the scene never presented this launch, so the click would land
        // on nothing - silently, which is how this bug reached a user as "the app will not
        // open". Nothing can summon a SwiftUI window scene from AppKit, so the honest move
        // is the blunt one: relaunch ourselves; the scene presents at launch.
        if reopenMainWindow == nil {
            LogManager.shared.log("🪟 Window: reopen bridge is nil — the scene never presented; relaunching to recover", type: .error)
            UserDefaults.standard.set(true, forKey: Self.windowBootstrapKey)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }

        // Always ask SwiftUI to present the "main" Window scene. For a `Window` scene this
        // recreates it if the user closed it, or brings it forward if it was ordered-out
        // (e.g. hidden during recording). Previously we returned early after
        // makeKeyAndOrderFront on a lingering, content-less NSWindow that AppKit keeps in
        // NSApp.windows after a SwiftUI close — so the scene never actually reopened and the
        // menu-bar / Dock click appeared to do nothing.
        reopenMainWindow?()

        // Raise / un-miniaturize the resulting window once SwiftUI has (re)created it. A
        // miniaturized window won't expand from openWindow alone, so deminiaturize here.
        DispatchQueue.main.async { [weak self] in
            self?.raiseMainWindow()
        }
    }

    /// Brings the main window to the front, expanding it if it was collapsed to the Dock.
    private func raiseMainWindow() {
        guard let window = NSApp.windows.first(where: {
            $0.title == "NoCorny Tracer" && $0.canBecomeKey
        }) else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The floating camera overlay counts as a "visible window" to AppKit, which
        // breaks the default dock-click reopen. Handle it ourselves.
        showMainWindow()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // If a recording is in progress, finalize it before quitting — otherwise the
        // app exits with an unfinalized (moov-less, unplayable) file and the whole
        // recording is lost. stopRecording() writes the file and persists the row,
        // so it survives to be uploaded/retried on next launch.
        guard let appState = AppState.shared else { return .terminateNow }
        let manager = appState.recordingManager
        // Three states, not one. `isRecording` alone was wrong in both directions: a stop
        // already in flight still reads as recording, so this called stopRecording again and
        // got nil back - which it read as "nothing to wait for" and terminated the process on
        // top of a file that had not been finalised yet.
        let busy = {
            QuitDecision.isBusy(isRecording: manager.isRecording,
                                isStopping: manager.isStopping,
                                isFinishing: manager.isFinishing)
        }
        // `isFinishing` covers the window after capture ends and before the system-audio
        // merge finishes. The row is already saved by then, so quitting no longer loses the
        // take - but it does lose the far side of the call, and on a long meeting that
        // window is minutes of looking completely idle.
        guard busy() else { return .terminateNow }
        Task { @MainActor in
            // Only start a stop if nobody else has. A stop already running finalises the file
            // and saves the row on its own; joining in just gets nil.
            if QuitDecision.shouldStartAStop(isRecording: manager.isRecording, isStopping: manager.isStopping) {
                await appState.stopRecording()
            } else {
                LogManager.shared.log("🔴 Recording: quit requested while a take is being finished - waiting")
            }
            // Bounded: the recording itself is safe either way, and macOS force-quits an app
            // that stalls here. A minute buys most merges; the rest lose only the system-audio
            // mix, and the mic-only file is untouched on disk.
            let deadline = Date().addingTimeInterval(60)
            while busy() && Date() < deadline {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

        // Handle the Tracer sign-in callback HERE in the AppDelegate, which always
        // exists — rather than only via a SwiftUI .onReceive on the main window's
        // view, which isn't in the hierarchy when the window is closed (so the
        // callback was silently dropped, leaving the user stuck mid-sign-in).
        if url.scheme == "nocornytracer", let appState = AppState.shared {
            Task { @MainActor in
                await appState.tracerAPIClient.completeBrowserSignIn(url: url)
                if appState.tracerAPIClient.isSignedIn {
                    await appState.syncDropboxFromTracer()
                    await appState.reloadRecordingsFromTracer()
                }
            }
        }
    }
}

