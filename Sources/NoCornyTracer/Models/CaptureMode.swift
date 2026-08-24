import Foundation

/// What the recorder captures. Chosen from the command bar's capture-mode menu and
/// persisted on AppState (UserDefaults key "captureMode"; the full choice — which
/// window, which area — is CaptureSelection, key "captureSelection").
///
/// Entire-screen and window record today (phase 6a). Selected-area has its engine wired
/// (CaptureGeometry + sourceRect in ScreenRecorder) but waits for the area-picking
/// overlay (phase 6b), so the menu shows that row disabled rather than letting the user
/// pick a mode that silently records the whole screen anyway.
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

    /// Whether the capture engine can actually record this mode. Selected-area flips
    /// when its overlay ships (phase 6b).
    var isAvailable: Bool { self != .selectedArea }
}
