import SwiftUI
import AppKit

// MARK: - Panel

/// The borderless floating panel that hosts the command bar.
///
/// `.nonactivatingPanel` + `canBecomeKey` is the NoiseSuggestionWindowManager recipe:
/// clicking the bar's buttons works without activating the whole app and yanking focus
/// out of whatever the user is recording. `hasShadow` is off because the SwiftUI content
/// draws the redesign's own shadow (`.floatingPanelShadow()`); `sharingType = .none`
/// keeps the bar out of screen captures — including our own recordings.
final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc fallback for the drawers: fires when the panel is key and nothing in the
    /// SwiftUI hierarchy consumed the key (`.onExitCommand` needs focus inside the
    /// drawer, which a nonactivating panel often doesn't have). Set by the manager.
    var onEsc: (() -> Void)?
    /// ⌘, toggles the Settings drawer (the hint the drawer header shows). Only
    /// works while the panel is key — same reach as Esc above.
    var onCmdComma: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onEsc { onEsc() } else { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEsc {   // 53 = Esc
            onEsc()
            return
        }
        super.keyDown(with: event)
    }

    // ⌘-shortcuts never reach keyDown — AppKit routes them through the key
    // window's performKeyEquivalent BEFORE the main menu. Intercepting here is
    // also what stops ⌘, from opening the empty placeholder Settings scene
    // (the documented phase-7 compromise) while the bar is key.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == ",",
           let onCmdComma {
            onCmdComma()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Drag clamp (round 6)

    /// Round 6 («тягну вікно вниз — меню заходить за екран»; «сам застосунок не
    /// повинен покидати рамки екрану взагалі»): the CameraOverlayWindow clamp
    /// recipe, adapted to the shadow apron — what must stay inside the visible
    /// frame is the LOGICAL glass rect, not the panel (which is `panelShadowInset`
    /// larger on every side; its transparent apron is SUPPOSED to hang past the
    /// edge when the glass sits flush against it). `constrainFrameRect` covers
    /// AppKit-driven placement including user drags, `setFrameOrigin` the
    /// origin-only path. Programmatic `setFrame` calls from the manager are left
    /// alone on purpose: they all come pre-clamped out of
    /// `MorphGeometry.targetFrame`, and clamping a mid-flight union frame would
    /// corrupt the flight's offset base. The manager's `panelWasDragged` re-clamp
    /// is the safety net for any path that slips both overrides (the camera
    /// window's delegate plays the same role).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Self.clampedToVisible(frameRect, screen: screen ?? self.screen ?? NSScreen.main)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        let proposed = NSRect(origin: point, size: frame.size)
        super.setFrameOrigin(
            Self.clampedToVisible(proposed, screen: self.screen ?? NSScreen.main).origin
        )
    }

    private static func clampedToVisible(_ frameRect: NSRect, screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return frameRect }
        return MorphGeometry.clampedPanelFrame(frameRect, visible: visible)
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        sharingType = .none
        // NSPanel hides itself when the app deactivates by default — the bar must stay.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }
}

// MARK: - Delegate

/// Persists the panel's position as the user drags it (the panel is
/// `isMovableByWindowBackground`, so moves happen without any code of ours
/// running). WHICH anchor a drag updates depends on the current surface — a
/// dragged recording pill must not clobber the bar's saved spot — so the
/// decision lives on the manager.
private final class CommandBarPanelDelegate: NSObject, NSWindowDelegate {
    weak var manager: CommandBarWindowManager?

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let logical = MorphGeometry.logicalFrame(forPanel: window.frame)
        // NSWindowDelegate callbacks arrive on the main thread.
        MainActor.assumeIsolated {
            manager?.panelWasDragged(toLogicalFrame: logical)
        }
    }
}

// MARK: - Manager

/// Owns the floating command-bar panel and morphs it between surfaces
/// (bar / bar+drawer / recording pill). Phase-2 scaffolding: the panel
/// coexists with the old main window until phase 7 dismantles the latter.
@Observable @MainActor
final class CommandBarWindowManager {
    typealias Surface = CommandBarSurface
    typealias DrawerTab = CommandBarDrawerTab

    /// The surface currently shown. The SwiftUI root switches on this.
    private(set) var surface: Surface = .bar

    /// Extra logical height under the bar while the storage banner is visible
    /// (`MorphGeometry.storageBannerExtent`, or 0). Only `.bar` renders the banner;
    /// the geometry ignores the value on every other surface.
    private(set) var bannerExtent: CGFloat = 0

    /// Bumped when Esc lands on the recording pill. The pill view observes this and
    /// opens its discard-confirmation popover (round 4) — a counter (not a Bool) so
    /// every press registers regardless of the previous value.
    private(set) var pillEscSignal = 0

    /// Extra logical width of the recording pill past its 341-pt base (round 3):
    /// the pill panel resizes DYNAMICALLY to its SwiftUI content — like the toast —
    /// for transient content the mockup doesn't draw (a 100+ minute timer wider
    /// than its 57-pt slot). Reported by the pill view via
    /// `setRecordingPillContentWidth`; only `.recordingPill` frames consume it.
    private(set) var pillExtraWidth: CGFloat = 0

