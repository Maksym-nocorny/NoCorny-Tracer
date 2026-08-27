import AppKit
import SwiftUI

// MARK: - Which step to show (pure)

/// The onboarding steps of the redesign (Figma 86:551): one permission card, one
/// "where should clips live" card. `none` means there is nothing left to onboard.
enum OnboardingStep: Equatable {
    case permission   // step 1 — "One permission to start"
    case cloud        // step 2 — "Where should clips live?"
    case none
}

enum OnboardingFlow {
    /// UserDefaults key flipped by finishing (sign-in or "Skip for now").
    static let completedDefaultsKey = "hasCompletedOnboarding"

    /// Pure decision so it's testable: screen permission first, then the cloud
    /// question, and nothing once onboarding has been completed. Note the
    /// permission check outranks `hasCompletedOnboarding` NOT here but at the
    /// call sites: the permission gate (`presentPermissionsGate`) re-opens step 1
    /// explicitly whenever a recording is blocked, completed or not.
    static func step(
        hasScreenPermission: Bool,
        isSignedIn: Bool,
        hasCompletedOnboarding: Bool
    ) -> OnboardingStep {
        if hasCompletedOnboarding { return .none }
        if !hasScreenPermission { return .permission }
        if !isSignedIn { return .cloud }
        return .none
    }
}

// MARK: - Window

/// Borderless so the glass card IS the window (the macro card has no title bar).
/// Borderless windows refuse key status by default — override, or Esc and the
/// buttons' key handling never arrive.
private final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    var onEsc: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEsc?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {   // 53 = Esc
            onEsc?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Manager

/// Owns the onboarding window (redesign phase 5): an imperative, centered,
/// borderless NSWindow — NOT a SwiftUI scene, so it can come up at launch and from
/// the permissions gate with no view graph anywhere.
@MainActor
@Observable
final class OnboardingWindowManager {
    private var window: OnboardingWindow?
    private weak var permissionsManager: PermissionsManager?

    var isVisible: Bool { window?.isVisible ?? false }

    // MARK: Launch trigger

    /// Called once at launch: shows the step the pure function picks, or nothing.
    /// A user who already has both the permission and a session (upgrade from the
    /// pre-onboarding era) gets the completed flag set silently instead of a window.
    func presentAtLaunchIfNeeded(appState: AppState, permissionsManager: PermissionsManager) {
        let defaults = UserDefaults.standard
        let completed = defaults.bool(forKey: OnboardingFlow.completedDefaultsKey)
        let step = OnboardingFlow.step(
            hasScreenPermission: CGPreflightScreenCaptureAccess(),
            isSignedIn: appState.tracerAPIClient.isSignedIn,
            hasCompletedOnboarding: completed
        )
        switch step {
        case .none:
            if !completed {
                defaults.set(true, forKey: OnboardingFlow.completedDefaultsKey)
            }
        case .permission, .cloud:
            present(step: step, appState: appState, permissionsManager: permissionsManager)
        }
    }

    // MARK: Presenting

    /// Shows the onboarding window at a step. Re-presenting while visible just
    /// re-fronts (and re-roots the view at the requested step).
    func present(step: OnboardingStep, appState: AppState, permissionsManager: PermissionsManager) {
        guard step != .none else { return }
        self.permissionsManager = permissionsManager

        let view = OnboardingView(
            appState: appState,
            permissionsManager: permissionsManager,
            manager: self,
            initialStep: step
        )
        let host = NSHostingController(rootView: view)
        // ROUND 13 (the 4.5.0 camera crash, same class): SwiftUI measures the
        // card, we place the window. The card CHANGES HEIGHT between steps
        // (320 → 300), which is precisely the "SwiftUI resizes its own window
        // mid-layout" shape that crashed the camera bubble — so `OnboardingView`
        // now boxes both steps into one fixed window and centres the card inside
        // it, and the window size below never has to move again. See
        // `WindowSizing`.
        WindowSizing.pin(host, to: WindowSizing.measuredByUsOnly)

        let window: OnboardingWindow
        if let existing = self.window {
            window = existing
            window.contentViewController = host
        } else {
            window = OnboardingWindow(
                contentRect: .zero,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = host
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false            // the SwiftUI card draws its own
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            // ROUND 12 (вердикт шефа 26.08). This card used to float above every
            // app and hide from capture, «like the bar» — and the bar itself has
            // since stopped doing both. The onboarding card is a window the user
            // READS AND WORKS IN, not a control for a live take: it is shown
            // active and key (see below), so an ordinary level costs it nothing,
            // and switching to another app should send it behind, exactly like
            // any window. Being visible to a screenshot is likewise correct now —
            // it is how a user reports a problem with the front door.
            //
            // The recording pill remains the ONLY always-on-top, never-captured
            // surface in the app; toasts stay floating because they are
            // notifications (see ToastWindowManager).
            window.level = .normal
            window.collectionBehavior = []
            window.sharingType = .readOnly
            self.window = window
        }

        // Esc closes only once the screen permission exists — before that the card
        // is the app's front door and dismissing it would strand the user.
        window.onEsc = { [weak self, weak permissionsManager] in
            guard permissionsManager?.isScreenRecordingGranted == true else { return }
            self?.finish()
        }

        // Same theme pin as every other surface of the redesign.
        window.appearance = NSAppearance.from(appState.appTheme)

        // The 1s permission polling already lives in the manager — the card's
        // Grant row goes green through it.
        permissionsManager.startMonitoring()

        // One size for both steps (round 13) — the card centres itself inside it,
        // so the shorter cloud card simply gets 10pt more transparent margin
        // above and below. `fittingSize` is still the measurement, it is just
        // asserted against the box rather than trusted blindly: a card that
        // outgrew the box would be clipped, and that must fail loudly in DEBUG
        // rather than ship as a cropped front door.
        let box = OnboardingView.windowContentSize
        #if DEBUG
        let fitting = host.view.fittingSize
        assert(fitting.width <= box.width + 0.5 && fitting.height <= box.height + 0.5,
               "onboarding card \(fitting) no longer fits its window box \(box)")
        #endif
        window.setContentSize(box)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Finishing

    /// Sign-in completed or "Skip for now": onboarding is done for good.
    func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingFlow.completedDefaultsKey)
        close()
    }

    /// Closes the window without deciding anything (used by the relaunch path,
    /// where the flag must stay unset so the relaunched app resumes at step 2).
    func close() {
        permissionsManager?.stopMonitoring()
        window?.orderOut(nil)
        window = nil
    }

    /// The screen-recording grant only takes effect after a relaunch (see the
    /// PermissionsManager notes). Recipe copied from AppDelegate's windowless
    /// recovery: spawn a fresh instance, then terminate this one.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
