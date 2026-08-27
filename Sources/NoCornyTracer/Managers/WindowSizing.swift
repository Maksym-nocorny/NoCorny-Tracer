import SwiftUI
import AppKit
import ObjectiveC

/// WHO OWNS A WINDOW'S SIZE — us, or SwiftUI. In this app the answer is always
/// "us", and this is the one place that says so.
///
/// ROUND 14 — the same production crash, THIRD day, and the first time we know
/// which window it is. Four reports now: two on 4.5.0 (16:49) and two on 4.5.1
/// (18:23, 18:29), every one of them while a take was running with the camera
/// on. The `.ips` files do not carry the exception text, but the unified log
/// does, and it is the same in all four:
///
///     The window has been marked as needing another Update Constraints in
///     Window pass, but it has already had more Update Constraints in Window
///     passes than there are views in the window.
///     <NoCornyTracer.CommandBarPanel: 0x…> {{1494, 1066}, {486, 199}}
///
///     Incrementing window 0x… update constraints count (was 44) …
///     Marking window 0x… as needing Update Constraints in Window
///     (limit: 43, count: 45)
///
/// So: THE COMMAND BAR, not the camera bubble. Round 13 read a stand's exception
/// instead of the battlefield's and spent a release hardening the wrong window —
/// which is why 4.5.1 crashed exactly like 4.5.0. 486×199 is the bar∪pill UNION
/// frame, i.e. the crash lands during the bar→pill morph flight, and the app log
/// puts it 1–7s after "Recording Actually Started" every time. AppKit's budget is
/// the window's view count (43); the runaway blew it at 45.
///
/// THE LOOP, from the crash's own stack:
///
///     NSWindow.layoutIfNeeded → NSHostingView.windowDidLayout()
///       → NSHostingView.updateAnimatedWindowSize(_:)   ← SwiftUI writes the frame
///       → NSWindow._setFrameCommon → NSNextStepFrame.setFrameSize
///       → KVO → NSHostingView.invalidateSafeAreaInsets()
///       → requestUpdate → NSView.setNeedsUpdateConstraints:
///       → NSWindow._postWindowNeedsUpdateConstraints  ← «one more pass»
///
/// WHY `sizingOptions = []` WAS NOT ENOUGH — the round-13 fix that shipped and
/// did not work. Disassembling `NSHostingView.windowDidLayout` (stand r14, run 8)
/// shows the write is gated on an INTERNAL `WindowSizeBridge`, not on our
/// property:
///
///     x20 = self.<windowSizeBridge>;  if x20 == nil { return }
///     WindowSizeBridge.clampedWindowSize(minSize:maxSize:) -> CGSize?
///     if result == nil { return }
///     → updateAnimatedWindowSize(result)
///
/// `sizingOptions` is one input to whether that bridge exists. It is a REQUEST,
/// not a wall, and the bar proved in production that the bridge can be alive
/// anyway. So round 14 stops asking and takes the channel away.
///
/// THE WALL: **no hosting view is ever a window's `contentView`.** A plain shell
/// view controller owns the content rect; the SwiftUI host is its CHILD, filling
/// it by autoresizing mask. SwiftUI then has no window to write — it only ever
/// sees a subview's bounds. Stand-measured (r14, runs 8/9) across every option
/// set including SwiftUI's own default — a window handed a size its content does
/// not want, then pumped through real layout passes:
///
///     hosting IS contentView, .standardBounds       → SwiftUI resized the window
///     hosting IS contentView, .maxSize              → SwiftUI resized the window
///     hosting IS contentView, .intrinsicContentSize → our size held
///     hosting IS contentView, []                    → our size held
///     hosting WRAPPED, every one of the four        → our size held
///
/// Note rows three and four: `[]` DOES hold on a stand, and it still shipped in
/// 4.5.1 and crashed. That is the whole lesson. `sizingOptions` decides what
/// SwiftUI ASKS FOR; the bridge decides whether it writes, and the bridge does
/// not answer to us. The pin below stays as defence in depth — it costs nothing
/// and it is what makes SwiftUI stop wanting the window — but the invariant that
/// is actually enforceable, and that `HostingWindowSizingTests` checks by
/// building real windows rather than by reading source text, is the wall.
///
/// MEASURING, once SwiftUI is behind the wall. `fittingSize` is only filled in
/// under `.intrinsicContentSize` and `.standardBounds`; under `[]` and `.maxSize`
/// it is (0, 0) and `intrinsicContentSize` is (-1, -1) (stand r14, run 5). Rather
/// than keep a second, weaker option set alive just so two windows can read a
/// number — the round-13 `measuredByUsOnly`, which was correct but bought us a
/// second rule to remember — `measure(_:)` takes the reading on a DETACHED probe
/// controller, which works under every option set and returns the same numbers
/// the toast and the onboarding card were already getting. One rule everywhere:
/// every host is `[]`, every size is measured detached and applied by us.
enum WindowSizing {

