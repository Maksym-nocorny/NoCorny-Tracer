import XCTest
@testable import NoCornyTracer

/// The pure decision behind the amber storage banner: `StorageAlert.level(used:allocated:)`.
final class StorageAlertLevelTests: XCTestCase {

    private let gb: UInt64 = 1024 * 1024 * 1024

    // MARK: Unknown quota

    func testUnknownAllocationIsOk() {
        XCTAssertEqual(StorageAlert.level(used: nil, allocated: nil), .ok)
        XCTAssertEqual(StorageAlert.level(used: 500, allocated: nil), .ok,
                       "used bytes without an allocation say nothing")
        XCTAssertEqual(StorageAlert.level(used: 500, allocated: 0), .ok,
                       "a zero allocation reads as quota-unknown, not as full")
    }

    func testNilUsedReadsAsEmpty() {
        XCTAssertEqual(StorageAlert.level(used: nil, allocated: 2 * gb), .ok)
    }

    // MARK: Threshold

    func testPlentyOfRoomIsOk() {
        XCTAssertEqual(StorageAlert.level(used: gb, allocated: 2 * gb), .ok)
    }

    func testExactlyTenPercentRemainingIsStillOk() {
        XCTAssertEqual(StorageAlert.level(used: 900, allocated: 1000), .ok,
                       "the gate is strictly less than 10% remaining")
    }

    func testJustUnderTenPercentIsLow() {
        // 2 GB allocation, 95% used → ~102 MB left → 5 whole minutes at 19.5 MB/min.
        let allocated = 2 * gb
        let used = UInt64(Double(allocated) * 0.95)
        let level = StorageAlert.level(used: used, allocated: allocated)
        XCTAssertEqual(
            level,
            .low(minutesLeft: DropboxQuota.minutesLeft(used: used, allocated: allocated)),
            "the banner's minutes and the drawer footer's minutes come from one formula"
        )
        XCTAssertEqual(level, .low(minutesLeft: 5))
    }

    func testSliversOfRoomAreLowWithZeroMinutes() {
        // One byte left: not .full yet, but no whole minute of recording fits.
        XCTAssertEqual(StorageAlert.level(used: 999, allocated: 1000), .low(minutesLeft: 0))
    }

    // MARK: Full

    func testZeroRemainingIsFull() {
        XCTAssertEqual(StorageAlert.level(used: 1000, allocated: 1000), .full)
    }

    func testOverQuotaIsFull() {
        XCTAssertEqual(StorageAlert.level(used: 1200, allocated: 1000), .full,
                       "used beyond allocated must not wrap into a huge remainder")
    }
}
