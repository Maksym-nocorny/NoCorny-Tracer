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

/// The headcount arithmetic. People count themselves in ("a call with two of us"), and
/// what clustering sees depends on whether the user's own voice is on a different track -
/// so the same answer has to mean two different things.
final class ExpectedSpeakersTests: XCTestCase {

    func testAutoAsksForARange() {
        let r = ExpectedSpeakers.auto.clusterRange(userIsOnAnotherTrack: true)
        XCTAssertEqual(r.min, 1)
        XCTAssertGreaterThan(r.max, r.min)
    }

    /// Two people, system audio on: the mic holds the user, so the track being clustered
    /// contains exactly one voice.
    func testTwoPeopleWithSystemAudioMeansOneFarEndVoice() {
        let r = ExpectedSpeakers.two.clusterRange(userIsOnAnotherTrack: true)
        XCTAssertEqual(r.min, 1)
        XCTAssertEqual(r.max, 1)
    }

    /// Same answer, one microphone: now everyone is in the same audio.
    func testTwoPeopleOnOneTrackMeansTwoVoices() {
        let r = ExpectedSpeakers.two.clusterRange(userIsOnAnotherTrack: false)
        XCTAssertEqual(r.min, 2)
        XCTAssertEqual(r.max, 2)
    }

    func testFivePeopleWithSystemAudioMeansFourFarEndVoices() {
        let r = ExpectedSpeakers.five.clusterRange(userIsOnAnotherTrack: true)
        XCTAssertEqual(r.min, 4)
        XCTAssertEqual(r.max, 4)
    }

    /// "Just me" on a two-track recording leaves nothing on the far end. Asking for zero
    /// clusters is meaningless, so it must still ask for one and come back with no spans.
    func testJustMeNeverAsksForZeroClusters() {
        let r = ExpectedSpeakers.justMe.clusterRange(userIsOnAnotherTrack: true)
        XCTAssertEqual(r.min, 1)
        XCTAssertEqual(r.max, 1)
    }

    /// Past a handful of voices an exact number is a worse guess than a range.
    func testSixOrMoreAsksForARangeRatherThanANumber() {
        let r = ExpectedSpeakers.manyMore.clusterRange(userIsOnAnotherTrack: true)
        XCTAssertLessThan(r.min, r.max)
        XCTAssertGreaterThanOrEqual(r.min, 2)
    }

    func testEveryCaseHasAName() {
        for c in ExpectedSpeakers.allCases {
            XCTAssertFalse(c.displayName.isEmpty, "\(c.rawValue) has no label")
        }
    }
}
