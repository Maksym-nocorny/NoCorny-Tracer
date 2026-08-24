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

        if panel == nil {
            let host = NSHostingController(
                rootView: CommandBarRootView(appState: appState, manager: self)
            )
            // The panel's size is driven by morph(to:), never by the SwiftUI fitting size.
            host.sizingOptions = []

            let newPanel = CommandBarPanel(contentRect: .zero)
            newPanel.contentViewController = host
            newPanel.delegate = panelDelegate
            panel = newPanel
        }
        guard let panel else { return }

        let visible = currentVisibleFrame()
        let size = MorphGeometry.size(of: surface)
        let anchor: CGPoint
        if let saved = Self.savedAnchor() {
            // targetFrame re-clamps below, so a stale anchor (disconnected display)
            // self-corrects instead of landing off-screen.
            anchor = saved
        } else {
            let origin = MorphGeometry.initialOrigin(for: size, visible: visible)
            anchor = CGPoint(x: origin.x, y: origin.y + size.height)
        }
        let target = MorphGeometry.targetFrame(anchorTopLeft: anchor, surface: surface, visible: visible)
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
        guard let panel else { return }

        let logical = MorphGeometry.logicalFrame(forPanel: panel.frame)
        let anchor = CGPoint(x: logical.minX, y: logical.maxY)
        let target = MorphGeometry.targetFrame(
            anchorTopLeft: anchor,
            surface: newSurface,
            visible: currentVisibleFrame(for: panel)
        )
        panel.setFrame(MorphGeometry.panelFrame(forLogical: target), display: true)
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
