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

    /// The anchor the CURRENT surface should be framed from: the pill has its own
    /// perch; everything else hangs off the bar anchor.
    private func anchorForCurrentSurface(visible: CGRect) -> CGPoint {
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
            #if DEBUG
            CapturablePanels.register(newPanel)
            #endif
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
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)

        applyPanelAppearance()
        panel.orderFrontRegardless()
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
            if pendingDrawerCloseSnap {
                // Mid-close (round 5b): the surface is already `.bar` but the
                // panel still wears the drawer-sized frame — deriving a bar
                // anchor from THAT frame would corrupt the saved position. The
                // correct anchor was persisted while the drawer was open;
                // there is nothing new to save.
                pendingDrawerCloseSnap = false
                drawerOpensUp = false
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

    /// Whether a surface switch animates the panel FRAME (round 5, вердикт з
    /// бойової 4.0.0: «хай плашка буде спокійною»). Only the recording-pill
    /// morphs fly — the pill travels to its perch and back, and the frame
    /// animation IS that flight. Drawer open/close SNAPS: animating the panel
    /// frame while the SwiftUI root re-lays out inside it every frame is exactly
    /// what read as the bar «здригається» — the bar must sit pixel-still, so the
    /// panel jumps to its final frame in one tick and only the drawer's own
    /// opacity fades (`Theme.Anim.drawerFade`). Pure and static so the policy is
    /// testable without a panel.
    nonisolated static func morphAnimates(from old: Surface, to new: Surface) -> Bool {
        old == .recordingPill || new == .recordingPill
    }

    /// Switches the panel to another surface. The BAR anchor stays the stable
    /// reference: the pill flies to its own perch and back, and an upward drawer
    /// grows above the stationary bar (see `MorphGeometry.targetFrame`).
    func morph(to newSurface: Surface) {
        guard surface != newSurface else { return }
        // Any surface change supersedes a drawer close still waiting for its
        // frame snap — the new morph reframes for itself.
        pendingDrawerCloseSnap = false
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
        surface = newSurface

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
                    self.reframe(animated: false)
                    // Back to the default top pin only once the bar-sized panel
                    // is in place — content fills it exactly, so the flip cannot
                    // move a pixel.
                    self.drawerOpensUp = false
                }
            }
            return
        }

        reframe(animated: animated)
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

    /// Duration of the panel's frame animation during an ANIMATED reframe (the
    /// pill flights) — tuned to ride together with the pill's content transitions
    /// (`Theme.Anim.surface`).
    private static let morphDuration: TimeInterval = 0.28

    /// Re-derives the panel frame for the current surface + banner extent from the
    /// surface's anchor (bar anchor, or the pill's own perch). Shared by morphs
    /// and banner visibility flips.
    ///
    /// `animated` (round 5): pill flights animate — an explicit NSAnimationContext
    /// with easeInOut rather than `setFrame(_:display:animate:)`, whose duration is
    /// the window-size-dependent `animationResizeTime` (verdict 24.08: the morph
    /// used to jump). Drawer/banner reframes pass `false` and snap in one tick —
    /// see `morphAnimates` for why. Animation is also skipped while the panel is
    /// off screen — animating an invisible window only delays it.
    private func reframe(animated: Bool) {
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
        let panelFrame = MorphGeometry.panelFrame(forLogical: target)
        if animated, panel.isVisible {
            isAnimatingReframe = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Self.morphDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(panelFrame, display: true)
            }, completionHandler: { [weak self] in
                // Runs on the main thread, like every AppKit animation callback.
                MainActor.assumeIsolated { self?.isAnimatingReframe = false }
            })
        } else {
            panel.setFrame(panelFrame, display: true)
        }
        persistAnchor(forLogicalFrame: target)
        // The surface now sits over different desktop real estate — let the Auto
        // theme re-judge it (debounced; a no-op while the monitor sleeps).
        backdropMonitor.sampleSoon()
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
        persistAnchor(forLogicalFrame: logical)
        // Dragged over new backdrop — re-judge the Auto look (debounced).
        backdropMonitor.sampleSoon()
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

    /// The monitor runs exactly while: Auto is chosen AND the panel is up.
    /// Everything else puts it to sleep. Silent without the screen permission —
    /// the monitor checks that itself before every sample.
    private func syncBackdropMonitor() {
        guard let appState, let panel, panel.isVisible, appState.appTheme == .auto else {
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
