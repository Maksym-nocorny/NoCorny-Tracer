import XCTest
@testable import NoCornyTracer

/// The tray's state mapping and its render descriptors (redesign phase 5). Pure
/// functions on purpose: what the menubar shows must be decidable without a
/// status bar, and the edges are exactly the ones the macro (89:786) draws —
/// recording beats background jobs, background shows only for a positive count.
final class StatusItemStateTests: XCTestCase {

    // MARK: - State mapping

    @MainActor
    func testRecordingBeatsBackgroundJobs() {
        let state = StatusItemController.state(
            isRecording: true, formattedDuration: "12:47", backgroundCount: 3
        )
        XCTAssertEqual(state, .recording(timer: "12:47"))
    }

    @MainActor
    func testBackgroundOnlyForPositiveCount() {
        XCTAssertEqual(
            StatusItemController.state(isRecording: false, formattedDuration: nil, backgroundCount: 2),
            .background(count: 2)
        )
        XCTAssertEqual(
            StatusItemController.state(isRecording: false, formattedDuration: nil, backgroundCount: 0),
            .idle
        )
    }

    @MainActor
    func testIdleWhenNothingHappens() {
        XCTAssertEqual(
            StatusItemController.state(isRecording: false, formattedDuration: "00:00", backgroundCount: 0),
            .idle
        )
    }

    @MainActor
    func testRecordingWithNoDurationYetShowsZeroTimer() {
        XCTAssertEqual(
            StatusItemController.state(isRecording: true, formattedDuration: nil, backgroundCount: 0),
            .recording(timer: "00:00")
        )
    }

    // MARK: - Left-click routing (round 3: hidden pill vs stop)

    /// A left click mid-recording STOPS only while the pill panel is visible;
    /// with the pill hidden (its round-3 chevron), the first click brings the
    /// pill back — the documented two-clicks-to-stop compromise.
    @MainActor
    func testRecordingClickStopsOnlyWhileThePillIsVisible() {
        XCTAssertEqual(
            StatusItemController.leftClickAction(state: .recording(timer: "12:47"), isCommandBarVisible: true),
            .stopRecording
        )
        XCTAssertEqual(
            StatusItemController.leftClickAction(state: .recording(timer: "12:47"), isCommandBarVisible: false),
            .showRecordingPill
        )
    }

    /// Panel visibility only matters mid-recording — idle and background keep
    /// their historical routes either way.
    @MainActor
    func testIdleAndBackgroundRoutesIgnorePanelVisibility() {
        for visible in [true, false] {
            XCTAssertEqual(
                StatusItemController.leftClickAction(state: .idle, isCommandBarVisible: visible),
                .showCommandBar
            )
            XCTAssertEqual(
                StatusItemController.leftClickAction(state: .background(count: 2), isCommandBarVisible: visible),
                .showGallery
            )
        }
    }

    // MARK: - Render descriptors

    @MainActor
    func testIdleRendersTemplateMarkAndEmptyTitle() {
        let render = StatusItemController.render(.idle)
        XCTAssertEqual(render, .init(icon: .idleMark, title: ""))
    }

    @MainActor
    func testRecordingRendersDotAndSpacedTimer() {
        let render = StatusItemController.render(.recording(timer: "12:47"))
        XCTAssertEqual(render, .init(icon: .recordingDot, title: " 12:47"))
    }

    @MainActor
    func testBackgroundRendersCloudAndArrowCount() {
        let render = StatusItemController.render(.background(count: 2))
        XCTAssertEqual(render, .init(icon: .backgroundCloud, title: " ↑2"))
    }
}
