import XCTest
@testable import NoCornyTracer

/// planChunks decides how a long recording is cut. It is pure arithmetic, and the
/// properties below are the ones a caller silently depends on: nothing is dropped,
/// chunks stay inside the transport ceiling, and consecutive chunks overlap.
final class ChunkPlannerTests: XCTestCase {

    private let sr = 16_000

    private func totalSpeech(_ chunks: [PlannedChunk]) -> Int {
        chunks.reduce(0) { $0 + $1.speechSamples }
    }

    func testEmptyInputPlansNothing() {
        XCTAssertTrue(
            ChunkPlanner.planChunks(
                keptRanges: [], targetSamples: sr * 300, maxSamples: sr * 600,
                minSliverSamples: sr, overlapSamples: sr * 2, maxChunks: 10
            ).isEmpty
        )
    }

    func testZeroLengthRangesAreIgnored() {
        let ranges = [SampleRange(start: 0, end: 0), SampleRange(start: 5, end: 5)]
        XCTAssertTrue(
            ChunkPlanner.planChunks(
                keptRanges: ranges, targetSamples: sr * 300, maxSamples: sr * 600,
                minSliverSamples: sr, overlapSamples: 0, maxChunks: 10
            ).isEmpty
        )
    }

    func testShortAudioStaysOneChunk() {
        // 60s of speech against a 300s target — no reason to cut.
        let ranges = [SampleRange(start: 0, end: sr * 60)]
        let chunks = ChunkPlanner.planChunks(
            keptRanges: ranges, targetSamples: sr * 300, maxSamples: sr * 600,
            minSliverSamples: sr, overlapSamples: sr * 2, maxChunks: 10
        )
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].speechSeconds, 60, accuracy: 0.01)
    }

    func testLongAudioIsCutIntoSeveralChunks() {
        // 30 minutes against a 5-minute target.
        let ranges = [SampleRange(start: 0, end: sr * 1800)]
        let chunks = ChunkPlanner.planChunks(
            keptRanges: ranges, targetSamples: sr * 300, maxSamples: sr * 600,
            minSliverSamples: sr, overlapSamples: sr * 2, maxChunks: 20
        )
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
    }

    /// The comment in planChunks is explicit that the count cap must raise the target
    /// rather than drop the tail. Losing the tail means silently shipping a partial
    /// transcript of a long recording.
    func testChunkCapRaisesTheTargetInsteadOfDroppingAudio() {
        let duration = sr * 3600            // an hour
        let ranges = [SampleRange(start: 0, end: duration)]
        let chunks = ChunkPlanner.planChunks(
            keptRanges: ranges, targetSamples: sr * 60, maxSamples: sr * 600,
            minSliverSamples: sr, overlapSamples: 0, maxChunks: 8
        )
        XCTAssertLessThanOrEqual(chunks.count, 8)
        XCTAssertGreaterThanOrEqual(
            totalSpeech(chunks), duration,
            "audio went missing when the chunk cap was hit"
        )
    }

    func testNoChunkExceedsTheMaximum() {
        let ranges = [SampleRange(start: 0, end: sr * 2400)]
        let maxSamples = sr * 600
        let chunks = ChunkPlanner.planChunks(
            keptRanges: ranges, targetSamples: sr * 300, maxSamples: maxSamples,
            minSliverSamples: sr, overlapSamples: sr * 2, maxChunks: 50
        )
        XCTAssertGreaterThan(chunks.count, 1, "40 minutes should not plan as one chunk")
        for c in chunks {
            XCTAssertLessThanOrEqual(
                c.speechSamples, maxSamples,
                "chunk \(c.index) is over the per-request ceiling"
            )
        }
    }

    /// Cues near a cut get transcribed twice on purpose; the merge dedupes them. With
    /// no overlap a word landing on the seam is lost by both sides.
    func testConsecutiveChunksOverlap() {
        let ranges = [SampleRange(start: 0, end: sr * 900)]
        let overlap = sr * 2
        let chunks = ChunkPlanner.planChunks(
            keptRanges: ranges, targetSamples: sr * 300, maxSamples: sr * 600,
            minSliverSamples: sr, overlapSamples: overlap, maxChunks: 20
        )
        guard chunks.count >= 2 else { return XCTFail("expected more than one chunk") }
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            guard let aEnd = a.ranges.last?.end, let bStart = b.ranges.first?.start else {
                return XCTFail("chunk with no ranges")
            }
            XCTAssertLessThan(bStart, aEnd, "chunks \(a.index)/\(b.index) do not overlap")
        }
    }

    func testSpeechSecondsMatchesSampleCount() {
        let chunk = PlannedChunk(index: 0, ranges: [SampleRange(start: 0, end: sr * 42)])
        XCTAssertEqual(chunk.speechSeconds, 42, accuracy: 0.001)
    }

    // MARK: kept-range selection

    func testMostlySilentRecordingKeepsOnlySpeech() {
        // 10s of speech inside a 100s recording: trimming should apply.
        let analysis = SpeechAnalysis(
            totalDuration: 100,
            totalSpeechDuration: 10,
            segments: [SpeechSegment(startSamples: sr * 20, endSamples: sr * 30)],
            silenceCoverage: 0.9,
            shouldSkipTranscription: false
        )
        let kept = ChunkPlanner.chunkKeptRanges(analysis: analysis, totalSamples: sr * 100)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].start, sr * 20)
        XCTAssertEqual(kept[0].end, sr * 30)
    }

    /// A continuously-narrated screen recording — the profile behind both production
    /// failures — must take the whole-timeline branch rather than the trimmed one.
    func testContinuouslyNarratedRecordingKeepsTheWholeTimeline() {
        let analysis = SpeechAnalysis(
            totalDuration: 100,
            totalSpeechDuration: 99,
            segments: [SpeechSegment(startSamples: 0, endSamples: sr * 99)],
            silenceCoverage: 0.01,
            shouldSkipTranscription: false
        )
        let kept = ChunkPlanner.chunkKeptRanges(analysis: analysis, totalSamples: sr * 100)
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept[0].start, 0)
        XCTAssertEqual(kept[0].end, sr * 100)
    }
}
