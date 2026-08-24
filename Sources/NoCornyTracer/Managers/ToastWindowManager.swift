import SwiftUI
import AppKit

// MARK: - Toast content

/// What an info toast shows: SF icon + one line of text + an optional action button.
/// The first client is "Uploaded — link copied" (Figma 88:762); anything transient
/// and glanceable belongs here rather than in a modal alert.
struct ToastContent {
    /// How hard a toast fights for the single panel. `.info` is glanceable good news
    /// ("Uploaded — link copied") that any newer toast may shove aside; `.critical` is
    /// something the user must act on while it matters (the microphone dying mid-take)
    /// and holds the panel for its whole duration against `.info` arrivals.
    enum Priority {
        case info
        case critical
    }

    var icon: String
    var iconColor: Color = Theme.Colors.statusGreen
    var message: String
    var buttonTitle: String?
    var buttonAction: (() -> Void)?
    /// Info toasts default to 4s; the noise-suggestion toast keeps its historical 12s.
    var duration: TimeInterval = 4
    var priority: Priority = .info
}

/// Pure decision for the after-upload moment: what goes to the pasteboard and what
/// the toast says. A recording can (rarely) finish uploading with no share URL at
/// all — then we announce the upload without pretending a link was copied.
enum UploadCompletionNotice {
    static func decision(shareURL: URL?) -> (copyText: String?, message: String) {
        guard let shareURL else { return (nil, "Uploaded") }
        return (shareURL.absoluteString, "Uploaded — link copied")
    }
}

// MARK: - Panel

/// A floating panel that can host clickable controls (buttons) without activating the
/// whole app. `.nonactivatingPanel` keeps focus where it is (the recording flow isn't
/// disrupted), while `canBecomeKey` lets the buttons receive clicks.
private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Manager

/// One floating toast panel near the top-center of the active screen, generalized from
/// the old NoiseSuggestionWindowManager (which this replaces): the same nonactivating
/// NSPanel recipe now serves both the simple info toasts (`show(toast:)`) and the
/// richer noise-reduction suggestion (`updateNoiseSuggestion`), which keeps its exact
/// three-button content and 12s auto-dismiss.
///
/// One panel, latest content wins — with one exception: a live `.critical` toast keeps
/// the panel against `.info` arrivals until its duration runs out (see `shouldReplace`).
/// `sharingType = .none` keeps toasts out of the recording itself.
@Observable
final class ToastWindowManager {
    private var window: NSPanel?
    private var dismissTimer: Timer?

    /// What the panel is holding right now, for the replacement decision: the priority of
    /// the content and when its duration runs out. Cleared by `hideWindow`. The noise
    /// suggestion counts as `.info` — it is advice, not an emergency.
    private var shownPriority: ToastContent.Priority?
    private var shownUntil: Date?
    /// Whether the panel's current content is the noise suggestion specifically, so
    /// `updateNoiseSuggestion(show: false)` only tears down its own content.
    private var isShowingNoiseSuggestion = false

    // MARK: Replacement policy (pure, covered by ToastReplacementPolicyTests)

    /// May `incoming` take the panel from what is showing? Pure so the answer is testable
    /// without a panel. `current` nil (or a duration that already ran out) means the panel
    /// is free — anything may present. `.critical` replaces anything, including an older
    /// critical toast: newer news of the same weight wins. `.info` replaces `.info` (the
    /// historical "latest wins") but never a critical toast that is still inside its
    /// duration. The losing info toast is DROPPED, not queued: it is glanceable, momentary
    /// news, and replaying it after the critical toast would surface stale information at
    /// a random later moment.
    static func shouldReplace(
        current: ToastContent.Priority?,
        remaining: TimeInterval,
        incoming: ToastContent.Priority
    ) -> Bool {
        guard let current, remaining > 0 else { return true }
        if incoming == .critical { return true }
        return current != .critical
    }

    /// The `remaining` argument for the policy, read off the panel's bookkeeping.
    private var remainingSeconds: TimeInterval {
        shownUntil?.timeIntervalSinceNow ?? 0
    }

    // MARK: Info toasts

    func show(toast: ToastContent, appState: AppState) {
        onMain { [self] in
            guard Self.shouldReplace(current: shownPriority,
                                     remaining: remainingSeconds,
                                     incoming: toast.priority) else {
                // Dropped, not queued — see shouldReplace. The log keeps the drop visible.
                LogManager.shared.log("🔔 Toast dropped (critical toast on screen): \(toast.message)")
                return
            }
            present(rootView: AnyView(InfoToastView(content: toast)), appState: appState)
            shownPriority = toast.priority
            shownUntil = Date().addingTimeInterval(toast.duration)
            isShowingNoiseSuggestion = false
            // Self-dismiss: nothing outside tracks an info toast's visibility.
            scheduleDismiss(after: toast.duration) { [weak self] in
                self?.hideWindow()
            }
        }
    }

