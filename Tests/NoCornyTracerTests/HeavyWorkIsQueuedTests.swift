import XCTest
@testable import NoCornyTracer

/// Proving the queue works proves nothing about whether anything is queued on it. Removing
/// the two `enqueue` calls that wire local transcription and diarization to their gates left
/// the whole suite green - the same shape of hole as a contract whose two ends are pinned and
/// whose middle is not.
///
/// So these occupy the real gate and check the real entry point waits its turn.
final class HeavyWorkIsQueuedTests: XCTestCase {

    /// Holds a gate until released, and says when it got in.
    private actor Holder {
        private var release: CheckedContinuation<Void, Never>?
        private var started: CheckedContinuation<Void, Never>?
        private var hasStarted = false

        func occupy() async {
            hasStarted = true
            started?.resume(); started = nil
            await withCheckedContinuation { self.release = $0 }
        }

        func waitUntilInside() async {
            if hasStarted { return }
            await withCheckedContinuation { self.started = $0 }
        }

        func letGo() { release?.resume(); release = nil }
    }

    func testLocalTranscriptionWaitsItsTurn() async {
        let holder = Holder()
        Task { await LocalWhisperEngine.runs.enqueue { await holder.occupy() } }
        await holder.waitUntilInside()

        let finished = Finished()
        let engine = LocalWhisperEngine()
        Task {
            // Returns almost immediately once it is allowed in - there is no model here, and
            // that is fine: what is being measured is whether it gets in at all.
            _ = await engine.transcribe(videoURL: URL(fileURLWithPath: "/dev/null/none.mov"), multiSpeaker: false)
            await finished.mark()
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        let ranWhileBlocked = await finished.value
        await holder.letGo()

        XCTAssertFalse(ranWhileBlocked, "transcription ran while the queue was occupied - it is not wired to the gate")

        for _ in 0..<40 where !(await finished.value) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let ranAfterRelease = await finished.value
        XCTAssertTrue(ranAfterRelease, "transcription never ran after the queue was released")
    }

    /// Cancelled rather than completed on purpose: letting the real diarizer through would
    /// download 130 MB of Core ML models. Being cancellable at all is proof enough that it
    /// went through the queue - `runDiarization` checks for it on its first line, and that
    /// line only ever runs when the queue lets it in.
    func testDiarizationWaitsItsTurnAndCanBeGivenUpOnWhileWaiting() async {
        let diarizer = SpeakerDiarizer.shared
        let holder = Holder()
        Task { await diarizer.runs.enqueue { await holder.occupy() } }
        await holder.waitUntilInside()

        let outcome = Outcome()
        let attempt = Task {
            do {
                _ = try await diarizer.diarize(
                    audioURL: URL(fileURLWithPath: "/dev/null/none.m4a"), minSpeakers: 1, maxSpeakers: 3
                )
                await outcome.record(cancelled: false)
            } catch is CancellationError {
                await outcome.record(cancelled: true)
            } catch {
                await outcome.record(cancelled: false)
            }
        }

        try? await Task.sleep(nanoseconds: 250_000_000)
        let settledWhileBlocked = await outcome.settled
        XCTAssertFalse(settledWhileBlocked, "diarization ran while the queue was occupied - it is not wired to the gate")

        attempt.cancel()
        await holder.letGo()
        for _ in 0..<40 where !(await outcome.settled) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let settled = await outcome.settled
        let cancelled = await outcome.wasCancelled
        XCTAssertTrue(settled, "diarization never got its turn after the queue was released")
        XCTAssertTrue(cancelled, "a diarization nobody was waiting for still went ahead and did the work")
    }

    /// The property the diarizer's first line depends on: work that reaches the front of the
    /// queue after its caller gave up can tell. Without it, an abandoned run does its minutes
    /// of Core ML anyway and holds the queue against the next recording.
    func testWorkCanTellThatItsCallerGaveUp() async {
        let gate = SerialGate()
        let holder = Holder()
        Task { await gate.enqueue { await holder.occupy() } }
        await holder.waitUntilInside()

        let seen = Outcome()
        let queued = Task {
            await gate.enqueue {
                await seen.record(cancelled: Task.isCancelled)
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        queued.cancel()
        await holder.letGo()
        for _ in 0..<40 where !(await seen.settled) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let settled = await seen.settled
        let sawCancellation = await seen.wasCancelled
        XCTAssertTrue(settled, "the queue swallowed the work entirely")
        XCTAssertTrue(sawCancellation, "queued work cannot tell its caller gave up, so it cannot step aside")
    }
}

private actor Outcome {
    private(set) var settled = false
    private(set) var wasCancelled = false
    func record(cancelled: Bool) { settled = true; wasCancelled = cancelled }
}

private actor Finished {
    private(set) var value = false
    func mark() { value = true }
}
