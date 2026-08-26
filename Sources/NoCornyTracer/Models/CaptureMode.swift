import Foundation

/// What the recorder captures. Chosen from the command bar's capture-mode menu and
/// persisted on AppState (UserDefaults key "captureMode"; the full choice — which
/// window — is CaptureSelection, key "captureSelection").
///
/// `.selectedArea` was RETIRED in round 6 (verdict from the 4.2.1 build: «дуже
/// багована фіча»): the picking overlay and every UI door are gone. The case stays
/// in the enum ONLY so an old persisted selection still decodes — it is not
/// available, never shown in the menu, and migrates to `.entireScreen` on load
/// (`CaptureSelection.migratingRetiredModes`).
enum CaptureMode: String, CaseIterable, Codable {
    case entireScreen
    case window
    case selectedArea

    var displayName: String {
        switch self {
        case .entireScreen: return "Entire Screen"
        case .window: return "Window"
        case .selectedArea: return "Selected Area"
        }
    }

    /// SF Symbol shown next to the mode in the capture menu.
    var symbolName: String {
        switch self {
        case .entireScreen: return "display"
        case .window: return "macwindow"
        case .selectedArea: return "viewfinder"
        }
    }

    /// Whether the mode is offered to the user at all. Since round 6 an unavailable
    /// mode is HIDDEN from the capture menu (not greyed out): `.selectedArea` exists
    /// only to decode old persisted selections and must not resurface as a row.
    var isAvailable: Bool {
        switch self {
        case .entireScreen, .window: return true
        case .selectedArea: return false
        }
    }

    /// The modes the capture menu shows — the available ones, in declaration order.
    static var menuCases: [CaptureMode] { allCases.filter(\.isAvailable) }
}
