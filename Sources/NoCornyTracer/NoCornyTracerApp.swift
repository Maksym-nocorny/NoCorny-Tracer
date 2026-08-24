import SwiftUI
import Sparkle

/// NoCorny Tracer — A macOS screen recording app with Dropbox sync
@main
struct NoCornyTracerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var appState = AppState()
    @State private var cameraWindowManager = CameraWindowManager()
    @State private var toastWindowManager = ToastWindowManager()
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
                toastWindowManager: toastWindowManager,
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
    let toastWindowManager: ToastWindowManager
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
                // hidden during recording (see AppState.presentNoiseSuggestion). Both the
                // noise suggestion and the phase-4 info toasts ("Uploaded — link copied",
                // "Upload failed — Dropbox full") share the one ToastWindowManager.
                appState.presentNoiseSuggestion = { show in
                    toastWindowManager.updateNoiseSuggestion(show: show, appState: appState)
                }
                appState.presentToast = { toast in
                    toastWindowManager.show(toast: toast, appState: appState)
                }

                // Route the recording permission gate to the onboarding card (phase 5):
                // a Start blocked on Screen Recording re-opens step 1, which explains
                // the grant AND the relaunch it needs. Mic/camera can only be missing
                // here when the user DENIED them earlier (undetermined ones get the
                // system prompt inside ensureRecordingPermissions) — onboarding can't
                // help with a denial, so those go straight to System Settings.
                appState.presentPermissionsGate = { missing in
                    NSApp.activate(ignoringOtherApps: true)
                    if missing.contains(.screenRecording) {
                        appDelegate.presentOnboardingPermissionStep()
                    } else if let first = missing.first {
                        PermissionsManager.openSystemSettings(for: first)
                    }
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
    /// The tray (phase 5): status item, icon states, click routing and the menu
    /// all live in the controller; the delegate only owns and wires it.
    @MainActor private var statusItemController: StatusItemController?

    // Sparkle updater (set from NoCornyTracerApp)
    var updaterController: SPUStandardUpdaterController?

    /// Reopens the main window Scene. Set by MainView via `.onAppear` so that we can
    /// invoke SwiftUI's environment `openWindow` from the AppDelegate (e.g. from the
    /// menu-bar icon after the window has been closed).
    var reopenMainWindow: (() -> Void)?

    /// The floating command bar of the redesign (phase 2). Owned here rather than as
    /// App @State because it must come up at launch and from the tray menu — neither
    /// path can rely on the main window's view graph having appeared.
    @MainActor var commandBarWindowManager: CommandBarWindowManager?

    /// The background-activity pills panel (phase 4) — owned here for the same
    /// reason as the bar: uploads resume at launch, before any window appears.
    @MainActor var backgroundPillsWindowManager: BackgroundPillsWindowManager?

    /// The onboarding window (phase 5) — owned here because both of its doors
    /// (first launch, permission gate) can open with no SwiftUI window anywhere.
    @MainActor var onboardingWindowManager: OnboardingWindowManager?

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

        // Redesign phase-2 scaffolding: show the floating command bar alongside the old
        // main window (which stays fully functional until phase 7 dismantles it).
        // Phase 5 adds the tray controller and the first-launch onboarding check
        // (which runs AFTER the bar so the card lands on top of it).
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setupStatusItemController()
            self.bootstrapCommandBar()
            self.presentOnboardingAtLaunchIfNeeded()
        }
    }

    // MARK: - Tray (redesign phase 5)

    @MainActor private func setupStatusItemController() {
        let controller = StatusItemController(actions: .init(
            showCommandBar: { [weak self] in self?.presentCommandBar() },
            showGallery: { [weak self] in self?.presentCommandBar(drawer: .gallery) },
            showSettings: { [weak self] in self?.presentCommandBar(drawer: .settings) }
        ))
        statusItemController = controller
        controller.attach()
    }

    /// Fronts the command bar (creating it if needed) and optionally opens a drawer.
    /// Mid-take the bar IS the recording pill — the drawer morph is skipped then,
    /// same invariant as the background-pills click below.
    @MainActor func presentCommandBar(drawer: CommandBarDrawerTab? = nil) {
        guard let appState = AppState.shared else { return }
        let manager = commandBarWindowManager ?? CommandBarWindowManager()
        commandBarWindowManager = manager
        manager.show(appState: appState)
        if let drawer, !appState.recordingManager.isRecording {
            manager.morph(to: .barWithDrawer(drawer))
        }
    }

    // MARK: - Onboarding (redesign phase 5)

    /// First-launch door: shows the step the pure OnboardingFlow picks, or nothing.
    /// Retries briefly for the same reason bootstrapCommandBar does — AppState is
    /// built in the SwiftUI App's init, normally before launch finishes.
    @MainActor private func presentOnboardingAtLaunchIfNeeded(retriesLeft: Int = 3) {
        guard let appState = AppState.shared,
              let permissionsManager = PermissionsManager.shared else {
            guard retriesLeft > 0 else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.presentOnboardingAtLaunchIfNeeded(retriesLeft: retriesLeft - 1)
            }
            return
        }
        let manager = onboardingWindowManager ?? OnboardingWindowManager()
        onboardingWindowManager = manager
        manager.presentAtLaunchIfNeeded(appState: appState, permissionsManager: permissionsManager)
    }

    /// Permission-gate door: a recording start was refused because Screen Recording
    /// is missing — re-open onboarding at step 1, completed or not.
    @MainActor func presentOnboardingPermissionStep() {
        guard let appState = AppState.shared,
              let permissionsManager = PermissionsManager.shared else { return }
        let manager = onboardingWindowManager ?? OnboardingWindowManager()
        onboardingWindowManager = manager
        manager.present(step: .permission, appState: appState, permissionsManager: permissionsManager)
    }

    // MARK: - Command Bar (redesign phase 2)

    /// Brings the command bar up and repeats the launch bootstrap that used to live only
    /// in MainView.onAppear (device refresh, hotkeys, Dropbox sync) — the bar can't rely
    /// on the old window's view graph once phase 7 removes it. Running both is safe: the
    /// refreshes are idempotent re-enumerations and hotkeyManager.start has an
    /// isStarted guard.
    @MainActor private func bootstrapCommandBar(retriesLeft: Int = 3) {
        guard let appState = AppState.shared else {
            // AppState is built in the SwiftUI App's init, which normally runs before
            // launch finishes — but don't bet the launch path on that ordering.
            guard retriesLeft > 0 else {
                LogManager.shared.log("🎛️ Command bar: AppState never appeared — bar not shown", type: .error)
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.bootstrapCommandBar(retriesLeft: retriesLeft - 1)
            }
            return
        }

        appState.cameraManager.refreshDevices()
        appState.recordingManager.audioCaptureManager.refreshDevices()
        appState.hotkeyManager.start(appState: appState)
        Task { await appState.syncDropboxState() }

        let manager = commandBarWindowManager ?? CommandBarWindowManager()
        commandBarWindowManager = manager
        manager.show(appState: appState)

        // Phase 4: the background-activity pills ride alongside the bar. A click on
        // any pill is a shortcut to the details — the bar's Gallery drawer.
        let pills = backgroundPillsWindowManager ?? BackgroundPillsWindowManager()
        backgroundPillsWindowManager = pills
        pills.attach(appState: appState) { [weak self] in
            guard let self, let appState = AppState.shared,
                  let bar = self.commandBarWindowManager else { return }
            // Mid-take the bar IS the recording pill — expanding it into a drawer
            // would break the "recording → pill" invariant, so the click waits.
            guard !appState.recordingManager.isRecording else { return }
            bar.show(appState: appState)
            bar.morph(to: .barWithDrawer(.gallery))
        }
    }

    // MARK: - Main window

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

