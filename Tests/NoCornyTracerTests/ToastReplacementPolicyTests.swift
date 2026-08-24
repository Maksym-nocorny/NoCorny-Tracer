import XCTest
@testable import NoCornyTracer

/// One panel, and the pure rule for who gets it. The historical behavior was "latest
/// wins", which let "Uploaded — link copied" shove the mic-lost warning off the screen
/// before anyone read it. The rule now: a live critical toast keeps the panel against
/// info arrivals for its whole duration; critical replaces anything; a free (or expired)
/// panel takes whatever comes. The losing info toast is dropped, not queued — replaying
/// glanceable news later would surface it stale.
final class ToastReplacementPolicyTests: XCTestCase {

    func testAnEmptyPanelTakesAnything() {
        XCTAssertTrue(ToastWindowManager.shouldReplace(current: nil, remaining: 0, incoming: .info))
        XCTAssertTrue(ToastWindowManager.shouldReplace(current: nil, remaining: 0, incoming: .critical))
    }

    func testInfoReplacesInfo() {
        // The historical "latest wins", kept for equal-weight news.
        XCTAssertTrue(ToastWindowManager.shouldReplace(current: .info, remaining: 3, incoming: .info))
    }

    func testCriticalReplacesAnything() {
        XCTAssertTrue(ToastWindowManager.shouldReplace(current: .info, remaining: 3, incoming: .critical))
        XCTAssertTrue(ToastWindowManager.shouldReplace(current: .critical, remaining: 3, incoming: .critical),
                      "newer news of the same weight lost to older news")
    }

    func testInfoDoesNotReplaceALiveCriticalToast() {
        // The bug this rule closes: the mic-lost warning replaced by an upload toast.
        XCTAssertFalse(ToastWindowManager.shouldReplace(current: .critical, remaining: 5, incoming: .info))
    }

    func testAnExpiredCriticalToastNoLongerHoldsThePanel() {
        // The hold is exactly the critical toast's duration, not forever.
        XCTAssertTrue(ToastWindowManager.shouldReplace(current: .critical, remaining: 0, incoming: .info))
        XCTAssertTrue(ToastWindowManager.shouldReplace(current: .critical, remaining: -1, incoming: .info))
    }
}
