import AppKit
import SwiftUI

// MARK: - Panel

/// Full-screen borderless panel that hosts the area-selection overlay (phase 6b).
///
/// The recipe is CommandBarPanel's (`.nonactivatingPanel` + `canBecomeKey`) with two
/// deviations from the handoff: `level = .screenSaver`, so the dim covers the command
/// bar (`.floating`) and everything else, and the panel is made key on present —
/// Enter/Esc must land here without activating the whole app. `sharingType = .none`
/// keeps the overlay itself out of every capture, ours included.
final class AreaSelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:   // Return / keypad Enter
            onCommit?()
        case 53:       // Esc
            onCancel?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Esc through the responder chain (same double door as CommandBarPanel).
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        sharingType = .none
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        #if DEBUG
        CapturablePanels.register(self)
        #endif
    }
}

// MARK: - Manager

/// Owns the area-selection overlay: one panel, on ONE screen at a time.
///
/// Which screen: the one under the cursor at the moment the overlay opens
/// (decision, phase 6b). The menu click that opens the overlay happens where the
/// cursor is, so that screen is where the user is working; a per-display overlay
/// array would buy multi-monitor pickings at several times the complexity, and the
/// selection model itself is single-display anyway (CaptureSelection.areaDisplayID
/// is one display — the rect is meaningless on another). To select on a different
/// screen, move the cursor there and open the overlay again.
///
/// Contract (mirror of the phase-6a window flow): presenting ALWAYS shows the
/// overlay; Enter with a selection commits the rect (in POINTS in the display's
/// local top-left space, exactly what CaptureGeometry expects) plus the display ID
/// and the caller starts recording; Esc changes nothing. A remembered area on the
/// same display comes up prefilled; a rect remembered for a DIFFERENT display is
/// left alone — it stays saved for its own display, and this screen starts empty.
@MainActor
final class AreaSelectionWindowManager {
    static let shared = AreaSelectionWindowManager()

    private var panel: AreaSelectionPanel?
    private var model: AreaSelectionModel?
    private var onCommit: ((CGRect, CGDirectDisplayID) -> Void)?
    private var displayID: CGDirectDisplayID = 0
    private var cursorPushed = false

    // MARK: Present / dismiss

    func present(
        current: CaptureSelection,
        onCommit: @escaping (CGRect, CGDirectDisplayID) -> Void
    ) {
        dismiss()   // re-invocation replaces any overlay already up

        guard let screen = Self.screenWithMouse() else {
            LogManager.shared.log("Area picker: no screen found under the cursor - not presenting", type: .error)
            return
        }
        let displayID = Self.displayID(of: screen) ?? CGMainDisplayID()
        let bounds = CGRect(origin: .zero, size: screen.frame.size)

        // Prefill the remembered rect when it belongs to THIS display (nil display ID
        // rides on whatever display is current — see CaptureSelection). Re-clamped:
        // the display's resolution can have changed since the rect was saved.
        var prefill: CGRect?
        if current.mode == .selectedArea,
           let saved = current.areaRect,
           current.areaDisplayID == nil || current.areaDisplayID == displayID {
            prefill = CaptureGeometry.clampedAreaRect(saved, in: bounds)
        }

        let model = AreaSelectionModel(bounds: bounds, scale: screen.backingScaleFactor, rect: prefill)
        self.model = model
        self.onCommit = onCommit
        self.displayID = displayID

        let host = NSHostingController(rootView: AreaSelectionOverlayView(model: model))
        host.sizingOptions = []   // the panel's frame is the screen, never the fitting size

        let panel = AreaSelectionPanel(contentRect: screen.frame)
        panel.contentViewController = host
        panel.onCommit = { [weak self] in self?.commit() }
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.setFrame(screen.frame, display: true)
        self.panel = panel

        NSCursor.crosshair.push()
        cursorPushed = true

        // Key without activating (nonactivating panel): Enter/Esc arrive while the
        // user's app keeps focus.
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        panel?.orderOut(nil)
        panel = nil
        model = nil
        onCommit = nil
    }

    // MARK: Commit

    /// Enter with no selection yet does nothing — the hint says "Drag to select area",
    /// and starting a recording of nothing would be the dishonest alternative.
    private func commit() {
        guard let rect = model?.rect else { return }
        let handler = onCommit
        let id = displayID
        dismiss()   // close BEFORE the recording starts, so the dim never joins the take
        handler?(rect, id)
    }

    // MARK: Screen lookup

    /// The screen under the cursor; main screen as the fallback (a cursor is always
    /// on SOME screen, but the API answers in frames and float edges exist).
    static func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}
