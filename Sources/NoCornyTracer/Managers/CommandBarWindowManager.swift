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

    /// Whether the currently open (or closing) drawer unfolds ABOVE the bar
    /// (verdict 25.08: bar in the lower half of the screen → drawer opens up).
    /// The SwiftUI root reads this to flip the stack order and the pin edge.
    /// Sticky through the close animation — see the reset in `morph(to:)`.
    private(set) var drawerOpensUp = false

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
        if let panel {
            let logical = MorphGeometry.logicalFrame(forPanel: panel.frame)
            persistAnchor(forLogicalFrame: logical)
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
        reframe()
    }

    /// Switches the panel to another surface. The BAR anchor stays the stable
    /// reference: the pill flies to its own perch and back, and an upward drawer
    /// grows above the stationary bar (see `MorphGeometry.targetFrame`).
    func morph(to newSurface: Surface) {
        guard surface != newSurface else { return }
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
        reframe()
        if newSurface == .bar, drawerOpensUp {
            // Keep the bottom-pin through the close animation (the bar must stay
            // put while the drawer folds up), then return to the default top-pin —
            // invisible at rest, but the banner's grow-down animation needs it.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.morphDuration * 1_500_000_000))
                guard let self, self.surface == .bar else { return }
                self.drawerOpensUp = false
            }
        }
    }

    /// Shows/hides the storage banner under the bar, resizing the panel in place.
    /// Called by the SwiftUI root when the quota level crosses the threshold —
    /// including mid-session, right after an upload refreshes used/allocated.
    func setStorageBannerVisible(_ visible: Bool) {
        let newExtent: CGFloat = visible ? MorphGeometry.storageBannerExtent : 0
        guard newExtent != bannerExtent else { return }
        bannerExtent = newExtent
        reframe()
    }

    /// Duration of the panel's frame animation during a morph — tuned to ride
    /// together with the SwiftUI content transitions (`Theme.Anim.surface`).
    private static let morphDuration: TimeInterval = 0.28

    /// Re-derives the panel frame for the current surface + banner extent from the
    /// surface's anchor (bar anchor, or the pill's own perch). Shared by morphs
    /// and banner visibility flips.
    ///
    /// The frame ANIMATES (verdict 24.08: the morph used to jump): an explicit
    /// NSAnimationContext with easeInOut rather than `setFrame(_:display:animate:)`,
    /// whose duration is the window-size-dependent `animationResizeTime`. Skipped
    /// while the panel is off screen — animating an invisible window only delays it.
    private func reframe() {
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
        if panel.isVisible {
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
    }

    /// True while an animated reframe is in flight — its intermediate frames also
    /// fire `windowDidMove`, and persisting those would poison the anchors with
    /// mid-animation garbage. `reframe()` already persists the END frame itself.
    private var isAnimatingReframe = false

    /// A user drag moved the panel — update whichever anchor the current surface
    /// owns. Called by the window delegate on `windowDidMove`.
    func panelWasDragged(toLogicalFrame logical: CGRect) {
        guard !isAnimatingReframe else { return }
        persistAnchor(forLogicalFrame: logical)
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

    /// Pins the panel's NSAppearance to the in-app theme. First precedent of theme in a
    /// floating panel: AppState.updateAppAppearance() sets NSApp.appearance, which panels
    /// inherit, but the explicit pin keeps the bar correct even if that global changes
    /// (and it is what makes `Color.adaptive` resolve per-panel). Called on show() and
    /// re-called from CommandBarRootView's `.onChange(of: appState.appTheme)`.
    func applyPanelAppearance() {
        guard let appState, let panel else { return }
        panel.appearance = NSAppearance.from(appState.appTheme)
    }

    // MARK: Helpers

    private func currentVisibleFrame(for panel: NSPanel? = nil) -> CGRect {
        let screen = panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }
}

// MARK: - NSAppearance from app theme

extension NSAppearance {
    /// The panel counterpart of `AppState.updateAppAppearance()`. The app's theme has no
    /// "system" case today — if one ever appears, it should map to nil (inherit).
    static func from(_ theme: AppState.AppTheme) -> NSAppearance? {
        switch theme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