    // MARK: Noise suggestion (migrated 1:1)

    /// Show/hide driven by `appState.showNoiseSuggestion` via the
    /// `presentNoiseSuggestion` closure in the app scene, exactly as before.
    func updateNoiseSuggestion(show: Bool, appState: AppState) {
        onMain { [self] in
            if show {
                guard Self.shouldReplace(current: shownPriority,
                                         remaining: remainingSeconds,
                                         incoming: .info) else {
                    // Blocked by a critical toast. Reset the AppState flag rather than
                    // leaving `showNoiseSuggestion` latched true with nothing on screen,
                    // which would block every later suggestion for the whole session.
                    appState.dismissNoiseSuggestion(forever: false)
                    return
                }
                present(rootView: AnyView(NoiseSuggestionToastView(appState: appState)), appState: appState)
                shownPriority = .info
                shownUntil = Date().addingTimeInterval(12.0)
                isShowingNoiseSuggestion = true
                // Auto-dismiss goes through AppState (not a plain hide) so
                // `showNoiseSuggestion` is reset and the suggestion can re-arm.
                scheduleDismiss(after: 12.0) { [weak appState] in
                    appState?.dismissNoiseSuggestion(forever: false)
                }
            } else {
                // Hiding the suggestion must not take down a critical toast that already
                // replaced it (dismissNoiseSuggestion hides unconditionally otherwise).
                if shownPriority == .critical, remainingSeconds > 0, !isShowingNoiseSuggestion {
                    return
                }
                hideWindow()
            }
        }
    }

    // MARK: Plumbing

    private func present(rootView: AnyView, appState: AppState) {
        dismissTimer?.invalidate()
        dismissTimer = nil

        let hostingController = NSHostingController(rootView: rootView)

        let panel: NSPanel
        if let window {
            panel = window
            panel.contentViewController = hostingController
        } else {
            panel = ToastPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hostingController
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Toasts appear DURING recording, while the app is usually inactive —
            // and must never join the capture themselves.
            panel.hidesOnDeactivate = false
            panel.sharingType = .none
            panel.isReleasedWhenClosed = false
            window = panel
        }

        // The toast follows the in-app theme like every other floating panel.
        panel.appearance = NSAppearance.from(appState.appTheme)

        // Size to the SwiftUI content, then position near top-center of the active screen.
        let fitting = hostingController.view.fittingSize
        panel.setContentSize(fitting)
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let origin = NSPoint(
                x: visible.midX - fitting.width / 2,
                y: visible.maxY - fitting.height - 24
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
    }

    private func scheduleDismiss(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            action()
        }
    }

    private func hideWindow() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        window?.orderOut(nil)
        window = nil
        shownPriority = nil
        shownUntil = nil
        isShowingNoiseSuggestion = false
    }

    /// AppState's closures fire from async pipeline contexts as well as the main
    /// thread; AppKit work must land on main either way.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - Info toast view

/// The glanceable capsule (macro 88:762: height 44, radius 22, icon 13, text 12).
/// Width hugs the text so "Uploaded" and a longer failure line both sit right.
private struct InfoToastView: View {
    let content: ToastContent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: content.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(content.iconColor)

            Text(content.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.textPrimary.opacity(0.9))
                .lineLimit(1)

            if let title = content.buttonTitle {
                Button(title) { content.buttonAction?() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary.opacity(0.7))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(height: 44)
        .fixedSize()
        .glassSurface(cornerRadius: 22)
    }
}

// MARK: - Noise suggestion view (moved verbatim from NoiseSuggestionWindowManager)

/// The compact suggestion card shown inside the floating panel.
private struct NoiseSuggestionToastView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Colors.orange)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Noisy environment detected")
                    .font(Theme.Typography.body(13, weight: .semibold))

                Text("Turn on noise reduction for your next recordings?")
                    .font(Theme.Typography.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Enable") {
                        appState.enableNoiseReductionFromSuggestion()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Not now") {
                        appState.dismissNoiseSuggestion(forever: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Don't suggest again") {
                        appState.dismissNoiseSuggestion(forever: true)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .font(Theme.Typography.body(10, weight: .light))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(width: 320, alignment: .leading)
        .cardStyle()
    }
}
