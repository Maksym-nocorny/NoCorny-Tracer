import XCTest
@testable import NoCornyTracer

/// When the on-device model comes down on its own. It is the default engine since 4.6.0, and
/// a default that waits for a click in Settings sends every recording to the cloud meanwhile.
final class LocalModelAutoDownloadPolicyTests: XCTestCase {

    private func may(
        engineIsLocal: Bool = true, modelPresent: Bool = false, downloading: Bool = false,
        busy: Bool = false, lowPower: Bool = false, optedOut: Bool = false,
        expensiveNetwork: Bool = false, failedRecently: Bool = false
    ) -> Bool {
        LocalModelWarmup.mayDownload(
            engineIsLocal: engineIsLocal, modelPresent: modelPresent, downloading: downloading,
            busy: busy, lowPower: lowPower, optedOut: optedOut,
            expensiveNetwork: expensiveNetwork, failedRecently: failedRecently
        )
    }

    func testAFreshLocalUserWithoutAModelGetsOne() {
        XCTAssertTrue(may())
    }

    func testEveryBlockerHoldsTheDownloadOnItsOwn() {
        let blockers: [(String, Bool)] = [
            ("cloud engine chosen", may(engineIsLocal: false)),
            ("model already complete", may(modelPresent: true)),
            ("download already running", may(downloading: true)),
            ("recording, uploading or transcribing", may(busy: true)),
            ("low power mode", may(lowPower: true)),
            ("the user pressed Remove", may(optedOut: true)),
            ("a hotspot or metered connection", may(expensiveNetwork: true)),
            ("a download failed a moment ago", may(failedRecently: true)),
        ]
        for (name, allowed) in blockers {
            XCTAssertFalse(allowed, "\(name) did not hold the download")
        }
    }

    /// The first look comes well before the warm's: bytes do not compete with a take the way
    /// the compile does, and every minute without the model is a recording in the cloud.
    func testTheFirstLookIsSoonerThanAWarmsAndStillNotInstant() {
        XCTAssertLessThan(LocalModelWarmup.downloadDelay, LocalModelWarmup.launchDelay)
        XCTAssertGreaterThanOrEqual(LocalModelWarmup.downloadDelay, 30)
    }

    /// A failure holds the next attempt for hours, not for the life of the process: the app
    /// lives for weeks between launches.
    func testAFailureHoldsForHoursNotForever() {
        XCTAssertGreaterThanOrEqual(LocalModelWarmup.retryAfterFailure, 3600)
        XCTAssertLessThan(LocalModelWarmup.retryAfterFailure, 24 * 3600)
    }

    func testTheOptOutKeyIsStable() {
        // Persisted in defaults; renaming it would silently re-download for everyone who
        // pressed Remove.
        XCTAssertEqual(LocalModelWarmup.autoDownloadOptOutKey, "localModelAutoDownloadOptOut")
    }
}
