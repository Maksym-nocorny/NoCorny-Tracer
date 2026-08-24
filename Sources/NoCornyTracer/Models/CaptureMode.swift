import Foundation

/// What the recorder captures. Chosen from the command bar's capture-mode menu and
/// persisted on AppState (UserDefaults key "captureMode"; the full choice — which
/// window, which area — is CaptureSelection, key "captureSelection").
///
/// All three modes record: entire-screen and window since phase 6a, selected-area
/// since phase 6b wired its picking overlay (AreaSelectionOverlay) to the engine that
/// was already waiting (CaptureGeometry + sourceRect in ScreenRecorder).
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

    /// Whether the capture engine can actually record this mode. All modes are live
    /// since phase 6b shipped the area overlay; the property (and the menu's disabled
    /// styling behind it) stays so a future half-shipped mode has a gate to stand on.
    var isAvailable: Bool { true }
}