    /// SwiftUI does not move the window and does not report a size:
    /// `fittingSize` is (0, 0), `intrinsicContentSize` is (-1, -1). Every window
    /// in this app uses it; measurement goes through `measure(_:)` instead.
    static let ownedByUs: NSHostingSizingOptions = []

    /// CAN such a set drive a window? Kept because it names the danger, and
    /// because `windowsDrivenBySwiftUI()` reports it. NOTE (round 14): a `false`
    /// here is NOT a safety guarantee — `[]` shipped in 4.5.1 and the bar still
    /// resized itself. Only the wall (`install(_:in:)`) is a guarantee.
    static func mayResizeWindow(_ options: NSHostingSizingOptions) -> Bool {
        !options.intersection([.minSize, .maxSize, .preferredContentSize]).isEmpty
    }

    /// Takes the wheel away from SwiftUI on both objects that carry the setting:
    /// the controller's value is not guaranteed to reach a view it did not make,
    /// and AppKit asks the VIEW.
    @discardableResult
    static func pin<Content: View>(
        _ controller: NSHostingController<Content>,
        to options: NSHostingSizingOptions = []
    ) -> NSHostingController<Content> {
        controller.sizingOptions = options
        if let hosting = controller.view as? NSHostingView<Content> {
            hosting.sizingOptions = options
        }
        return controller
    }

    /// Same for a bare `NSHostingView`.
    @discardableResult
    static func pin<Content: View>(
        _ hosting: NSHostingView<Content>,
        to options: NSHostingSizingOptions = []
    ) -> NSHostingView<Content> {
        hosting.sizingOptions = options
        return hosting
    }

    // MARK: - The wall

    /// The window's real content view: a plain AppKit view that owns the whole
    /// content rect. Nothing SwiftUI can reach through.
    ///
    /// The host is laid out EXPLICITLY rather than by autoresizing mask. Two
    /// reasons, both real here: `CommandBarPanel` is created with
    /// `contentRect: .zero` and only gets its frame from `morph`, and an
    /// autoresizing mask distributes a resize proportionally against the OLD
    /// size — which is degenerate when the old size is zero. And this container
    /// also carries the theme-fade snapshot overlay
    /// (`CommandBarWindowManager.applyPanelAppearance(smooth:)`), which must be
    /// left exactly where it was put, so only the host is touched.
    final class HostContainerView: NSView {
        weak var host: NSView?

        override func layout() {
            super.layout()
            if let host, host.frame != bounds { host.frame = bounds }
        }
    }

