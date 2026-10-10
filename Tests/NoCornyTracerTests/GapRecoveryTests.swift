import XCTest
@testable import NoCornyTracer

/// Which stretches of speech get decoded a second time. The incident: on a 289 s take the
/// turbo model came back without 227-257 s in one run and without 182-212 s in another, a
/// whole Whisper window each, nothing hallucinated and nothing logged.
final class GapRecoveryTests: XCTestCase {

    private func spans(
        speech: [(Double, Double)], cues: [(Double, Double)], duration: Double = 289
    ) -> [GapRecovery.Span] {
        GapRecovery.uncoveredSpans(
            speech: speech.map { (start: $0.0, end: $0.1) },
            cues: cues.map { (start: $0.0, end: $0.1) },
            duration: duration
        )
    }

    func testAFullyCoveredRecordingNeedsNothing() {
        XCTAssertEqual(spans(speech: [(0, 100)], cues: [(0, 50), (50, 100)]), [])
    }

    /// The 227-257 case: speech throughout, cues on both sides, a window-sized hole between.
    /// The clip is the hole exactly: cues on both sides leave no room for padding.
    func testAMissingWindowIsDecodedAgain() {
        let got = spans(speech: [(0, 289)], cues: [(0, 227), (257, 289)])
        XCTAssertEqual(got, [GapRecovery.Span(start: 227, end: 257)])
    }

    /// A hole that lands between two VAD segments counts only the voiced part of it.
    func testOnlyVoicedAudioInsideTheHoleCounts() {
        let got = spans(speech: [(0, 100), (120, 150), (170, 200)], cues: [(0, 100), (170, 200)])
        XCTAssertEqual(got, [GapRecovery.Span(start: 119.5, end: 150.5)])
    }

    /// The review's reproduction: padding into the previous cue re-transcribes its last word,
    /// and that word landed as a subtitle of its own. The clip may not cross a cue edge.
    func testPaddingNeverEntersANeighbouringCue() {
        let got = spans(speech: [(0, 100)], cues: [(0, 50), (70, 100)])
        XCTAssertEqual(got, [GapRecovery.Span(start: 50, end: 70)])
        // Where no cue is adjacent, the pad still applies.
        let open = spans(speech: [(0, 100)], cues: [(0, 50), (80, 100)], duration: 100)
        XCTAssertEqual(open, [GapRecovery.Span(start: 50, end: 80)])
        let island = spans(speech: [(60, 70)], cues: [(0, 50), (80, 100)], duration: 100)
        XCTAssertEqual(island, [GapRecovery.Span(start: 59.5, end: 70.5)])
    }

    func testAnEchoOfTheNeighbouringCueIsRecognised() {
        XCTAssertTrue(GapRecovery.isEdgeEcho("application", previous: "They work in the application.", next: nil))
        XCTAssertTrue(GapRecovery.isEdgeEcho("Field.", previous: "Type it into the search field.", next: nil))
        XCTAssertTrue(GapRecovery.isEdgeEcho("the search", previous: nil, next: "The search field is empty."))
        XCTAssertFalse(GapRecovery.isEdgeEcho("application", previous: "Open the settings.", next: "Then save."))
        // Three words and more are speech, whatever the neighbours say.
        XCTAssertFalse(GapRecovery.isEdgeEcho("in the application", previous: "They work in the application.", next: nil))
    }

    /// The review's second reproduction: keyboard clatter came back as "Thank you." and as
    /// "you", once over twelve seconds and once over one. Fillers over noise, not a lost
    /// window; a lost window is tens of words.
    func testFillersOverNoiseAreNotRecoveredSpeech() {
        XCTAssertFalse(GapRecovery.isPlausibleRecovery(text: "Thank you."))
        XCTAssertFalse(GapRecovery.isPlausibleRecovery(text: "you"))
        XCTAssertFalse(GapRecovery.isPlausibleRecovery(text: "ок давай"))
        XCTAssertFalse(GapRecovery.isPlausibleRecovery(text: ""))
        XCTAssertTrue(GapRecovery.isPlausibleRecovery(text: "ну да, конечно"))
        XCTAssertTrue(GapRecovery.isPlausibleRecovery(text: "As you can see, the file is saved."))
    }

    func testAShortUncoveredStretchIsLeftAlone() {
        // A second and a half of voice with no cue: a "yes", not a lost window.
        XCTAssertEqual(spans(speech: [(0, 100)], cues: [(0, 50), (51.5, 100)]), [])
    }

    /// Two holes with a short cue between them stay two clips: one clip across the cue would
    /// decode its words a second time.
    func testHolesOnEitherSideOfACueStayApart() {
        let got = spans(speech: [(0, 100)], cues: [(0, 20), (24, 24.5), (29, 100)])
        XCTAssertEqual(got, [GapRecovery.Span(start: 20, end: 24), GapRecovery.Span(start: 24.5, end: 29)])
    }

    /// Two holes separated by a VAD pause and nothing else do merge.
    func testHolesWithOnlySilenceBetweenThemMerge() {
        let got = spans(speech: [(20, 24), (24.6, 29)], cues: [(0, 20), (29, 100)])
        XCTAssertEqual(got, [GapRecovery.Span(start: 20, end: 29)])
    }

    func testPaddingNeverLeavesTheRecordingNorEntersTheCue() {
        let got = spans(speech: [(0, 10), (280, 289)], cues: [(10, 280)])
        XCTAssertEqual(got, [GapRecovery.Span(start: 0, end: 10), GapRecovery.Span(start: 280, end: 289)])
    }

    /// Dozens of holes mean the decode missed the recording, not a window: a second pass would
    /// only miss it again, slower, so nothing is re-decoded.
    func testATranscriptFullOfHolesIsNotReDecoded() {
        var speech: [(Double, Double)] = []
        for i in 0..<50 { speech.append((Double(i) * 10, Double(i) * 10 + 5)) }
        XCTAssertEqual(spans(speech: speech, cues: [], duration: 500), [])
    }

    func testThresholdsAreTheMeasuredOnes() {
        XCTAssertEqual(GapRecovery.minVoicedSec, 2.0)
        XCTAssertEqual(GapRecovery.padSec, 0.5)
        XCTAssertEqual(GapRecovery.maxSpans, 40)
    }
}
