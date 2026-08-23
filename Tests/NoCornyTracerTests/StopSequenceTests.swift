import XCTest
@testable import NoCornyTracer

/// The order a stop happens in, and what the list looks like afterwards.
///
/// Both were invisible failures. Handing the take over after the merge meant that for the
/// minutes a long export takes there was no row anywhere and no timer - and quitting there,
/// which is what people do after a meeting, lost the recording. Then handing it over first
/// made the row deletable mid-merge, and writing the second copy unconditionally brought it
/// back pointing at a file that had just been removed.
final class StopSequenceTests: XCTestCase {

    private func take() -> Recording {
        Recording(fileURL: URL(fileURLWithPath: "/tmp/take.mp4"), createdAt: Date(), duration: 60)
    }

    // MARK: - Order

    func testTheTakeIsHandedOverBeforeTheMergeStarts() async {
        var events: [String] = []
        _ = await RecordingManager.finishTake(
            take(),
            handOver: { _ in events.append("handOver") },
            markFinishing: { events.append($0 ? "finishing" : "done") },
            merge: { events.append("merge") },
            sizeOnDisk: { events.append("size"); return 1 }
        )
        XCTAssertEqual(events, ["handOver", "finishing", "merge", "done", "size"])
    }

    /// The flag a quit waits on has to be up for the whole merge and down after it. Without
    /// it the quit handler sees an idle app and kills the export.
    func testTheBusyFlagBracketsTheMerge() async {
        var duringMerge: Bool?
        var finishing = false
        _ = await RecordingManager.finishTake(
            take(),
            handOver: { _ in },
            markFinishing: { finishing = $0 },
            merge: { duringMerge = finishing },
            sizeOnDisk: { nil }
        )
        XCTAssertEqual(duringMerge, true, "a quit during the merge would have seen an idle app")
        XCTAssertFalse(finishing, "the app would refuse to quit for a minute after every stop")
    }

    /// The merge rewrites the file, so a size read before it is the wrong number.
    func testTheSizeIsTheOneTheMergeLeftBehind() async {
        var merged = false
        let result = await RecordingManager.finishTake(
            take(),
            handOver: { _ in },
            markFinishing: { _ in },
            merge: { merged = true },
            sizeOnDisk: { merged ? 9_000 : 1_000 }
        )
        XCTAssertEqual(result.fileSize, 9_000)
    }

    func testTheTakeHandedOverIsTheOneThatComesBack() async {
        let original = take()
        var handedOver: Recording?
        let result = await RecordingManager.finishTake(
            original,
            handOver: { handedOver = $0 },
            markFinishing: { _ in },
            merge: {},
            sizeOnDisk: { 1 }
        )
        XCTAssertEqual(handedOver?.id, original.id)
        XCTAssertEqual(result.id, original.id, "the second write would land on a different row")
    }

    // MARK: - What the list does with the result

    func testDeletingDuringTheMergeKeepsItDeleted() {
        let saved = take()
        XCTAssertNil(
            AppState.applyingStopResult(saved, alreadySaved: true, to: []),
            "a recording deleted while its audio was mixing came back and was uploaded"
        )
    }

    func testTheNormalCaseUpdatesTheRowInPlace() {
        let saved = take()
        var withSize = saved
        withSize.fileSize = 5_000
        let after = AppState.applyingStopResult(withSize, alreadySaved: true, to: [saved])
        XCTAssertEqual(after?.count, 1)
        XCTAssertEqual(after?.first?.fileSize, 5_000)
    }

    /// The salvage path never hands anything over, so its take has never been saved. Treating
    /// "not in the list" as "deleted" there would throw away the recovered recording.
    func testATakeThatWasNeverSavedIsStillAdded() {
        let recovered = take()
        let after = AppState.applyingStopResult(recovered, alreadySaved: false, to: [])
        XCTAssertEqual(after?.count, 1)
        XCTAssertEqual(after?.first?.id, recovered.id)
    }
}

/// The screen stream dying mid-capture - a monitor unplugged, screen-recording permission
/// revoked - finalises the file, pays for the merge, and hands the take over. Nothing was
/// subscribed to that hook in any commit, so it went in the bin: the file stayed on disk and
/// the recording simply did not exist for the user.
final class InterruptedTakeTests: XCTestCase {

    private func take() -> Recording {
        Recording(fileURL: URL(fileURLWithPath: "/tmp/interrupted.mp4"), createdAt: Date(), duration: 42)
    }

    func testAnInterruptedTakeIsKept() {
        let interrupted = take()
        let kept = AppState.keepingInterrupted(interrupted, in: [])
        XCTAssertEqual(kept?.list.count, 1, "a recording the stream took down was thrown away")
        XCTAssertEqual(kept?.id, interrupted.id)
    }

    func testAnInterruptionWithNothingToKeepDoesNothing() {
        XCTAssertNil(AppState.keepingInterrupted(nil, in: []))
    }

    /// It goes to the top like any other take, and does not disturb what is already there.
    func testItJoinsTheListWithoutDisplacingAnything() {
        let existing = Recording(fileURL: URL(fileURLWithPath: "/tmp/older.mp4"), createdAt: Date(), duration: 10)
        let kept = AppState.keepingInterrupted(take(), in: [existing])
        XCTAssertEqual(kept?.list.count, 2)
        XCTAssertEqual(kept?.list.last?.id, existing.id)
    }
}
