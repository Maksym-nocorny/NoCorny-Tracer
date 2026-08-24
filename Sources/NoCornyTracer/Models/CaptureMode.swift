import Foundation

/// What the recorder captures. Chosen from the command bar's capture-mode menu and
/// persisted on AppState (UserDefaults key "captureMode").
///
/// Only `.entireScreen` actually records today — window and selected-area capture are
/// phase 6 of the redesign. The menu shows the other two disabled rather than letting
/// the user pick a mode that silently records the whole screen anyway.
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

    /// Whether the capture engine can actually record this mode (phase 6 flips the rest).
    var isAvailable: Bool { self == .entireScreen }
}
