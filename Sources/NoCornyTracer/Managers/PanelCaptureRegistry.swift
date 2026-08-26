import AppKit

/// Whether Tracer's own floating panels join screen captures (round 6, package 4 —
/// the DEBUG-only design-review switch grown into a product setting: "Show Tracer
/// in screen captures" in Settings → RECORDING).
///
/// Default OFF: the redesign ships every panel with `sharingType = .none`, so the
/// bar, toasts and onboarding never photobomb screenshots or the user's own
/// recordings. Turning the setting ON flips every REGISTERED panel to `.readOnly`
/// (visible to captures, still not writable by them) and every panel created later
/// comes up capturable too, because creation-time registration applies the current
/// state.
///
/// A REGISTRY rather than a sweep over `NSApp.windows` on purpose (inherited from
/// the DEBUG predecessor, CapturablePanels): the camera bubble deliberately keeps
/// the default sharing type — it MUST join recordings as a feature — so a blanket
/// "reset everything" would break it. Only panels that opt into the
/// hide-from-capture policy register here; the bubble never does.
///
/// Weak references — panels come and go (the toast panel is torn down on every
/// dismiss), and the registry must never keep one alive.
///
/// The STATE is owned by `AppState.panelsCapturable` (which persists it under
/// `defaultsKey` and pushes changes here); the registry itself only holds the
/// current verdict and the windows it applies to. Main-actor, like the panels.
@MainActor
enum PanelCaptureRegistry {
    /// The UserDefaults key `AppState.panelsCapturable` persists under.
    static let defaultsKey = "panelsCapturable"

    private static let panels = NSHashTable<NSWindow>.weakObjects()
    private(set) static var isCapturable = false

    /// The sharing type the current state dictates — pure mapping, applied to
    /// every registered panel and to each new one at registration.
    nonisolated static func sharingType(capturable: Bool) -> NSWindow.SharingType {
        capturable ? .readOnly : .none
    }

    /// Adds a panel to the policy and applies the current state to it.
    static func register(_ window: NSWindow) {
        panels.add(window)
        window.sharingType = sharingType(capturable: isCapturable)
    }

    /// Flips every registered panel between capturable (.readOnly) and hidden
    /// from capture (.none). Called by `AppState.panelsCapturable` — both on user
    /// toggles and once at launch to apply the persisted value.
    static func setCapturable(_ enabled: Bool) {
        isCapturable = enabled
        for window in panels.allObjects {
            window.sharingType = sharingType(capturable: enabled)
        }
    }
}
