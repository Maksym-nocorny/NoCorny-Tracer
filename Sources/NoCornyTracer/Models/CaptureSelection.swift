import Foundation
import CoreGraphics

/// The remembered capture choice: the mode plus whatever that mode points at — a window
/// (by CGWindowID) or an area of a display. Persisted as JSON under "captureSelection" so
/// the next recording is one click: pick a window once, and the record button reuses it
/// until the window closes.
///
/// The details survive a mode switch on purpose. Switching to Entire Screen and back to
/// Window keeps the remembered window; only picking a different one replaces it.
///
/// Liveness is checked at the moment of use, not stored: `isSatisfiable` answers "can this
/// selection start a recording right now" from a fresh SCShareableContent snapshot, and a
/// dead selection falls back to an honest re-pick (the picker again) rather than silently
/// recording the whole screen.
struct CaptureSelection: Codable, Equatable {
    var mode: CaptureMode = .entireScreen
    /// The picked window, for `.window` mode. CGWindowIDs are never reused within a login
    /// session, so a stale ID simply matches nothing — it cannot point at the wrong window.
    var windowID: CGWindowID?
    /// Shown in the capture menu and tooltips ("Window — Safari"). Display only; the ID is
    /// what identifies the window.
    var windowTitle: String?
    /// The selected area for `.selectedArea` mode, in POINTS in the display's local
    /// coordinate space (top-left origin) — the same space SCStreamConfiguration.sourceRect
    /// is documented to use.
    var areaRect: CGRect?
    /// Which display the area lives on. The rect is meaningless on another display, so the
    /// selection dies with the display. nil = whatever display the recorder has selected.
    var areaDisplayID: CGDirectDisplayID?

    // MARK: - Persistence

    static let defaultsKey = "captureSelection"

    /// nil when nothing was ever saved or the payload does not decode (a corrupt value is
    /// treated as absent, not as an error — the default selection is always a safe start).
    static func load(from defaults: UserDefaults) -> CaptureSelection? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(CaptureSelection.self, from: data)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: - Retired modes (round 6)

    /// Selected Area left the UI in round 6 («дуже багована фіча») — the case only
    /// survives in `CaptureMode` so an old persisted payload still decodes. This is
    /// the load-time migration: a remembered area selection becomes a plain
    /// entire-screen one, with the dead rect dropped. Pure, so it is testable;
    /// AppState applies it right after `load` and saves the result back.
    func migratingRetiredModes() -> CaptureSelection {
        guard mode == .selectedArea else { return self }
        var migrated = self
        migrated.mode = .entireScreen
        migrated.areaRect = nil
        migrated.areaDisplayID = nil
        return migrated
    }

    // MARK: - Liveness

    /// Whether this selection can start a recording right now, given what is actually on
    /// screen. Pure so it is testable: the caller snapshots SCShareableContent and passes
    /// the IDs in.
    ///
    /// - `.entireScreen` always can.
    /// - `.window` needs its remembered window to still be on screen.
    /// - `.selectedArea` needs a rect, and — when it remembers a display — that display
    ///   still connected. A rect with no display ID rides on the recorder's currently
    ///   selected display, so it stays satisfiable.
    func isSatisfiable(liveWindowIDs: Set<CGWindowID>, liveDisplayIDs: Set<CGDirectDisplayID>) -> Bool {
        switch mode {
        case .entireScreen:
            return true
        case .window:
            guard let windowID else { return false }
            return liveWindowIDs.contains(windowID)
        case .selectedArea:
            guard areaRect != nil else { return false }
            guard let areaDisplayID else { return true }
            return liveDisplayIDs.contains(areaDisplayID)
        }
    }
}
