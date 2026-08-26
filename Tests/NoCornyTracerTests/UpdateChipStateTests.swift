import XCTest
@testable import NoCornyTracer

/// The pure mapping behind the "Relaunch to update" chip (4.2.0): whether the
/// tray-menu item / drawer row exists, what it says, and what a click does.
/// Pure on purpose — decidable without Sparkle or a status bar.
final class UpdateChipStateTests: XCTestCase {

    func testNoPendingVersionMeansNoChip() {
        XCTAssertNil(UpdateChipState.decide(pendingVersion: nil, isRecording: false))
        XCTAssertNil(UpdateChipState.decide(pendingVersion: "", isRecording: true))
    }

    func testPendingUpdateOffersInstallAndRelaunch() {
        XCTAssertEqual(
            UpdateChipState.decide(pendingVersion: "4.2.0", isRecording: false),
            UpdateChipState(title: "Relaunch to update v4.2.0", clickAction: .installAndRelaunch)
        )
    }

    /// The chip stays visible mid-take — hiding it would drop the one place the
    /// user learns an update is ready — but the click explains instead of
    /// relaunching, because a relaunch would end the recording.
    func testRecordingTurnsTheClickIntoAnExplanation() {
        let chip = UpdateChipState.decide(pendingVersion: "4.2.0", isRecording: true)
        XCTAssertEqual(chip?.title, "Relaunch to update v4.2.0")
        XCTAssertEqual(chip?.clickAction, .explainRecordingBlock)
    }

    /// Appcast versions arrive without the "v"; a feed that ships one anyway
    /// must not render "vv4.3.0".
    func testAlreadyPrefixedVersionIsNotDoublePrefixed() {
        let chip = UpdateChipState.decide(pendingVersion: "v4.3.0", isRecording: false)
        XCTAssertEqual(chip?.title, "Relaunch to update v4.3.0")
    }

    /// The bar chip's short label shares the same normalization (round 7).
    func testDisplayVersionNormalizesThePrefix() {
        XCTAssertEqual(UpdateChipState.displayVersion("4.3.0"), "v4.3.0")
        XCTAssertEqual(UpdateChipState.displayVersion("v4.3.0"), "v4.3.0")
    }

    // MARK: The bar chip's visibility (round 7, hybrid A→B)

    /// The bar shows the chip exactly when an update is pending AND no take is
    /// running — mid-take the bar is the pill, which carries no chip. The tray
    /// item and drawer row stay visible mid-take (that is `decide`'s job).
    func testBarChipShowsOnlyWithAPendingUpdateAndNoRecording() {
        XCTAssertTrue(UpdateChipState.showsInBar(pendingVersion: "4.3.0", isRecording: false))
        XCTAssertFalse(UpdateChipState.showsInBar(pendingVersion: "4.3.0", isRecording: true),
                       "mid-take the bar hides its chip")
        XCTAssertFalse(UpdateChipState.showsInBar(pendingVersion: nil, isRecording: false))
        XCTAssertFalse(UpdateChipState.showsInBar(pendingVersion: "", isRecording: false))
    }
}
