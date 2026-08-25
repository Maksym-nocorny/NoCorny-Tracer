#if DEBUG
import AppKit

/// DEBUG-only design-review switch (verdict 25.08: the boss could not screenshot
/// the demo — every panel ships `sharingType = .none`). Registered panels flip to
/// `.readOnly` while enabled and back to `.none` when disabled; panels created
/// while the switch is ON come up capturable too. Driven from the tray's
/// "UI Preview → Capturable panels (design review)" item.
///
/// A REGISTRY rather than a sweep over `NSApp.windows` on purpose: the camera
/// bubble deliberately has the default sharing type (it MUST join recordings),
/// so a blanket "reset everything to .none" would break a real feature. Only
/// panels that opt into the hide-from-capture policy register here.
///
/// Weak references — panels come and go (the toast panel is torn down on every
/// dismiss), and the registry must never keep one alive.
///
/// Main-thread only, like the panels themselves. None of this exists in a
/// release build: the type, the menu item and every call site are `#if DEBUG`.
enum CapturablePanels {
    private static let panels = NSHashTable<NSWindow>.weakObjects()
    private(set) static var isEnabled = false

    /// Adds a panel to the policy and applies the current state to it.
    static func register(_ window: NSWindow) {
        panels.add(window)
        window.sharingType = isEnabled ? .readOnly : .none
    }

    /// Flips every registered panel between capturable (.readOnly) and hidden
    /// from capture (.none).
    static func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        for window in panels.allObjects {
            window.sharingType = enabled ? .readOnly : .none
        }
    }
}
#endif
