import XCTest
@testable import NoCornyTracer

/// The overlap rule is the only part of speaker separation that can be wrong without anything
/// crashing: a cue attributed to the wrong person still renders, still syncs, and still reads
/// like a transcript. Everything around it (model download, Core ML, the deadline race) needs
/// real audio and real time; this does not.
final class SpeakerSeparationTests: XCTestCase {

    private func cue(_ start: Double, _ end: Double) -> SrtSegment {
        SrtSegment(start: start, end: end, text: "x")
    }

    private func span(_ id: String, _ startMs: Int64, _ endMs: Int64) -> DiarizedSpan {
        DiarizedSpan(speakerId: id, startMs: startMs, endMs: endMs)
    }

    func testCueTakesTheSpeakerItSharesMostTimeWith() {
        let cues = [cue(0, 10)]
        let spans = [span("a", 0, 3000), span("b", 3000, 10_000)]
        XCTAssertEqual(
            SpeakerSeparation.assign(cues: cues, spans: spans, fallbackToNearest: true)[0],
            "b"
        )
    }

    /// One track: a cue landing in a gap means the span edges are slightly off, not that
    /// nobody said it.
    func testUnmatchedCueFallsBackToTheNearestSpan() {
        let cues = [cue(20, 21)]
        let spans = [span("a", 0, 1000), span("b", 18_000, 19_000)]
        XCTAssertEqual(
            SpeakerSeparation.assign(cues: cues, spans: spans, fallbackToNearest: true)[0],
            "b"
        )
    }

    /// Two tracks: a cue that overlaps nothing on the system track is the user talking, and
    /// handing it to the nearest far-end voice would be exactly the wrong answer.
    func testUnmatchedCueStaysUnassignedWhenTheOtherTrackOwnsIt() {
        let cues = [cue(20, 21)]
        let spans = [span("a", 0, 1000)]
        XCTAssertNil(
            SpeakerSeparation.assign(cues: cues, spans: spans, fallbackToNearest: false)[0]
        )
    }

    func testNoSpansAssignsNothing() {
        XCTAssertTrue(
            SpeakerSeparation.assign(cues: [cue(0, 5)], spans: [], fallbackToNearest: true).isEmpty
        )
    }
}
