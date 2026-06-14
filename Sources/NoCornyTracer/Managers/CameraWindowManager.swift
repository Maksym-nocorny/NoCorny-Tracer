import SwiftUI
import AppKit

/// NSPanel that clamps its origin to the visible frame of whichever screen
/// it sits on. The camera circle can be dragged freely within screen bounds
/// but never past an edge — simpler and more predictable than a snap-back
/// animation, and immune to all the event-delivery quirks that plagued the
/// snap-back implementations (see git history v3.9.9–v3.9.15).
private final class CameraOverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Self.clamped(rect: frameRect, to: screen ?? self.screen ?? NSScreen.main)
    }

    override func setFrameOrigin(_ point: NSPoint) {
        super.setFrameOrigin(Self.clamped(
            origin: point,
            size: frame.size,
            to: self.screen ?? NSScreen.main
        ))
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(
            Self.clamped(rect: frameRect, to: self.screen ?? NSScreen.main),
            display: flag
        )
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate: Bool) {
        super.setFrame(
            Self.clamped(rect: frameRect, to: self.screen ?? NSScreen.main),
            display: flag,
            animate: animate
        )
    }

    static func clamped(rect: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return rect }
        var r = rect
        r.origin.x = max(visible.minX, min(r.origin.x, visible.maxX - r.width))
        r.origin.y = max(visible.minY, min(r.origin.y, visible.maxY - r.height))
        return r
    }

    static func clamped(origin: NSPoint, size: NSSize, to screen: NSScreen?) -> NSPoint {
        guard let visible = screen?.visibleFrame else { return origin }
        return NSPoint(
            x: max(visible.minX, min(origin.x, visible.maxX - size.width)),
            y: max(visible.minY, min(origin.y, visible.maxY - size.height))
        )
    }
}

/// Safety-net delegate: if AppKit ever moves the window via a code path
/// that bypasses our `setFrameOrigin` / `setFrame` overrides, `windowDidMove`
/// fires after the move and we re-clamp here. It also persists the latest
/// (clamped) origin so the bubble can be restored across toggle off/on and
/// across app launches.
private final class CameraWindowDelegate: NSObject, NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = window.frame.origin
        let size = window.frame.size
        let clampedX = max(visible.minX, min(origin.x, visible.maxX - size.width))
        let clampedY = max(visible.minY, min(origin.y, visible.maxY - size.height))
        if clampedX != origin.x || clampedY != origin.y {
            window.setFrameOrigin(NSPoint(x: clampedX, y: clampedY))
            CameraWindowManager.saveOrigin(NSPoint(x: clampedX, y: clampedY))
        } else {
            CameraWindowManager.saveOrigin(origin)
        }
    }
}

/// Manages the floating, borderless camera window
@Observable
final class CameraWindowManager {
    private var window: NSWindow?
    private var windowDelegate = CameraWindowDelegate()

    // Persisted bubble origin (survives toggle off/on and app relaunch).
    // NSPoint isn't directly storable in UserDefaults, so x/y are kept as two Doubles.
    private static let originXKey = "cameraBubbleOriginX"
    private static let originYKey = "cameraBubbleOriginY"

    static func saveOrigin(_ origin: NSPoint) {
        let defaults = UserDefaults.standard
        defaults.set(Double(origin.x), forKey: originXKey)
        defaults.set(Double(origin.y), forKey: originYKey)
    }

    static func savedOrigin() -> NSPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXKey) != nil,
              defaults.object(forKey: originYKey) != nil else { return nil }
        return NSPoint(x: defaults.double(forKey: originXKey),
                       y: defaults.double(forKey: originYKey))
    }

    func updateVisibility(isEnabled: Bool, appState: AppState) {
        if isEnabled {
            showWindow(appState: appState)
        } else {
            hideWindow()
        }
    }

    private func showWindow(appState: AppState) {
        if window == nil {
            let cameraView = CameraView(cameraManager: appState.cameraManager)
            let hostingController = NSHostingController(rootView: cameraView)

            let newWindow = CameraOverlayWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            newWindow.contentViewController = hostingController
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true
            newWindow.level = .floating
            newWindow.isMovableByWindowBackground = true
            newWindow.delegate = windowDelegate

            // Restore the last position if we have one; otherwise fall back to the
            // bottom-left corner default. setFrameOrigin re-clamps to the current
            // screen's visibleFrame, so a stale/off-screen saved origin (e.g. a
            // disconnected display) is self-correcting and never lands off-screen.
            if let saved = Self.savedOrigin() {
                newWindow.setFrameOrigin(saved)
            } else if let screen = NSScreen.main {
                let padding: CGFloat = 40
                newWindow.setFrameOrigin(NSPoint(
                    x: screen.visibleFrame.minX + padding,
                    y: screen.visibleFrame.minY + padding
                ))
            }

            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            self.window = newWindow
        }

        window?.orderFrontRegardless()
    }

    private func hideWindow() {
        // Capture the final (already-clamped) origin before teardown so the next
        // toggle-on restores it, even if no move fired this session.
        if let origin = window?.frame.origin {
            Self.saveOrigin(origin)
        }
        window?.orderOut(nil)
        window = nil
    }
}
