import XCTest
@testable import NoCornyTracer

/// The pure gate behind the coordinator's 5-minute update poll (round 7):
/// whether a timer tick may call `checkForUpdatesInBackground()` right now.
/// Pure on purpose — decidable without Sparkle, a timer, or an updater.
final class UpdatePollGateTests: XCTestCase {

    /// The quiet steady state: auto-checks on, nothing pending, Sparkle idle,
    /// no recording — the only combination that polls.
    func testIdleStatePolls() {
        XCTAssertTrue(UpdateCoordinator.shouldPoll(
            sessionInProgress: false, pending: false, recording: false, autoChecksOn: true
        ))
    }

    /// The Settings toggle turns off OUR timer's effect too, not just Sparkle's
    /// scheduler — OFF must mean no background traffic at all.
    func testAutoChecksOffSilencesThePoll() {
        XCTAssertFalse(UpdateCoordinator.shouldPoll(
            sessionInProgress: false, pending: false, recording: false, autoChecksOn: false
        ))
    }

    /// A staged update has already stalled Sparkle's cycles
    /// (willInstallUpdateOnQuit returned true) — polling adds nothing before
    /// the relaunch.
    func testPendingUpdateStopsThePoll() {
        XCTAssertFalse(UpdateCoordinator.shouldPoll(
            sessionInProgress: false, pending: true, recording: false, autoChecksOn: true
        ))
    }

    /// Mid-cycle Sparkle documents checkForUpdatesInBackground as a no-op —
    /// don't poke it.
    func testSessionInProgressStopsThePoll() {
        XCTAssertFalse(UpdateCoordinator.shouldPoll(
            sessionInProgress: true, pending: false, recording: false, autoChecksOn: true
        ))
    }

    /// The delegate's recording gate would decline the check anyway (with a log
    /// line per decline) — the poll skips at the source instead.
    func testRecordingStopsThePoll() {
        XCTAssertFalse(UpdateCoordinator.shouldPoll(
            sessionInProgress: false, pending: false, recording: true, autoChecksOn: true
        ))
    }

    /// Belt and braces: any combination of blockers still refuses.
    func testEverythingBlockedRefuses() {
        XCTAssertFalse(UpdateCoordinator.shouldPoll(
            sessionInProgress: true, pending: true, recording: true, autoChecksOn: false
        ))
    }

    /// The cadence and tolerance the coordinator schedules with — pinned so a
    /// future tweak is a conscious decision, not a drive-by.
    func testPollCadenceIsFiveMinutesWithBatteryTolerance() {
        XCTAssertEqual(UpdateCoordinator.pollInterval, 300)
        XCTAssertEqual(UpdateCoordinator.pollTolerance, 30)
    }
}
