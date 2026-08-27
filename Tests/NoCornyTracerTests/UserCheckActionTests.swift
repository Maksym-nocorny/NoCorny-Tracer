import XCTest
@testable import NoCornyTracer

/// ROUND 14 — the regression net under «натискаю Check for Updates, нічого не
/// відбувається» (боєва 4.5.1).
///
/// The button used to go straight to `-[SPUUpdater checkForUpdates]` in every
/// state. That call returns SILENTLY while an update session is alive — and our
/// own `willInstallUpdateOnQuit → true` keeps the automatic driver's session
/// alive for the rest of the process once an update is staged. So the one state
/// in which the user most wants the button (an update is downloaded and
/// waiting) was exactly the state in which it did nothing at all.
///
/// `userCheckAction` is the whole fix expressed as a pure function: three
/// states, three visible outcomes, and never a fourth "nothing happens".
final class UserCheckActionTests: XCTestCase {

    // MARK: The three states

    /// Nothing staged → ask Sparkle. This is the only branch that is allowed to
    /// touch `checkForUpdates` at all.
    func testNothingPendingAsksSparkle() {
        XCTAssertEqual(
            UpdateCoordinator.userCheckAction(pending: nil, isRecording: false),
            .askSparkle
        )
        XCTAssertEqual(
            UpdateCoordinator.userCheckAction(pending: nil, isRecording: true),
            .askSparkle
        )
    }

    /// THE BUG, pinned: a staged update must install, not go to Sparkle.
    func testStagedUpdateInstallsInsteadOfAskingSparkle() {
        XCTAssertEqual(
            UpdateCoordinator.userCheckAction(pending: "4.5.1", isRecording: false),
            .install
        )
        XCTAssertNotEqual(
            UpdateCoordinator.userCheckAction(pending: "4.5.1", isRecording: false),
            .askSparkle,
            "a staged update handed to checkForUpdates is answered with silence — that was 4.5.0"
        )
    }

    /// Mid-take a relaunch would end the recording, so the click explains. It
    /// still does something VISIBLE — that is the contract.
    func testStagedUpdateMidTakeExplainsInsteadOfRelaunching() {
        XCTAssertEqual(
            UpdateCoordinator.userCheckAction(pending: "4.5.1", isRecording: true),
            .toastWaitForTake
        )
    }

    /// An empty version is not a pending update (the appcast can hand us one).
    func testEmptyVersionIsNotPending() {
        XCTAssertEqual(
            UpdateCoordinator.userCheckAction(pending: "", isRecording: false),
            .askSparkle
        )
    }

    // MARK: The contract itself

    /// Every reachable combination must land on one of the three visible
    /// outcomes. The point is not the enum's exhaustiveness — the compiler does
    /// that — but that no input maps to "the button was pressed and nothing
    /// was shown", which is only expressible as a missing branch upstream.
    func testEveryStateProducesAVisibleOutcome() {
        for pending in [nil, "", "4.5.1", "v4.6.0"] as [String?] {
            for recording in [false, true] {
                let action = UpdateCoordinator.userCheckAction(
                    pending: pending, isRecording: recording
                )
                XCTAssertTrue(
                    [.install, .toastWaitForTake, .askSparkle].contains(action),
                    "pending=\(pending ?? "nil") recording=\(recording) fell through"
                )
            }
        }
    }

    /// The button and the chip are the same door, so they may never disagree
    /// about what a click means: wherever the chip offers a relaunch the button
    /// must install, wherever it explains the button must explain, and where
    /// there is no chip the button must ask Sparkle.
    func testTheButtonAndTheChipAlwaysAgree() {
        for pending in [nil, "", "4.5.1", "v4.6.0"] as [String?] {
            for recording in [false, true] {
                let chip = UpdateChipState.decide(pendingVersion: pending, isRecording: recording)
                let action = UpdateCoordinator.userCheckAction(
                    pending: pending, isRecording: recording
                )
                switch chip?.clickAction {
                case .none:
                    XCTAssertEqual(action, .askSparkle,
                                   "no chip must mean askSparkle (pending=\(pending ?? "nil"))")
                case .installAndRelaunch:
                    XCTAssertEqual(action, .install)
                case .explainRecordingBlock:
                    XCTAssertEqual(action, .toastWaitForTake)
                }
            }
        }
    }

    // MARK: One door, in the source

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/NoCornyTracer")

    /// Only `UpdateCoordinator` may talk to Sparkle's manual check. A surface
    /// that reaches past the door re-opens the bug for its own button — and
    /// that is exactly how the drawer's link and the chip drifted apart.
    func testOnlyTheCoordinatorCallsSparkleDirectly() throws {
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(fm.enumerator(at: Self.sourceRoot,
                                                     includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard url.lastPathComponent != "UpdateCoordinator.swift" else { continue }
            let lines = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where line.contains("checkForUpdates(") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///") else { continue }
                offenders.append("\(url.lastPathComponent):\(index + 1) — \(trimmed)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            Sparkle's manual check called outside UpdateCoordinator — it returns \
            silently while an update is staged, so this button can do nothing:
            \(offenders.joined(separator: "\n"))
            """)
    }

    /// The three update surfaces call the ONE door. A surface that grew its own
    /// spelling is a surface that will answer differently from the others.
    func testEverySurfaceUsesTheOneDoor() throws {
        let surfaces = [
            "Views/CommandBar/DrawerSettingsView.swift",
            "Managers/StatusItemController.swift",
        ]
        for relative in surfaces {
            let text = try String(
                contentsOf: Self.sourceRoot.appendingPathComponent(relative),
                encoding: .utf8
            )
            XCTAssertTrue(text.contains("UpdateCoordinator.handleUpdateRequest()"),
                          "\(relative) no longer goes through the one door")
        }
    }
}