    /// Whether the currently open drawer unfolds ABOVE the bar (verdict 26.08:
    /// upward ONLY when the drawer cannot fit below — `MorphGeometry.
    /// drawerOpensUpward`). The SwiftUI root reads this to flip the stack order
    /// and the pin edge. On close it stays TRUE until the deferred frame snap
    /// (round 5b): the bottom pin is what keeps the bar pixel-still while the
    /// drawer fades out above it inside the still-large panel.
    private(set) var drawerOpensUp = false

    /// True between a drawer close and its deferred frame snap (round 5b): the
    /// surface is already `.bar` but the panel deliberately still wears the
    /// drawer-sized frame so the removal fade + the Liquid Glass dematerialize
    /// can play out un-clipped. Anything that would reframe or persist anchors
    /// from the oversized frame must check this first.
    private var pendingDrawerCloseSnap = false

    /// The tab of a drawer mid-CLOSE (round 5c), nil otherwise. The closing
    /// drawer STAYS IN THE SWIFTUI TREE — still occupying its layout slot in
    /// the held panel frame — while its opacity animates to 0; only the
    /// deferred snap removes it, when nothing of it is visible any more.
    ///
    /// Why not a removal transition: burst-proven twice. A bare state change
    /// yanks the removed subtree in ONE frame (a transition's attached
    /// animation drives insertions, not removals), and putting the fade into
    /// the transaction animates the LAYOUT REFLOW too — the dying drawer
    /// slides across the bar's face while fading. Keeping the node in layout
    /// is the only variant where the drawer dissolves exactly in place.
    private(set) var closingDrawerTab: DrawerTab?

    /// How long the panel keeps the drawer-sized frame after a close (round 5b).
    /// Harness-measured: the 0.15s `drawerFade` plus the glass dematerialize
    /// tail end ~0.28s after the morph; 0.35s snaps with margin, and a snap that
    /// late changes no visible pixel (burst-verified, shots r5a-*).
    private static let drawerCloseSnapDelay: TimeInterval = 0.35

    private var panel: CommandBarPanel?
    private let panelDelegate = CommandBarPanelDelegate()
    private weak var appState: AppState?

    /// Logical TOP-LEFT of the BAR — the stable anchor every morph is computed
    /// from. Tracked explicitly (not re-derived from the panel frame) because an
    /// upward-opened drawer and the recording pill both put the panel somewhere
    /// the bar is NOT, and the bar must come back to exactly this point.
    private var barAnchor: CGPoint?

    // MARK: Persisted positions

    // The stored points are LOGICAL TOP-LEFT anchors (AppKit screen coordinates,
    // so top-left = (minX, maxY)). NSPoint isn't UserDefaults-storable; x/y are
    // two Doubles. The bar and the recording pill persist separately: the pill
    // has its own perch (top-center by default, wherever the user dragged it
    // afterwards — the camera bubble's contract), and neither position may
    // clobber the other.
    private static let anchorXKey = "commandBarOriginX"
    private static let anchorYKey = "commandBarOriginY"
    private static let pillAnchorXKey = "recordingPillOriginX"
    private static let pillAnchorYKey = "recordingPillOriginY"

