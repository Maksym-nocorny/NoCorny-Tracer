import XCTest
@testable import NoCornyTracer

/// The DEBUG-only fake-state store behind the tray's "UI Preview" submenu
/// (verdict 24.08: the demo could not show the pills/toasts/banner). Tests build
/// in the debug configuration, so the type exists here; in release neither the
/// store nor these tests exist.
@MainActor
final class UIPreviewStateTests: XCTestCase {

    private var state: UIPreviewState { UIPreviewState.shared }

    override func tearDown() {
        UIPreviewState.shared.reset()
        super.tearDown()
    }

    // MARK: Pill

    func testShowPillRecordingStartsAtZero() {
        state.showPill(paused: false)
        XCTAssertEqual(state.pill, .recording)
        XCTAssertEqual(state.formattedElapsed, "00:00")
    }

    func testShowPillPausedStartsMidTake() {
        state.showPill(paused: true)
        XCTAssertEqual(state.pill, .paused)
        XCTAssertEqual(state.formattedElapsed, "01:23",
                       "a paused take frozen at 00:00 would read as broken")
    }

    func testTogglePausedFlipsBothWays() {
        state.showPill(paused: false)
        state.togglePaused()
        XCTAssertEqual(state.pill, .paused)
        state.togglePaused()
        XCTAssertEqual(state.pill, .recording)
    }

    func testEndPillClearsPillAndClock() {
        state.showPill(paused: true)
        state.endPill()
        XCTAssertNil(state.pill)
        XCTAssertEqual(state.formattedElapsed, "00:00")
    }

    // MARK: Reset

    func testResetClearsEverything() {
        state.showPill(paused: false)
        state.storageLevel = .full

        state.reset()

        XCTAssertNil(state.pill)
        XCTAssertNil(state.storageLevel)
    }
}
