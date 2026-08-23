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

/// The Speakers menu has seven options and lives on rows near the bottom of a list. Opening
/// downwards always put its last options past the window edge, where they cannot be clicked.
final class DropdownPlacementTests: XCTestCase {

    private let window: CGFloat = 540
    private let menu: CGFloat = 196   // seven rows at 28pt

    func testAMenuWithRoomBelowStillOpensDownwards() {
        let trigger = CGRect(x: 0, y: 100, width: 120, height: 24)
        let centre = CustomDropdownOverlay.menuCenterY(triggerRect: trigger, menuHeight: menu, availableHeight: window)
        XCTAssertGreaterThan(centre, trigger.maxY, "a menu with room below moved somewhere else")
        XCTAssertLessThanOrEqual(centre + menu / 2, window)
    }

    func testAMenuWithoutRoomBelowOpensUpwards() {
        let trigger = CGRect(x: 0, y: 470, width: 120, height: 24)
        let centre = CustomDropdownOverlay.menuCenterY(triggerRect: trigger, menuHeight: menu, availableHeight: window)
        // The BOTTOM of the menu has to clear the TOP of the trigger. Asserting only that the
        // centre sits above the trigger passes just as happily when the menu stayed below and
        // was merely clamped back inside the window - which leaves it covering the row it
        // belongs to, and was exactly what this test did at first.
        XCTAssertLessThanOrEqual(centre + menu / 2, trigger.minY,
                                 "the menu did not flip above the trigger; it was only clamped inside the window")
        XCTAssertGreaterThanOrEqual(centre - menu / 2, 0, "flipping up pushed it off the top instead")
    }

    /// Every option has to be inside the window, whichever way it opened.
    func testEveryOptionStaysInsideTheWindow() {
        for top in stride(from: CGFloat(0), through: window - 24, by: 20) {
            let trigger = CGRect(x: 0, y: top, width: 120, height: 24)
            let centre = CustomDropdownOverlay.menuCenterY(triggerRect: trigger, menuHeight: menu, availableHeight: window)
            XCTAssertGreaterThanOrEqual(centre - menu / 2, -0.001, "clipped at the top for a trigger at \(top)")
            XCTAssertLessThanOrEqual(centre + menu / 2, window + 0.001, "clipped at the bottom for a trigger at \(top)")
        }
    }

    /// Neither side has room, but the menu would still fit somewhere in the window. This is
    /// the case the clamp exists for, and with seven 28pt rows it is unreachable - so it went
    /// untested until a mutant removed the clamp and nothing noticed.
    func testAMenuThatFitsNowhereIsStillKeptInsideTheWindow() {
        let tall: CGFloat = 400
        let trigger = CGRect(x: 0, y: 200, width: 120, height: 24)
        let centre = CustomDropdownOverlay.menuCenterY(triggerRect: trigger, menuHeight: tall, availableHeight: window)
        XCTAssertGreaterThanOrEqual(centre - tall / 2, -0.001, "ran off the top")
        XCTAssertLessThanOrEqual(centre + tall / 2, window + 0.001, "ran off the bottom")
    }

    /// A menu taller than the window cannot fit either way; centring beats pinning it to an
    /// edge it overflows in one direction.
    func testAMenuTallerThanTheWindowIsCentred() {
        let trigger = CGRect(x: 0, y: 100, width: 120, height: 24)
        let centre = CustomDropdownOverlay.menuCenterY(triggerRect: trigger, menuHeight: 900, availableHeight: window)
        XCTAssertEqual(centre, window / 2)
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