    /// THE ONLY WAY THIS APP PUTS SWIFTUI IN A WINDOW.
    ///
    /// Pins the host (defence in depth), then installs it as a CHILD of a plain
    /// shell view controller whose view becomes `window.contentView`. Ordinary
    /// AppKit containment, so appearance callbacks and retention behave exactly
    /// as they did when the host was the content view controller — the single
    /// difference is that SwiftUI is no longer looking at a window.
    ///
    /// Replaces whatever content the window had (the toast re-roots its one
    /// panel for every message, the onboarding card for every step).
    @discardableResult
    static func install<Content: View>(
        _ controller: NSHostingController<Content>,
        in window: NSWindow,
        sizing options: NSHostingSizingOptions = []
    ) -> NSHostingController<Content> {
        pin(controller, to: options)

        let container = HostContainerView(
            frame: NSRect(origin: .zero, size: window.contentRect(forFrameRect: window.frame).size)
        )
        let shell = NSViewController()
        shell.view = container
        shell.addChild(controller)

        let hosting = controller.view
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = []
        hosting.frame = container.bounds
        container.addSubview(hosting)
        container.host = hosting
        container.needsLayout = true

        window.contentViewController = shell

        assert(!isSwiftUIHost(window.contentView),
               "a hosting view reached window.contentView — SwiftUI can resize this window from inside its layout pass (round 14)")
        return controller
    }

    // MARK: - Measuring without a window

    /// What a SwiftUI tree WANTS to be, read off a controller that is not in any
    /// window. `sizeThatFits(in:)` is the one reading that works under EVERY
    /// option set, `[]` included (stand r14, run 5) — `fittingSize` needs
    /// `.intrinsicContentSize` or `.standardBounds` to report at all, and asking
    /// two windows to keep a different option set just to read a number is how
    /// the rule grows a second copy. Verified to return the same sizes the toast
    /// (189×60) and the noise card (352×114) were reading before.
    ///
    /// Callers size the window from this and then place it themselves. Main
    /// thread, like every other AppKit call around it — deliberately NOT
    /// `@MainActor`, because the window managers that need it (`present`) are
    /// plain methods reached through their own `onMain` hop.
    static func measure<Content: View>(_ view: Content) -> CGSize {
        let probe = NSHostingController(rootView: view)
        probe.sizingOptions = []
        return probe.sizeThatFits(in: CGSize(width: CGFloat.infinity, height: CGFloat.infinity))
    }

    // MARK: - The runtime audit (what the tests assert, and DEBUG shouts about)

    /// Is this view a SwiftUI host? `NSHostingView` is generic, so a plain
    /// `is NSHostingView<X>` only ever recognises one Content — the class chain
    /// is what actually answers the question for all of them.
    static func isSwiftUIHost(_ view: NSView?) -> Bool {
        guard let view else { return false }
        var cls: AnyClass? = type(of: view)
        while let current = cls {
            let swiftName = String(describing: current)
            let objcName = NSStringFromClass(current)
            if swiftName.contains("NSHostingView") || objcName.contains("NSHostingView") {
                return true
            }
            cls = class_getSuperclass(current)
        }
        return false
    }

    /// Every window whose content view IS a SwiftUI host — i.e. every window
    /// SwiftUI can resize from inside a layout pass. Must always be empty.
    /// Read at RUNTIME on purpose: round 13's inventory scanned source text and
    /// passed while the shipped app crashed.
    @MainActor
    static func windowsDrivenBySwiftUI() -> [NSWindow] {
        NSApplication.shared.windows.filter { isSwiftUIHost($0.contentView) }
    }

    /// Called after the app has its windows up. Fails loudly in DEBUG; in
    /// release it leaves a line in the log so the next report names the window
    /// instead of making us read a disassembly for it.
    @MainActor
    static func auditWindows() {
        let offenders = windowsDrivenBySwiftUI()
        guard !offenders.isEmpty else { return }
        let names = offenders.map { "\(type(of: $0)) \($0.frame)" }.joined(separator: ", ")
        LogManager.shared.log(
            "🪟 Window sizing: SwiftUI owns the content view of \(names) — it can resize the window from inside layout (round 14)",
            type: .error
        )
        assertionFailure("SwiftUI-driven window(s): \(names)")
    }
}
