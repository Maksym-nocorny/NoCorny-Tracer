import XCTest
@testable import NoCornyTracer

/// Stopping a recording now saves twice: once when the file is finalised, once after the
/// system-audio merge. It has to, because the merge takes minutes on a long meeting and a
/// take that exists only as a value in flight dies with the process - quitting right after a
/// call is the ordinary thing to do, and it used to lose the recording outright.
///
/// Two writes mean the second one must find the first.
final class StopBookkeepingTests: XCTestCase {

    private func recording(_ duration: TimeInterval = 60) -> Recording {
        Recording(fileURL: URL(fileURLWithPath: "/tmp/take.mp4"), createdAt: Date(), duration: duration)
    }

    func testTheSecondWriteUpdatesTheRowRatherThanAddingOne() {
        let first = recording()
        var second = first
        second.fileSize = 5_000_000

        let after = AppState.writing(second, into: AppState.writing(first, into: []))
        XCTAssertEqual(after.count, 1, "one recording produced two rows in the list")
        XCTAssertEqual(after[0].fileSize, 5_000_000, "the merged size never reached the row")
    }

    func testANewTakeGoesToTheTop() {
        let older = recording(30)
        let newer = recording(90)
        let after = AppState.writing(newer, into: [older])
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].id, newer.id, "the new recording did not land at the top of the list")
    }

    func testUpdatingDoesNotReorderTheList() {
        let older = recording(30)
        let newer = recording(90)
        var updated = older
        updated.fileSize = 1
        let after = AppState.writing(updated, into: [newer, older])
        XCTAssertEqual(after.map(\.id), [newer.id, older.id], "an update moved a row")
    }

    // MARK: - What counts as stranded after a restart

    /// Both mean "the run that was going to handle this is gone". `.uploading` had a task
    /// that no longer exists; `.notUploaded` never got one, which is where quitting during a
    /// recording leaves it - and the retry the list offers is only for `.failed`.
    func testBothAbandonedStatesAreRecognised() {
        XCTAssertTrue(AppState.isStrandedAtLaunch(.uploading))
        XCTAssertTrue(AppState.isStrandedAtLaunch(.notUploaded))
    }

    func testAFinishedOrFailedRecordingIsLeftAlone() {
        XCTAssertFalse(AppState.isStrandedAtLaunch(.uploaded), "a finished upload would be marked broken on every launch")
        XCTAssertFalse(AppState.isStrandedAtLaunch(.failed), "a failed upload would have its own error message overwritten")
    }
}

/// The server's title column is NOT NULL and the API substitutes a placeholder when a
/// recording has no generated name yet. So the line that assigned it could never see "nothing"
/// and be careful about it - it saw a plausible string and wrote it over the real name.
final class TitleSurvivesSyncTests: XCTestCase {

    private let placeholder = "Recording · 29 Apr 2026 14:32"

    func testAGeneratedNameIsNotReplacedByThePlaceholder() {
        XCTAssertEqual(
            AppState.titleToKeep(fromServer: placeholder, local: "Layoff plan review"),
            "Layoff plan review",
            "a sync arriving before the title PATCH landed erased the generated name"
        )
    }

    func testARealServerTitleWins() {
        XCTAssertEqual(
            AppState.titleToKeep(fromServer: "Renamed on the site", local: "Layoff plan review"),
            "Renamed on the site",
            "renaming a recording on the site stopped working"
        )
    }

    func testWithNoLocalNameThePlaceholderIsFineToShow() {
        XCTAssertEqual(AppState.titleToKeep(fromServer: placeholder, local: nil), placeholder)
        XCTAssertEqual(AppState.titleToKeep(fromServer: placeholder, local: ""), placeholder)
    }

    /// A recording someone genuinely titled "Recording · something" on the site is not a
    /// placeholder, and this is where the two are told apart.
    func testOnlyTheGeneratedShapeCountsAsAPlaceholder() {
        XCTAssertTrue(AppState.isPlaceholderTitle(placeholder))
        XCTAssertFalse(AppState.isPlaceholderTitle("Recording notes"))
        XCTAssertFalse(AppState.isPlaceholderTitle("Weekly sync"))
        XCTAssertFalse(AppState.isPlaceholderTitle(""))
    }
}
