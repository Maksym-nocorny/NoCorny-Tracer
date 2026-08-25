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

/// Persists the bar's position as the user drags it (the panel is
/// `isMovableByWindowBackground`, so moves happen without any code of ours running).
private final class CommandBarPanelDelegate: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let logical = MorphGeometry.logicalFrame(forPanel: window.frame)
        CommandBarWindowManager.saveAnchor(CGPoint(x: logical.minX, y: logical.maxY))
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
    /// opens its inline discard confirmation — a counter (not a Bool) so every press
    /// registers even while the confirmation is already showing.
    private(set) var pillEscSignal = 0

    private var panel: CommandBarPanel?
    private let panelDelegate = CommandBarPanelDelegate()
    private weak var appState: AppState?

    // MARK: Persisted position

    // The stored point is the LOGICAL TOP-LEFT anchor of the surface (AppKit screen
    // coordinates, so top-left = (minX, maxY)) — the anchor `MorphGeometry.targetFrame`
    // holds across morphs. NSPoint isn't UserDefaults-storable; x/y are two Doubles.
    private static let anchorXKey = "commandBarOriginX"
    private static let anchorYKey = "commandBarOriginY"

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
            panel = newPanel
        }
        guard let panel else { return }

        let visible = currentVisibleFrame()
        let size = MorphGeometry.size(of: surface, bannerHeight: bannerExtent)
        let anchor: CGPoint
        if let saved = Self.savedAnchor() {
            // targetFrame re-clamps below, so a stale anchor (disconnected display)
            // self-corrects instead of landing off-screen.
            anchor = saved
        } else {
            let origin = MorphGeometry.initialOrigin(for: size, visible: visible)
            anchor = CGPoint(x: origin.x, y: origin.y + size.height)
        }
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: surface, bannerHeight: bannerExtent, visible: visible
        )
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)

        applyPanelAppearance()
        panel.orderFrontRegardless()
    }

    func hide() {
        if let panel {
            let logical = MorphGeometry.logicalFrame(forPanel: panel.frame)
            Self.saveAnchor(CGPoint(x: logical.minX, y: logical.maxY))
            panel.orderOut(nil)
        }
        panel = nil
    }

    /// Switches the panel to another surface, holding the top-left anchor
    /// (see `MorphGeometry.targetFrame` for the doesn't-fit fallbacks).
    func morph(to newSurface: Surface) {
        guard surface != newSurface else { return }
        surface = newSurface
        reframe()
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

    /// Re-derives the panel frame for the current surface + banner extent, holding
    /// the top-left anchor. Shared by morphs and banner visibility flips.
    ///
    /// The frame ANIMATES (verdict 24.08: the morph used to jump): an explicit
    /// NSAnimationContext with easeInOut rather than `setFrame(_:display:animate:)`,
    /// whose duration is the window-size-dependent `animationResizeTime`. Skipped
    /// while the panel is off screen — animating an invisible window only delays it.
    private func reframe() {
        guard let panel else { return }
        let logical = MorphGeometry.logicalFrame(forPanel: panel.frame)
        let anchor = CGPoint(x: logical.minX, y: logical.maxY)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: surface,
            bannerHeight: bannerExtent,
            visible: currentVisibleFrame(for: panel)
        )
        let panelFrame = MorphGeometry.panelFrame(forLogical: target)
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.morphDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(panelFrame, display: true)
            }
        } else {
            panel.setFrame(panelFrame, display: true)
        }
        Self.saveAnchor(CGPoint(x: target.minX, y: target.maxY))
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