    nonisolated static func saveAnchor(_ anchor: CGPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(anchor.x), forKey: anchorXKey)
        defaults.set(Double(anchor.y), forKey: anchorYKey)
    }

    nonisolated static func savedAnchor() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: anchorXKey) != nil,
              defaults.object(forKey: anchorYKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: anchorXKey),
                       y: defaults.double(forKey: anchorYKey))
    }

    nonisolated static func savePillAnchor(_ anchor: CGPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(anchor.x), forKey: pillAnchorXKey)
        defaults.set(Double(anchor.y), forKey: pillAnchorYKey)
    }

    nonisolated static func savedPillAnchor() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: pillAnchorXKey) != nil,
              defaults.object(forKey: pillAnchorYKey) != nil else { return nil }
        return CGPoint(x: defaults.double(forKey: pillAnchorXKey),
                       y: defaults.double(forKey: pillAnchorYKey))
    }

    /// The anchor a surface should be framed from: the pill has its own perch;
    /// everything else hangs off the bar anchor (lazily seeded on first use).
    /// Parameterized (round 5c) because a flight needs the TARGET surface's
    /// anchor while `surface` still holds the source.
    private func anchorFor(surface: Surface, visible: CGRect) -> CGPoint {
        if surface == .recordingPill {
            return Self.savedPillAnchor() ?? MorphGeometry.recordingPillTopLeft(visible: visible)
        }
        if let barAnchor { return barAnchor }
        let size = MorphGeometry.size(of: .bar, bannerHeight: bannerExtent)
        let origin = MorphGeometry.initialOrigin(for: size, visible: visible)
        let anchor = CGPoint(x: origin.x, y: origin.y + size.height)
        barAnchor = anchor
        return anchor
    }

    private func anchorForCurrentSurface(visible: CGRect) -> CGPoint {
        anchorFor(surface: surface, visible: visible)
    }

    // MARK: Lifecycle

    func show(appState: AppState) {
        self.appState = appState

        // A recording can already be running when the bar comes (back) up — started
        // from the tray while the panel was closed. Come up as the matching surface,
        // because the root's isRecording observer only fires on CHANGES.
        if appState.recordingManager.isRecording {
            surface = .recordingPill
        } else if surface == .recordingPill {
            surface = .bar
        }

        if panel == nil {
            let host = NSHostingController(
                rootView: CommandBarRootView(appState: appState, manager: self)
            )
            // The panel's size is driven by morph(to:), never by the SwiftUI fitting size.
            host.sizingOptions = []

            let newPanel = CommandBarPanel(contentRect: .zero)
            newPanel.contentViewController = host
            panelDelegate.manager = self
            newPanel.delegate = panelDelegate
            // Esc closes an open drawer, and on the recording pill opens the inline
            // discard confirmation (the panel must be key for Esc to arrive at all —
            // the known nonactivating-panel limit from phase 3). On the bare bar: nothing.
            newPanel.onEsc = { [weak self] in
                guard let self else { return }
                switch self.surface {
                case .barWithDrawer:
                    self.morph(to: .bar)
                case .recordingPill:
                    self.pillEscSignal += 1
                case .bar:
                    break
                }
            }
            // ⌘, — the shortcut the Settings drawer's header advertises. Toggles
            // the drawer; inert mid-recording (the pill has no drawers).
            newPanel.onCmdComma = { [weak self] in
                guard let self else { return }
                switch self.surface {
                case .barWithDrawer(.settings):
                    self.morph(to: .bar)
                case .bar, .barWithDrawer:
                    self.morph(to: .barWithDrawer(.settings))
                case .recordingPill:
                    break
                }
            }
            PanelCaptureRegistry.register(newPanel)
            panel = newPanel
        }
        guard let panel else { return }

        let visible = currentVisibleFrame()
        if barAnchor == nil {
            // savedAnchor may be stale (disconnected display) — targetFrame
            // re-clamps below, so it self-corrects instead of landing off-screen.
            barAnchor = Self.savedAnchor()
        }
        let anchor = anchorForCurrentSurface(visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: surface, bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth, visible: visible
        )
        // A re-show mid-flight (round 5c) supersedes the flight: zero offset +
        // target frame in one transaction, content lands in place.
        cancelFlight()
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)

        applyPanelAppearance()
        panel.orderFrontRegardless()
        // Round 6 REGRESSION FIX («після апдейту авто не працює, поки не
        // перемкнеш тему»): everything above ran while the panel was still
        // ordered OUT — `applyPanelAppearance()` → `syncBackdropMonitor()` saw
        // `panel.isVisible == false` and STOPPED the monitor instead of starting
        // it, and the root view's `.onChange(of: appTheme, initial: true)` fires
        // during the first layout pass, also pre-front. So a fresh launch with
        // Auto never sampled the backdrop; a manual theme round-trip "fixed" it
        // only because that onChange runs against an already-visible panel.
        // One more sync AFTER orderFront is the whole cure: the panel is
        // visible now, so Auto actually starts its monitor.
        syncBackdropMonitor()
    }

    /// Hides the bar — the app keeps running in the menu bar (verdict 25.08: the
    /// close button hides, it does NOT quit). A no-op mid-recording: the pill is
    /// the only control surface of a live take and has no close button anyway —
    /// its OWN way out is `hideRecordingPill()` below.
    func hide() {
        guard appState?.recordingManager.isRecording != true else { return }
        dismissPanel()
    }

    /// The recording pill's "hide" button (round 3): sends the panel away while
    /// the take KEEPS recording — deliberately bypassing `hide()`'s mid-recording
    /// guard, which exists to stop the bar's close door, not this one. The tray
    /// keeps the red-dot timer; a left tray click (or the tray menu's "Show
    /// recording pill") brings the pill back — `show()` comes up as the pill
    /// surface whenever a recording is live.
    func hideRecordingPill() {
        guard surface == .recordingPill else { return }
        dismissPanel()
    }

    /// Whether the panel is currently on screen — the tray's click routing needs
    /// this to tell "stop the take" from "bring the hidden pill back".
    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// Shared teardown of `hide()` / `hideRecordingPill()`: persist the anchor of
    /// whatever surface is up, then drop the panel (a later `show()` rebuilds it).
    private func dismissPanel() {
        backdropMonitor.stop()   // no panel → nothing to sample under (4.1.0)
        if let panel {
            if pendingDrawerCloseSnap || flightActive {
                // Mid-close (round 5b) or mid-flight (round 5c): the surface
                // state is already final but the panel deliberately wears an
                // oversized frame (the held drawer frame / the flight union) —
                // deriving an anchor from THAT frame would corrupt the saved
                // position. The correct anchor was already persisted (on drawer
                // open / at flight lift-off); there is nothing new to save.
                pendingDrawerCloseSnap = false
                closingDrawerTab = nil
                drawerOpensUp = false
                cancelFlight()
            } else {
                let logical = MorphGeometry.logicalFrame(forPanel: panel.frame)
                persistAnchor(forLogicalFrame: logical)
            }
            panel.orderOut(nil)
        }
        panel = nil
    }

    /// The pill view reports its laid-out width here (round 3): anything past the
    /// 341-pt base becomes `pillExtraWidth` and the panel grows to the RIGHT of
    /// the pill's held top-left anchor (the stop button at the leading edge must
    /// not move under an approaching cursor — see `MorphGeometry.targetFrame`).
    /// Idempotent per width, so the resize→relayout→report cycle settles.
    func setRecordingPillContentWidth(_ width: CGFloat) {
        let extra = max(0, width - Theme.Metrics.recordingPillSize.width)
        guard extra != pillExtraWidth else { return }
        pillExtraWidth = extra
        guard surface == .recordingPill else { return }
        // The pill's width growth stays animated (round 5 touches only drawers/
        // banner): it is part of the pill's own motion language, and the timer
        // crossing its slot is a once-per-take event.
        reframe(animated: true)
    }

    /// Whether a surface switch animates the morph (round 5, вердикт з
    /// бойової 4.0.0: «хай плашка буде спокійною»). Only the recording-pill
    /// morphs fly — the pill travels to its perch and back, on the compositor
    /// flight since round 5c (`beginFlight`). Drawer open/close SNAPS: moving
    /// the panel frame tick-by-tick while the SwiftUI root re-lays out inside
    /// it is exactly what read as the bar «здригається» — the bar must sit
    /// pixel-still, so the panel jumps to its final frame in one tick and only
    /// the drawer's own opacity fades (`Theme.Anim.drawerFade`). Pure and
    /// static so the policy is testable without a panel.
    nonisolated static func morphAnimates(from old: Surface, to new: Surface) -> Bool {
        old == .recordingPill || new == .recordingPill
    }

    /// Switches the panel to another surface. The BAR anchor stays the stable
    /// reference: the pill flies to its own perch and back, and an upward drawer
    /// grows above the stationary bar (see `MorphGeometry.targetFrame`).
    func morph(to newSurface: Surface) {
        guard surface != newSurface else { return }
        // Any surface change supersedes a drawer close still waiting for its
        // frame snap — the new morph reframes for itself. A half-faded closing
        // drawer is dropped on the spot (a ≤0.15s window, user-interrupted).
        let hadPendingSnap = pendingDrawerCloseSnap
        pendingDrawerCloseSnap = false
        closingDrawerTab = nil
        let animated = Self.morphAnimates(from: surface, to: newSurface)
        let closingDrawer: Bool
        if case .barWithDrawer = surface, newSurface == .bar {
            closingDrawer = true
        } else {
            closingDrawer = false
        }
        if newSurface == .recordingPill {
            // A fresh take starts at the base width; the mounted pill re-reports
            // its actual width immediately (a stale extra from the previous take's
            // long timer must not flash on the new pill).
            pillExtraWidth = 0
        }
        if case .barWithDrawer = newSurface {
            // Drawers only ever open from the bar (the pill has none), so the
            // bar anchor is the reference for the direction rule.
            let visible = currentVisibleFrame(for: panel)
            var anchor = anchorForCurrentSurface(visible: visible)
            if surface == .recordingPill { anchor = barAnchor ?? anchor }
            drawerOpensUp = MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: visible)
        }

        if animated, let panel, panel.isVisible {
            if hadPendingSnap {
                // Mid close-hold the bar sits at the BOTTOM of a deliberately
                // oversized panel, but the flight's offset math assumes the
                // content fills the logical frame — complete the deferred snap
                // first (clipping the last beats of the drawer fade under a
                // starting recording is fine; the old frame animation clipped
                // it the same way).
                reframe(animated: false)
                drawerOpensUp = false
            }
            // Round 5c compositor flight (verdict 26.08, «рідні анімації …
            // мають більше fps»). ORDER MATTERS, burst-caught twice:
            // 1. The flight's coordinate base — the offset jump and the union
            //    frame — must commit BEFORE the branch swap: an outgoing branch
            //    freezes at the attribute values of the PREVIOUS commit, so a
            //    swap-first ordering paints the dying surface one frame at the
            //    union's top-left corner.
            // 2. The swap itself must ride the same spring the offset flies on:
            //    a transition's attached animation drives insertions, but a
            //    REMOVAL only animates when the transaction of the state change
            //    carries the animation — a bare `surface = …` yanks the old
            //    surface in a single frame.
            let target = beginFlight(toSurface: newSurface, panel: panel)
            withAnimation(Theme.Anim.surface) { surface = newSurface }
            persistAnchor(forLogicalFrame: target)
            backdropMonitor.sampleSoon()
            if newSurface == .bar { drawerOpensUp = false }
            return
        }

        if closingDrawer {
            // Round 5c: the closing drawer stays IN the tree and IN layout
            // (`closingDrawerTab`) while its opacity animates to 0 — the fade
            // lives in the TRANSACTION of this state change. See the property
            // docs for why a removal transition cannot do this job.
            if case .barWithDrawer(let tab) = surface {
                withAnimation(Theme.Anim.drawerFade) {
                    closingDrawerTab = tab
                    surface = newSurface
                }
            } else {
                surface = newSurface
            }
        } else {
            surface = newSurface
        }

        if closingDrawer {
            // Round 5b (verdict 26.08, «анімація рвана» when the up-drawer
            // closes): the close is symmetric to the open. The drawer fades out
            // IN PLACE — the panel keeps the drawer-sized frame and the pin edge
            // keeps the bar pixel-still — because snapping the frame in the same
            // tick would CLIP the removal fade and the ~150ms Liquid Glass
            // dematerialize that follows it (on an upward drawer that clipped,
            // dying glass collapsed visibly across the bar's face). The frame
            // snap runs after `drawerCloseSnapDelay`, when nothing visible is
            // left to clip — burst-proven invisible (shots r5a-*).
            pendingDrawerCloseSnap = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.drawerCloseSnapDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingDrawerCloseSnap else { return }
                    self.pendingDrawerCloseSnap = false
                    guard self.surface == .bar else { return }
                    // The drawer leaves the tree only NOW, at opacity 0 — its
                    // removal (and the glass teardown) has nothing visible left.
                    self.closingDrawerTab = nil
                    self.reframe(animated: false)
                    // Back to the default top pin only once the bar-sized panel
                    // is in place — content fills it exactly, so the flip cannot
                    // move a pixel.
                    self.drawerOpensUp = false
                }
            }
            return
        }

        reframe(animated: false)
        if newSurface == .bar {
            drawerOpensUp = false
        }
    }

    /// Shows/hides the storage banner under the bar, resizing the panel in place.
    /// Called by the SwiftUI root when the quota level crosses the threshold —
    /// including mid-session, right after an upload refreshes used/allocated.
    /// Snaps, never animates (round 5): the banner rides under the resting bar,
    /// and the bar must not stir — the banner's own fade is all the motion.
    func setStorageBannerVisible(_ visible: Bool) {
        let newExtent: CGFloat = visible ? MorphGeometry.storageBannerExtent : 0
        guard newExtent != bannerExtent else { return }
        bannerExtent = newExtent
        // Mid drawer-close (round 5b) the extent is recorded but the panel is
        // deliberately oversized for the removal fade — the deferred snap will
        // apply it; reframing NOW would clip the fade.
        guard !pendingDrawerCloseSnap else { return }
        reframe(animated: false)
    }

    /// Re-derives the panel frame for the current surface + banner extent from the
    /// surface's anchor (bar anchor, or the pill's own perch). Shared by morphs
    /// and banner visibility flips.
    ///
    /// `animated` (round 5c, verdict 26.08 — «рідні анімації … мають більше fps»):
    /// pill flights are COMPOSITOR-driven. The previous NSAnimationContext frame
    /// animation ticked a window-server resize on a main-thread timer: every tick
    /// re-laid-out the hosting view and re-sampled the Liquid Glass at a new size,
    /// and the tick rate never exceeds 60 — half the shef's ProMotion display.
    /// Now the panel takes the UNION of both endpoint frames in ONE tick and the
    /// CONTENT flies inside it on an animated SwiftUI offset — a per-frame layer
    /// transform, no re-layout, running at the display's native rate. When the
    /// spring settles, the frame snaps to the target; the content already sits
    /// exactly there, so the snap changes no visible pixel (burst-proven,
    /// shots r5c-*). Drawer/banner reframes pass `false` and snap in one tick —
    /// see `morphAnimates` for why. Animation is also skipped while the panel is
    /// off screen — animating an invisible window only delays it.
    private func reframe(animated: Bool) {
        guard let panel else { return }
        if animated, panel.isVisible {
            // Same-surface animated reframe (the pill widening under a long
            // timer): starts — or retargets — a flight toward the fresh target.
            let target = beginFlight(toSurface: surface, panel: panel)
            persistAnchor(forLogicalFrame: target)
            backdropMonitor.sampleSoon()
            return
        }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: surface,
            bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth,
            visible: visible
        )
        // A snap reframe supersedes any flight still in the air: zero the
        // offset in the same transaction as the frame jump, so the content
        // lands exactly in the new frame (drawer opened within ~0.3s of a
        // pill landing, say).
        cancelFlight()
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)
        persistAnchor(forLogicalFrame: target)
        // The surface now sits over different desktop real estate — let the Auto
        // theme re-judge it (debounced; a no-op while the monitor sleeps).
        backdropMonitor.sampleSoon()
    }

    // MARK: Compositor flight (round 5c)

    /// Content displacement while a flight is in the air: the panel wears the
    /// union frame, the pin is top-leading, and the CONTENT sits at
    /// `contentOffset(of: <its logical frame>, in: <union>)` — animated by the
    /// `Theme.Anim.surface` spring from the source position to the target's.
    /// Zero between flights. The SwiftUI root applies it verbatim.
    private(set) var flightOffset: CGSize = .zero

    /// True from lift-off to the settle snap. The root reads it to force the
    /// top-leading pin during a flight (the offset's coordinate base) even when
    /// a lingering `drawerOpensUp` would pin bottom.
    private(set) var flightActive = false

    /// Orphans stale flight callbacks: every lift-off, retarget and cancel bumps
    /// it, and completions compare before touching state.
    private var flightGeneration = 0

    /// Starts (or retargets) the compositor flight toward `toSurface`'s target
    /// frame, computed from that surface's own anchor. Returns the target so
    /// the caller can persist it. Does NOT touch `surface` — the caller swaps
    /// it right after, inside the spring transaction (see `morph`).
    ///
    /// Lift-off is one atomic beat: `flightOffset` is jumped (animation
    /// explicitly disabled) to the content's CURRENT position inside the union
    /// and the panel takes the union frame — same commit, so the content does
    /// not move on screen. The spring launches a runloop turn later: writing
    /// the same property twice in one turn coalesces into a plain jump
    /// (burst-proven — the flight degenerated into two fades in place). A
    /// retarget mid-flight lets the spring continue from its live presentation
    /// value — valid as long as the union's top-left (the offset's coordinate
    /// base) stays put; when a retarget would move the base (pill widening
    /// against the screen edge — ultra-rare), the flight snaps out instead.
    @discardableResult
    private func beginFlight(toSurface: Surface, panel: CommandBarPanel) -> CGRect {
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorFor(surface: toSurface, visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: toSurface,
            bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth,
            visible: visible
        )
        let current = MorphGeometry.logicalFrame(forPanel: panel.frame)

        if flightActive {
            guard MorphGeometry.unionKeepsTopLeft(current: current, adding: target) else {
                cancelFlight()
                panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)
                return target
            }
            let union = current.union(target)
            if union != current {
                // Grows right/down only — the base corner holds, nothing moves.
                panel.setFrame(MorphGeometry.panelFrame(forLogical: union), display: true)
            }
            launchFlightSpring(toward: MorphGeometry.contentOffset(of: target, in: union))
            return target
        }

        let union = current.union(target)
        flightActive = true
        isAnimatingReframe = true
        // The base jump must not animate — and must land BEFORE the union
        // frame's layout pass, so that pass already draws the content where
        // it visually is.
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            flightOffset = MorphGeometry.contentOffset(of: current, in: union)
        }
        panel.setFrame(MorphGeometry.panelFrame(forLogical: union), display: true)
        let destination = MorphGeometry.contentOffset(of: target, in: union)
        flightGeneration += 1
        let generation = flightGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.flightActive, self.flightGeneration == generation else { return }
            self.launchFlightSpring(toward: destination)
        }
        return target
    }

    /// Animates `flightOffset` to `destination` and, once the spring has fully
    /// settled (`.removed` — a `logicallyComplete` snap would clip the spring's
    /// last sub-pixel tail into a visible nudge), snaps the panel to the real
    /// target frame of whatever surface is CURRENT by then.
    private func launchFlightSpring(toward destination: CGSize) {
        flightGeneration += 1
        let generation = flightGeneration
        withAnimation(Theme.Anim.surface, completionCriteria: .removed) {
            flightOffset = destination
        } completion: { [weak self] in
            // SwiftUI animation completions run on the main actor.
            guard let self, self.flightActive, self.flightGeneration == generation else { return }
            self.settleFlight()
        }
    }

    /// The landing: flight state off and the panel snapped to the current
    /// surface's own frame — in one transaction, so pin + zero offset in the
    /// target-sized panel draw the content exactly where the flight left it.
    private func settleFlight() {
        flightActive = false
        flightOffset = .zero
        isAnimatingReframe = false
        guard let panel else { return }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: surface,
            bannerHeight: bannerExtent,
            pillExtraWidth: pillExtraWidth,
            visible: visible
        )
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)
    }

    /// Drops a flight without landing it (snap reframe took over, or the panel
    /// is going away). Offset zeroing is not animated; the caller's own frame
    /// change lands in the same transaction.
    private func cancelFlight() {
        guard flightActive else { return }
        flightGeneration += 1
        flightActive = false
        flightOffset = .zero
        isAnimatingReframe = false
    }

    /// True while an animated reframe is in flight — its intermediate frames also
    /// fire `windowDidMove`, and persisting those would poison the anchors with
    /// mid-animation garbage. `reframe()` already persists the END frame itself.
    private var isAnimatingReframe = false

    /// A user drag moved the panel — update whichever anchor the current surface
    /// owns. Called by the window delegate on `windowDidMove`.
    func panelWasDragged(toLogicalFrame logical: CGRect) {
        guard !isAnimatingReframe else { return }
        // Mid drawer-close (round 5b) the frame is deliberately oversized while
        // the surface is already `.bar` — deriving a bar anchor from it would
        // corrupt the position. The snap lands in a beat and persists the truth.
        guard !pendingDrawerCloseSnap else { return }
        // Round 6 safety net (the camera window's delegate recipe): if a move
        // slipped past the panel's own clamp overrides, push the glass back into
        // the visible frame. The setFrame fires a fresh `windowDidMove`, and THAT
        // pass — now in-bounds — persists the anchor and judges the flip.
        if let panel {
            let visible = currentVisibleFrame(for: panel)
            let clamped = MorphGeometry.clampedIntoVisible(logical, visible: visible)
            if clamped != logical {
                panel.setFrame(MorphGeometry.panelFrame(forLogical: clamped), display: true)
                return
            }
        }
        persistAnchor(forLogicalFrame: logical)
        scheduleDrawerFlipIfNeeded()
        // Dragged over new backdrop — re-judge the Auto look (debounced).
        backdropMonitor.sampleSoon()
    }

    // MARK: Drawer auto-flip on drag (round 6)

    /// Pending re-evaluation of the drawer direction after a drag; nil when the
    /// position agrees with the current direction.
    private var drawerFlipTask: Task<Void, Never>?

    /// How long after the LAST `windowDidMove` the direction is re-judged. Long
    /// enough to never fire between two events of a live drag stream.
    private static let drawerFlipDebounce: TimeInterval = 0.18

    /// Round 6 («якщо шухляда знизу і місце закінчилось — переміщай наверх»):
    /// while a drawer is open, every drag event re-evaluates
    /// `MorphGeometry.drawerOpensUpward` for the bar's new position. A needed
    /// change does NOT flip mid-drag: the up- and down-frames share only the
    /// bar's rows, so reframing while AppKit's drag session is live would yank
    /// the panel out from under the tracked mouse delta. Instead the flip is
    /// debounced past the event stream AND waits for the mouse button to be
    /// released (`pressedMouseButtons` poll) — the drawer changes sides the
    /// moment the user lets go, via the same snap-frame + fade-in language the
    /// drawer open uses (round-5 policy: the bar itself never stirs).
    private func scheduleDrawerFlipIfNeeded() {
        guard case .barWithDrawer = surface, closingDrawerTab == nil, !flightActive,
              let panel else {
            drawerFlipTask?.cancel()
            drawerFlipTask = nil
            return
        }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let desired = MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: visible)
        guard desired != drawerOpensUp else {
            drawerFlipTask?.cancel()
            drawerFlipTask = nil
            return
        }
        drawerFlipTask?.cancel()
        drawerFlipTask = Task { @MainActor [weak self] in
            // Debounce past the drag's event stream, then wait out the button:
            // flipping under a held mouse fights AppKit's drag tracking.
            try? await Task.sleep(nanoseconds: UInt64(Self.drawerFlipDebounce * 1_000_000_000))
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 0x1 != 0 {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            guard !Task.isCancelled else { return }
            self?.performDrawerFlipIfStillNeeded()
        }
    }

    /// The flip itself, re-checked at fire time (the user may have dragged back).
    /// Same mechanism as a drawer open: `drawerOpensUp` swaps inside a
    /// `drawerFade` transaction (the drawer fades in on its new side; the pin
    /// edge follows) and the panel SNAPS to the direction's frame — the bar's
    /// glass does not move a pixel, because both frames are anchored to it.
    private func performDrawerFlipIfStillNeeded() {
        drawerFlipTask = nil
        guard case .barWithDrawer = surface, closingDrawerTab == nil, !flightActive,
              !pendingDrawerCloseSnap, let panel else { return }
        let visible = currentVisibleFrame(for: panel)
        let anchor = anchorForCurrentSurface(visible: visible)
        let desired = MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: visible)
        guard desired != drawerOpensUp else { return }
        withAnimation(Theme.Anim.drawerFade) { drawerOpensUp = desired }
        reframe(animated: false)
    }

    /// Writes the anchor a logical surface frame implies. A dragged/reframed pill
    /// updates ONLY its own perch (used by this and future takes); every other
    /// surface updates the bar anchor — recovered through `MorphGeometry.barAnchor`
    /// because an upward drawer's frame has the bar at its bottom.
    private func persistAnchor(forLogicalFrame logical: CGRect) {
        if surface == .recordingPill {
            Self.savePillAnchor(CGPoint(x: logical.minX, y: logical.maxY))
            return
        }
        let anchor = MorphGeometry.barAnchor(
            forSurfaceFrame: logical, surface: surface, opensUp: drawerOpensUp
        )
        barAnchor = anchor
        Self.saveAnchor(anchor)
    }

    // MARK: Theme

    /// Watches the desktop under the panel while the Auto theme is on (4.1.0);
    /// its verdicts land in `AppState.autoPanelDark` and come back through
    /// `applyPanelAppearance(smooth: true)`.
    private let backdropMonitor = BackdropLuminanceMonitor()

    /// Pins the panel's NSAppearance to the resolved panel look
    /// (`AppState.panelAppearance`: the explicit Light/Dark choice, or the Auto
    /// verdict). The explicit pin is what makes `Color.adaptive` resolve
    /// per-panel. Called on show(), from CommandBarRootView's
    /// `.onChange(of: appState.appTheme)`, and by the backdrop monitor.
    ///
    /// `smooth` (Auto flips only, verdict 26.08: the alpha dip still read as a
    /// hard blink — «перемикання … ріже око»): NSAppearance is not animatable,
    /// so the flip hides behind a SNAPSHOT CROSSFADE — one bitmap of the old
    /// look pinned over the content, the appearance switched underneath it, the
    /// snapshot dissolved over `themeFadeDuration`. The overlay is click-through
    /// (`hitTest` nil) and hover keeps working: tracking areas belong to the
    /// live views below and never consult z-order.
    func applyPanelAppearance(smooth: Bool = false) {
        guard let appState, let panel else { return }
        let target = appState.panelAppearance
        if smooth, panel.isVisible, panel.appearance?.name != target?.name,
           let contentView = panel.contentView,
           let snapshot = Self.snapshotOverlay(of: contentView) {
            // One fade at a time: a newer flip replaces the previous overlay
            // (with the 6s decision dwell this is belt-and-braces, not a path
            // the monitor can actually race).
            themeFadeOverlay?.removeFromSuperview()
            contentView.addSubview(snapshot)
            themeFadeOverlay = snapshot
            // The live content re-renders in the new look UNDER the snapshot.
            panel.appearance = target
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.themeFadeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                snapshot.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    snapshot.removeFromSuperview()
                    if let self, self.themeFadeOverlay === snapshot {
                        self.themeFadeOverlay = nil
                    }
                }
            })
        } else {
            panel.appearance = target
        }
        syncBackdropMonitor()
    }

    /// Duration of the Auto-theme crossfade (verdict 26.08).
    private static let themeFadeDuration: TimeInterval = 0.45

    /// The dissolving snapshot of the previous look; nil between crossfades.
    private var themeFadeOverlay: NSImageView?

    /// One bitmap of the content view AS CURRENTLY DRAWN (the old look), wrapped
    /// in a click-through image view covering the whole content view. Sized in
    /// points with the rep carrying the backing scale, so Retina stays sharp.
    private static func snapshotOverlay(of contentView: NSView) -> NSImageView? {
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            return nil
        }
        contentView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        let overlay = ThemeFadeOverlayView(frame: bounds)
        overlay.image = image
        overlay.imageScaling = .scaleAxesIndependently
        overlay.autoresizingMask = [.width, .height]
        return overlay
    }

    /// The one-line policy behind `syncBackdropMonitor`, pure so the regression
    /// of round 6 stays pinned by a test: the Auto-theme monitor runs exactly
    /// while Auto is chosen AND the panel is actually on screen. The
    /// `panelIsVisible` half is why the ORDER of calls in `show()` matters —
    /// any sync made before `orderFrontRegardless()` must come out as `false`.
    nonisolated static func backdropMonitorShouldRun(
        theme: AppState.AppTheme, panelIsVisible: Bool
    ) -> Bool {
        theme == .auto && panelIsVisible
    }

    /// The monitor runs exactly while: Auto is chosen AND the panel is up
    /// (`backdropMonitorShouldRun`). Everything else puts it to sleep. Silent
    /// without the screen permission — the monitor checks that itself before
    /// every sample.
    private func syncBackdropMonitor() {
        guard let appState, let panel,
              Self.backdropMonitorShouldRun(
                  theme: appState.appTheme, panelIsVisible: panel.isVisible
              ) else {
            backdropMonitor.stop()
            return
        }
        backdropMonitor.onLook = { [weak self] look in
            guard let self, let appState = self.appState else { return }
            appState.autoPanelDark = (look == .dark)
            self.applyPanelAppearance(smooth: true)
        }
        backdropMonitor.start(panel: panel)
    }

    // MARK: Helpers

    private func currentVisibleFrame(for panel: NSPanel? = nil) -> CGRect {
        let screen = panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

// MARK: - Theme-fade overlay

/// The crossfade snapshot (verdict 26.08): sits over the live content while the
/// old look dissolves, and never intercepts the mouse — clicks land on the live
/// controls underneath, and their tracking-area hover states keep firing.
private final class ThemeFadeOverlayView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - NSAppearance from app theme

extension NSAppearance {
    /// The ONBOARDING-side mapping (the panels use `AppState.panelAppearance`):
    /// `.auto` maps to nil — inherit — because Auto steers floating panels only,
    /// and the onboarding window follows the system appearance by design (4.1.0).
    static func from(_ theme: AppState.AppTheme) -> NSAppearance? {
        switch theme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case .auto: return nil
        }
    }
}
