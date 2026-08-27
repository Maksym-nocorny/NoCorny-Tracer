import SwiftUI
import Sparkle

/// NoCorny Tracer — A macOS screen recording app with Dropbox sync
///
/// Phase 7 of the redesign: the app has NO SwiftUI windows any more. The whole
/// surface is imperative AppKit panels owned by the AppDelegate — the floating
/// command bar (with its Gallery/Settings drawers), the recording pill, toasts,
/// the storage banner, the camera bubble, the onboarding card and the tray.
/// The `Settings` scene below is a required
/// placeholder: a SwiftUI `App` must declare at least one scene.
@main
struct NoCornyTracerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// `AppState.shared` is a WEAK static — this @State is what actually keeps
    /// the app's state alive for the lifetime of the process.
    @State private var appState = AppState()
    /// Same deal: `PermissionsManager.shared` is weak, this reference retains it.
    @State private var permissionsManager: PermissionsManager

    // Sparkle auto-updater
    private let updaterController: SPUStandardUpdaterController
    /// Held for the lifetime of the app: Sparkle keeps both delegates weakly.
    private let updateCoordinator: UpdateCoordinator

    init() {
        // Register custom fonts from the app bundle
        Theme.Typography.registerFonts()

        // Sparkle (4.2.0, the Claude Code way): scheduled checks download and
        // stage silently (SUAutomaticallyUpdate in Info.plist), the coordinator's
        // "Relaunch to update" chip is the only scheduled-update UI (it is the
        // userDriverDelegate's gentle reminders), and an ignored chip still
        // installs on the next quit. Manual checks stay Sparkle-standard.
        let coordinator = UpdateCoordinator()
        self.updateCoordinator = coordinator
        let updater = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: coordinator,
            userDriverDelegate: coordinator
        )
        self.updaterController = updater

        let pManager = PermissionsManager(updaterController: updater)
        self._permissionsManager = State(initialValue: pManager)

        // Read live rather than captured: the app almost always launches with no recording
        // running, so a captured value would always say "go ahead".
        coordinator.isRecording = { AppState.shared?.recordingManager.isRecording ?? false }

        // Round 7: 5-minute background checks on our own timer — Sparkle's
        // scheduler bottoms out at an hour (the plist's 3600 stays as a safety
        // net). Started here, right after startingUpdater: true.
        coordinator.startPolling(updater: updater.updater)

        // Hand Sparkle to the AppDelegate through a static rather than by touching
        // `appDelegate` here: the adaptor's timing in `init` is an implementation
        // detail, the static is deterministic. Consumed in applicationDidFinishLaunching;
        // the Settings drawer reaches it via (NSApp.delegate as? AppDelegate).
        AppDelegate.bootstrapUpdaterController = updater
    }

    var body: some Scene {
        // Zero windows (phase 7). `Settings { EmptyView() }` is the standard
        // agent-style-app placeholder scene. Known compromise: the app menu's
        // "Settings…" (⌘,) — visible on the rare occasions the app is active,
        // e.g. during onboarding — opens this empty window. The real Settings
        // live in the command bar's drawer (tray menu → Settings…).
        Settings { EmptyView() }
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

    // Sparkle updater (set from NoCornyTracerApp via the bootstrap static)
    var updaterController: SPUStandardUpdaterController?
    /// One-way handoff from the SwiftUI App's init — see the note there.
    static var bootstrapUpdaterController: SPUStandardUpdaterController?

    /// The floating command bar of the redesign (phase 2). Owned here rather than as
    /// App @State because it must come up at launch and from the tray menu — since
    /// phase 7 there is no window view graph anywhere to hang it off.
    @MainActor var commandBarWindowManager: CommandBarWindowManager?

    /// The onboarding window (phase 5) — owned here because both of its doors
    /// (first launch, permission gate) can open with no SwiftUI window anywhere.
    @MainActor var onboardingWindowManager: OnboardingWindowManager?

    /// Toasts (phase 4) — owned here since phase 7: the old main window's host
    /// used to wire the present* closures, and the window is gone.
    @MainActor var toastWindowManager: ToastWindowManager?

    /// The floating camera bubble — owned here since phase 7 for the same reason:
    /// its visibility used to be driven by the main window's .onChange.
    @MainActor var cameraWindowManager: CameraWindowManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        updaterController = Self.bootstrapUpdaterController

        // URL handler for Tracer browser sign-in (nocornytracer://...).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleProcessURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // The command bar IS the app now (phase 7): tray first, then the bar and
        // its wiring, then the first-launch onboarding check (which runs AFTER
        // the bar so the card lands on top of it).
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setupStatusItemController()
            self.bootstrapCommandBar()
            self.presentOnboardingAtLaunchIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Moved from the old MainView's .onReceive(didBecomeActive) in phase 7,
        // same isSignedIn gate: refresh when the user switches back to the app
        // (e.g. after renaming a video on tracer.nocorny.com in their browser).
        // Entitlements too — someone who just upgraded in the browser switches
        // straight back here expecting it to have taken effect.
        guard let appState = AppState.shared, appState.tracerAPIClient.isSignedIn else { return }
        Task { await appState.reloadRecordingsFromTracer() }
        Task { await appState.tracerAPIClient.refreshProfile() }
    }

    // MARK: - Tray (redesign phase 5)

    @MainActor private func setupStatusItemController() {
        let controller = StatusItemController(actions: .init(
            showCommandBar: { [weak self] in self?.presentCommandBar() },
            showGallery: { [weak self] in self?.presentCommandBar(drawer: .gallery) },
            showSettings: { [weak self] in self?.presentCommandBar(drawer: .settings) },
            // Round 3: the tray tells "stop the take" from "bring the hidden pill
            // back" by whether the panel is on screen.
            isCommandBarVisible: { [weak self] in self?.commandBarWindowManager?.isPanelVisible ?? false }
        ))
        statusItemController = controller
        controller.attach()
    }

    /// Fronts the command bar (creating it if needed) and optionally opens a drawer.
    /// Mid-take the bar IS the recording pill — the drawer morph is skipped then,
    /// so the "recording → pill" invariant holds.
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

    /// Brings the command bar up, runs the launch bootstrap that used to live in
    /// MainView.onAppear (device refresh, hotkeys, Dropbox sync), and — since
    /// phase 7 — owns the present* closure wiring that used to live in the old
    /// main window's host view. The refreshes are idempotent re-enumerations and
    /// hotkeyManager.start has an isStarted guard, so re-running is safe.
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

        wirePresentationClosures(appState: appState)

        appState.cameraManager.refreshDevices()
        appState.recordingManager.audioCaptureManager.refreshDevices()
        appState.hotkeyManager.start(appState: appState)
        Task { await appState.syncDropboxState() }

        let manager = commandBarWindowManager ?? CommandBarWindowManager()
        commandBarWindowManager = manager
        manager.show(appState: appState)

        // The background-activity pills panel died in round 7 (boss's verdict):
        // in-flight work now shows in the library rows (per-recording progress),
        // the tray's "↑N" and the Gallery button badge — both fed by the same
        // BackgroundActivity mappings the pills used to read.
    }

    /// The present* closures (phase 7): every AppState "surface this" hook lands on
    /// a floating panel the delegate owns. They used to be wired in the main
    /// window's .onAppear; the window is gone and the delegate always exists —
    /// which is the whole reason these are closures in the first place (they fire
    /// from the pipeline / hotkeys, with no window anywhere).
    @MainActor private func wirePresentationClosures(appState: AppState) {
        let toasts = toastWindowManager ?? ToastWindowManager()
        toastWindowManager = toasts

        // Both the noise suggestion and the info toasts share the one ToastWindowManager.
        appState.presentNoiseSuggestion = { [weak toasts] show in
            guard let appState = AppState.shared else { return }
            toasts?.updateNoiseSuggestion(show: show, appState: appState)
        }
        appState.presentToast = { [weak toasts] toast in
            guard let appState = AppState.shared else { return }
            toasts?.show(toast: toast, appState: appState)
        }

        // A start blocked on Screen Recording re-opens onboarding step 1, which
        // explains the grant AND the relaunch it needs. Mic/camera can only be
        // missing here when the user DENIED them earlier (undetermined ones get
        // the system prompt inside ensureRecordingPermissions) — onboarding can't
        // help with a denial, so those go straight to System Settings.
        appState.presentPermissionsGate = { [weak self] missing in
            NSApp.activate(ignoringOtherApps: true)
            if missing.contains(.screenRecording) {
                self?.presentOnboardingPermissionStep()
            } else if let first = missing.first {
                PermissionsManager.openSystemSettings(for: first)
            }
        }

        // A start refusal used to be an alert on the main window; phase 7 makes it
        // a toast — the message is already written for people (startFailureMessage).
        // Round 3: the toast now comes WITH the command bar. A start can be refused
        // right after the area overlay closed (Enter → engine says no) or from a
        // hotkey with the bar hidden — a toast that fades over an empty desk left
        // the user with no surface at all («минулого разу викинуло»). Re-showing
        // an already-visible bar is a harmless re-front.
        appState.presentStartFailure = { [weak self, weak toasts] in
            guard let appState = AppState.shared else { return }
            toasts?.show(toast: ToastContent(
                icon: "exclamationmark.triangle.fill",
                iconColor: Theme.Colors.recordRed,
                message: appState.startRecordingFailure ?? "The recording could not be started",
                duration: 6
            ), appState: appState)
            Task { @MainActor [weak self] in
                self?.presentCommandBar()
            }
        }

        // Nothing sets uploadFailureNotice today (out-of-space became toast+banner in
        // phase 4), but the door stays wired so a future notice surfaces instead of
        // vanishing silently.
        appState.presentUploadFailure = { [weak toasts] in
            guard let appState = AppState.shared else { return }
            toasts?.show(toast: ToastContent(
                icon: "exclamationmark.triangle.fill",
                iconColor: Theme.Colors.pausedAmber,
                message: appState.uploadFailureNotice ?? "Upload failed",
                duration: 6
            ), appState: appState)
        }

        // The camera bubble used to follow the main window's .onChange(of:
        // isCameraEnabled); AppState now announces the flip itself.
        let camera = cameraWindowManager ?? CameraWindowManager()
        cameraWindowManager = camera
        appState.presentCameraOverlay = { [weak camera] enabled in
            guard let appState = AppState.shared else { return }
            camera?.updateVisibility(isEnabled: enabled, appState: appState)
        }
        // Restore the bubble at launch if the camera was left enabled.
        camera.updateVisibility(isEnabled: appState.isCameraEnabled, appState: appState)
    }

    // MARK: - Reopen (Dock click)

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Dock click summons the command bar — there is no main window any more.
        // `flag` is deliberately ignored: since round 12 the bar IS an ordinary
        // visible window, so a Dock click on a bar that is merely buried behind
        // another app would otherwise do nothing. `show()` is idempotent and
        // re-orders the existing panel to the front, which is exactly the answer
        // in both cases. (The app never auto-quits on the last window closing —
        // `applicationShouldTerminateAfterLastWindowClosed` is left at AppKit's
        // false, and hiding the bar is a hide, not a quit.)
        Task { @MainActor [weak self] in
            self?.presentCommandBar()
        }
        return true
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
        // exists — since phase 7 there is no window whose view hierarchy could
        // observe it, and even before that a closed window silently dropped the
        // callback, leaving the user stuck mid-sign-in.
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
