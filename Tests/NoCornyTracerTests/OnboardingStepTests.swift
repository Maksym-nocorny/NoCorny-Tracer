import XCTest
@testable import NoCornyTracer

/// Which onboarding card to show (redesign phase 5, Figma 86:551). The pure
/// decision: the screen permission comes first, the cloud question second, and a
/// completed onboarding shows nothing at launch — the permission GATE re-opens
/// step 1 explicitly, outside this function, when a start is blocked.
final class OnboardingStepTests: XCTestCase {

    func testMissingPermissionShowsStepOne() {
        XCTAssertEqual(
            OnboardingFlow.step(hasScreenPermission: false, isSignedIn: false, hasCompletedOnboarding: false),
            .permission
        )
        // Even a signed-in user can't record without the permission.
        XCTAssertEqual(
            OnboardingFlow.step(hasScreenPermission: false, isSignedIn: true, hasCompletedOnboarding: false),
            .permission
        )
    }

    func testPermissionGrantedButSignedOutShowsStepTwo() {
        XCTAssertEqual(
            OnboardingFlow.step(hasScreenPermission: true, isSignedIn: false, hasCompletedOnboarding: false),
            .cloud
        )
    }

    func testPermissionAndSessionMeanNothingToOnboard() {
        XCTAssertEqual(
            OnboardingFlow.step(hasScreenPermission: true, isSignedIn: true, hasCompletedOnboarding: false),
            OnboardingStep.none
        )
    }

    func testCompletedOnboardingShowsNothingAtLaunch() {
        // Completed wins over everything at launch — including a still-missing
        // permission (the gate, not the launch check, handles that case).
        XCTAssertEqual(
            OnboardingFlow.step(hasScreenPermission: false, isSignedIn: false, hasCompletedOnboarding: true),
            OnboardingStep.none
        )
        XCTAssertEqual(
            OnboardingFlow.step(hasScreenPermission: true, isSignedIn: false, hasCompletedOnboarding: true),
            OnboardingStep.none
        )
    }
}
