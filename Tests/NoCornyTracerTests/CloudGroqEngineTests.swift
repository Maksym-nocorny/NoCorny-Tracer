import XCTest
@testable import NoCornyTracer

/// Tests aimed at the two things on the Groq path that fail silently.
///
/// A chunk's cues arrive in clip-local seconds and have to land on the original
/// recording's timeline; get that wrong and the transcript is well formed, in range, and
/// out of sync. And the seam between two chunks has to drop a re-reading of the same
/// speech without eating a phrase that was genuinely said twice.
final class CloudGroqEngineTests: XCTestCase {

    private func engine() -> CloudGroqEngine {
        // Never reaches the network: every method exercised here is pure.
        CloudGroqEngine(proxyClient: TranscriptionProxyClient(tokenProvider: { nil }))
    }

    private func response(_ cues: [(Double, Double, String)]) -> ProxyTranscription {
        ProxyTranscription(
            text: cues.map(\.2).joined(separator: " "),
            duration: cues.last?.1 ?? 0,
            segments: cues.map { ProxyTranscriptionSegment(start: $0.0, end: $0.1, text: $0.2) },
            latencyMs: 0
        )
    }

    // MARK: Clip-local cues

    func testClampsCuesToTheClipAndDropsEmptyOnes() {
        let cues = CloudGroqEngine.clipLocalSegments(
            response([(0, 3, "first cue"), (3, 7, "   "), (295, 310, "runs past the end")]),
            clipDuration: 300
        )
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[1].end, 300, accuracy: 0.001)
    }

    func testDropsWhisperBoilerplateOverSilence() {
        let cues = CloudGroqEngine.clipLocalSegments(
            response([(0, 3, "real speech here"), (3, 6, "Спасибо за просмотр")]),
            clipDuration: 300
        )
        XCTAssertEqual(cues.map(\.text), ["real speech here"])
    }

    // MARK: Projection onto the original timeline

    func testChunkCuesLandOnTheOriginalTimeline() {
        // Chunk 2 of a long recording: 300s of audio taken from 600s in. Its mapping is
        // clip-local on the stitched side, exactly what buildChunkAudio produces.
        let mapping = [TimestampMapping(
            stitchedStartSamples: 0,
            stitchedEndSamples: 300 * 16000,
            originalStartSamples: 600 * 16000
        )]
        let cues = CloudGroqEngine.clipLocalSegments(
            response([(10, 14, "ten seconds into the clip")]),
            clipDuration: 300
        )

        let (mapped, outOfBounds) = SrtCodec.mapSegments(
            cues, mapping: mapping, speedupFactor: 1.0, originalDuration: 3600
        )
        XCTAssertEqual(outOfBounds, 0)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].start, 610, accuracy: 0.001)
        XCTAssertEqual(mapped[0].end, 614, accuracy: 0.001)
    }

    func testCuesAfterATrimmedSilenceFollowTheirOwnRange() {
        // One chunk stitched from two speech ranges with a minute of silence dropped
        // between them. A cue in the second range must pick up the SECOND offset, not the
        // first plus its clip time.
        let mapping = [
            TimestampMapping(stitchedStartSamples: 0, stitchedEndSamples: 100 * 16000, originalStartSamples: 0),
            TimestampMapping(stitchedStartSamples: 100 * 16000, stitchedEndSamples: 200 * 16000, originalStartSamples: 160 * 16000),
        ]
        let cues = CloudGroqEngine.clipLocalSegments(
            response([(5, 9, "before the gap"), (105, 109, "after the gap")]),
            clipDuration: 200
        )

        let (mapped, outOfBounds) = SrtCodec.mapSegments(
            cues, mapping: mapping, speedupFactor: 1.0, originalDuration: 300
        )
        XCTAssertEqual(outOfBounds, 0)
        XCTAssertEqual(mapped[0].start, 5, accuracy: 0.001)
        XCTAssertEqual(mapped[1].start, 165, accuracy: 0.001)
    }

    // MARK: Seam merge

    func testDropsARereadingOfTheSamePhraseAcrossASeam() {
        // The overlap window, transcribed twice, worded slightly differently the second
        // time. Exact-equality dedupe (what the Gemini path uses) would keep both.
        let first = ChunkResult(index: 0, status: .transcribed, segments: [
            SrtSegment(start: 290, end: 296, text: "so we open the settings panel and check"),
        ])
        let second = ChunkResult(index: 1, status: .transcribed, segments: [
            SrtSegment(start: 295, end: 297, text: "So we open the Settings panel, and check!"),
            SrtSegment(start: 297, end: 302, text: "now the token is finally accepted"),
        ])

        let merged = engine().mergeChunkSegments([first, second])
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[1].text, "now the token is finally accepted")
    }

    func testKeepsAPhraseGenuinelyRepeatedLaterInTheRecording() {
        let first = ChunkResult(index: 0, status: .transcribed, segments: [
            SrtSegment(start: 10, end: 14, text: "and that is the whole trick right there"),
        ])
        let second = ChunkResult(index: 1, status: .transcribed, segments: [
            SrtSegment(start: 900, end: 904, text: "and that is the whole trick right there"),
        ])

        let merged = engine().mergeChunkSegments([first, second])
        XCTAssertEqual(merged.count, 2)
    }

    func testKeepsShortFillersThatOverlapTheSeam() {
        let first = ChunkResult(index: 0, status: .transcribed, segments: [
            SrtSegment(start: 298, end: 300, text: "okay"),
        ])
        let second = ChunkResult(index: 1, status: .transcribed, segments: [
            SrtSegment(start: 299, end: 301, text: "Okay!"),
            SrtSegment(start: 301, end: 305, text: "let us try the other branch"),
        ])

        // "okay" == "okay" once normalized, so the exact test still fires. A one-word cue
        // must never be dropped by the LOOSER tests, which is what the token floors guard.
        XCTAssertFalse(CloudGroqEngine.isSeamDuplicate("okay then", of: "okay"))
        let merged = engine().mergeChunkSegments([first, second])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergedCuesNeverOverlap() {
        let first = ChunkResult(index: 0, status: .transcribed, segments: [
            SrtSegment(start: 0, end: 6, text: "one two three four five"),
        ])
        let second = ChunkResult(index: 1, status: .transcribed, segments: [
            SrtSegment(start: 4, end: 9, text: "something else entirely happened here"),
        ])

        let merged = engine().mergeChunkSegments([first, second])
        XCTAssertEqual(merged.count, 2)
        XCTAssertGreaterThanOrEqual(merged[1].start, merged[0].end)
    }
}
