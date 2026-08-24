import XCTest
@testable import NoCornyTracer

/// The "~N min left" formula, extracted from MainView's footer into DropboxQuota so
/// the old footer and the command-bar drawer footer share one source of truth.
final class DropboxQuotaTests: XCTestCase {

    private let mb: UInt64 = 1024 * 1024

    func testFullQuotaConvertsAtNineteenPointFiveMBPerMinute() {
        // 1950 MB remaining / 19.5 MB per minute = exactly 100 minutes.
        XCTAssertEqual(DropboxQuota.minutesLeft(used: 0, allocated: 1950 * mb), 100)
    }

    func testUsageIsSubtractedBeforeConverting() {
        XCTAssertEqual(DropboxQuota.minutesLeft(used: 975 * mb, allocated: 1950 * mb), 50)
    }

    func testFractionalMinutesRoundDown() {
        // 30 MB remaining is 1.53 minutes — the footer promises whole minutes.
        XCTAssertEqual(DropboxQuota.minutesLeft(used: 0, allocated: 30 * mb), 1)
    }

    func testAllocatedZeroMeansZeroNotCrash() {
        // Unknown quota (fresh account, sync not run yet) must not divide by zero.
        XCTAssertEqual(DropboxQuota.minutesLeft(used: 0, allocated: 0), 0)
        XCTAssertEqual(DropboxQuota.minutesLeft(used: 500 * mb, allocated: 0), 0)
    }

    func testUsedOverAllocatedClampsToZero() {
        // Overfilled quota (Dropbox lowered the plan) reads 0, never negative.
        XCTAssertEqual(DropboxQuota.minutesLeft(used: 2000 * mb, allocated: 1000 * mb), 0)
    }

    func testMatchesTheOldFooterFormula() {
        // Regression guard: the exact expression this replaced in MainView.footerView.
        let used: UInt64 = 34_252_783_616      // ≈ 31.9 GB
        let allocated: UInt64 = 51_539_607_552 // 48 GiB
        let remaining = max(0, Double(allocated) - Double(used))
        let oldFooterMinutes = Int(remaining / (19.5 * 1024 * 1024))
        XCTAssertEqual(DropboxQuota.minutesLeft(used: used, allocated: allocated), oldFooterMinutes)
    }
}
