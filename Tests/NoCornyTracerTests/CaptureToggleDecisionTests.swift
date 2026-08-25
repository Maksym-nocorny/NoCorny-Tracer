import XCTest
import AVFoundation
@testable import NoCornyTracer

/// The mic/cam toggle permission gate (verdict 25.08: the camera toggle lit up
/// over a denied camera and nobody asked the system or told the user).
final class CaptureToggleDecisionTests: XCTestCase {

    func testAuthorizedEnablesRightAway() {
        XCTAssertEqual(CaptureToggleDecision.forTurningOn(status: .authorized), .enable)
    }

    func testNotDeterminedAsksTheSystem() {
        XCTAssertEqual(
            CaptureToggleDecision.forTurningOn(status: .notDetermined), .requestAccess,
            "first-ever toggle must produce the one-tap system prompt"
        )
    }

    func testDeniedStaysOffAndExplains() {
        XCTAssertEqual(
            CaptureToggleDecision.forTurningOn(status: .denied), .deniedFeedback,
            "the prompt will not appear again — the toggle stays off and points at System Settings"
        )
    }

    func testRestrictedBehavesLikeDenied() {
        XCTAssertEqual(CaptureToggleDecision.forTurningOn(status: .restricted), .deniedFeedback)
    }
}
