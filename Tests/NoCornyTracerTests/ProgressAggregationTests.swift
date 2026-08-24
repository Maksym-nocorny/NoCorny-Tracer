import XCTest
@testable import NoCornyTracer

/// A stand-in engine that reports a scripted stream of progress before answering, so the
/// progress plumbing can be exercised without a network, a model, or a real recording.
private final class ReportingEngine: TranscriptionEngine, @unchecked Sendable {
    let kind: TranscriptionEngineKind
    let isReady = true
    private let answer: EngineResult
    private let reports: [TranscriptionProgress]

    init(_ kind: TranscriptionEngineKind, answer: EngineResult, reports: [TranscriptionProgress] = []) {
        self.kind = kind
        self.answer = answer
        self.reports = reports
    }

    func transcribe(
        videoURL: URL,
        multiSpeaker: Bool,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async -> EngineResult {
        for report in reports { progress(report) }
        return answer
    }
}

/// Collects progress reports across threads, so a test can read the sequence back.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TranscriptionProgress] = []

    func append(_ value: TranscriptionProgress) {
        lock.lock(); stored.append(value); lock.unlock()
    }

    var values: [TranscriptionProgress] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// The arithmetic under the progress channel. Each rule here exists because its absence
/// has a specific, visible failure: a bar that moves backwards reads as the run breaking,
/// 0/0 chunks divides to NaN, and a fallback that keeps the refused engine's number tells
/// the user the new engine is nearly done before it has started.
final class ProgressAggregationTests: XCTestCase {

    // MARK: - Monotonic local fraction

    /// Whisper's segment discovery reports whatever window just finished decoding, and
    /// windows land out of order - the raw stream genuinely goes backwards.
    func testTheFractionNeverMovesBackwards() {
        let gate = MonotonicProgress()
        XCTAssertEqual(gate.advance(to: 0.2), 0.2)
        XCTAssertNil(gate.advance(to: 0.1), "an out-of-order window dragged the bar backwards")
        XCTAssertNil(gate.advance(to: 0.2), "a repeat is not progress worth reporting")
        XCTAssertEqual(gate.advance(to: 0.7), 0.7)
        XCTAssertEqual(gate.advance(to: 1.0), 1.0)
    }

    /// Whisper snaps a window's last cue to the window edge, so the raw share can exceed
    /// the recording - a bar past 100% that then snaps back reads as the run breaking.
    func testTheFractionIsClampedToOne() {
        let gate = MonotonicProgress()
        XCTAssertEqual(gate.advance(to: 1.7), 1.0)
        XCTAssertNil(gate.advance(to: 2.0), "a clamped ceiling was 'advanced' past")
    }

    func testANegativeFractionIsNotProgress() {
        let gate = MonotonicProgress()
        XCTAssertNil(gate.advance(to: -0.5))
        XCTAssertEqual(gate.advance(to: 0.3), 0.3, "the rejected negative poisoned the gate")
    }

    // MARK: - Chunk arithmetic

    func testChunkProgressDividesToAFraction() {
        let progress = TranscriptionProgress.chunks(completed: 3, total: 12)
        XCTAssertEqual(progress.completedChunks, 3)
        XCTAssertEqual(progress.totalChunks, 12)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
    }

    /// 0 of 0 is the on-device engine's "share of time, not of chunks" signal - it must
    /// report fraction 0, never NaN.
    func testZeroChunksReportsZeroNotNaN() {
        let progress = TranscriptionProgress.chunks(completed: 0, total: 0)
        XCTAssertEqual(progress.fraction, 0)
        XCTAssertFalse(progress.fraction.isNaN)
    }

    func testChunkProgressCannotOvershoot() {
        XCTAssertEqual(TranscriptionProgress.chunks(completed: 5, total: 3).fraction, 1.0)
    }

    // MARK: - The fallback walk resets the bar

    /// When a refused engine hands the run to another, the new engine starts from nothing
    /// and the bar has to say so - keeping the refused engine's 50% would show the local
    /// engine "nearly done" minutes before it is.
    func testTheFallbackWalkResetsProgressBetweenEngines() async {
        let refusing = ReportingEngine(
            .cloudGemini,
            answer: EngineResult(srt: nil, name: nil, usage: .zero, model: "gemini",
                                 latencyMs: 0, attempts: 1, success: false,
                                 errorCode: "premium_required", fatal: true),
            reports: [.chunks(completed: 2, total: 4)]
        )
        // Answers with a title too, so the orchestrator's separate naming call never runs
        // and the test stays offline.
        let answering = ReportingEngine(
            .localWhisper,
            answer: EngineResult(srt: "1\n00:00:00,000 --> 00:00:02,000\nhello\n",
                                 name: "A real title", usage: .zero, model: "local",
                                 latencyMs: 0, attempts: 1, success: true),
            reports: [TranscriptionProgress(completedChunks: 0, totalChunks: 0, fraction: 0.3)]
        )
        let service = AINamingService(
            engines: [refusing, answering], preferring: .cloudGemini,
            namingService: NamingService(proxyClient: GeminiProxyClient(tokenProvider: { nil }))
        )

        let log = ProgressLog()
        let result = await service.generateSubtitlesAndName(
            for: URL(fileURLWithPath: "/dev/null/never-read.mov"),
            progress: { log.append($0) }
        )

        XCTAssertNotNil(result.srt, "the walk itself broke - nothing below can mean anything")
        let reports = log.values
        XCTAssertEqual(reports, [
            .chunks(completed: 2, total: 4),
            TranscriptionProgress(completedChunks: 0, totalChunks: 0, fraction: 0),
            TranscriptionProgress(completedChunks: 0, totalChunks: 0, fraction: 0.3),
        ], "the hand-over between engines did not reset the bar")
    }
}
