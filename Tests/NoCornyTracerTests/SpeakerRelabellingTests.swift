import XCTest
@testable import NoCornyTracer

/// Re-running separation reads the transcript it wrote last time, and the speaker labels live
/// inside the cue text as a "[Speaker 1] " prefix. Feeding that text back in without stripping
/// it produces "[Speaker 2] [Speaker 1] hello" - a transcript that still parses, still syncs,
/// and gets a little worse every time somebody tries to fix it.
final class SpeakerRelabellingTests: XCTestCase {

    private func cue(_ text: String, speaker: String? = nil) -> SrtSegment {
        SrtSegment(start: 0, end: 1, text: text, speaker: speaker)
    }

    private func stripped(_ text: String) -> String {
        AppState.strippingSpeakerPrefixes(from: [cue(text)])[0].text
    }

    func testTheLabelPrefixComesOff() {
        XCTAssertEqual(stripped("[Speaker 1] hello there"), "hello there")
    }

    func testStackedPrefixesFromAnEarlierRunAllComeOff() {
        XCTAssertEqual(stripped("[Speaker 3] [Speaker 2] [Speaker 1] hello"), "hello")
    }

    func testAnUnlabelledCueIsUntouched() {
        XCTAssertEqual(stripped("hello there"), "hello there")
    }

    /// The prefix is only a prefix at the front of the line. Brackets mid-sentence are
    /// something a person said, or a transcriber's aside, and both stay.
    func testBracketsLaterInTheLineStay() {
        XCTAssertEqual(stripped("hello [Speaker 1] there"), "hello [Speaker 1] there")
    }

    /// The web player lifts the name with `/^\[([^\]]{1,40})\]\s+/`, so anything longer than
    /// forty characters was never a label to begin with.
    func testAnOverlongBracketIsNotALabel() {
        let long = "[" + String(repeating: "x", count: 41) + "] hello"
        XCTAssertEqual(stripped(long), long)
    }

    /// A cue that is nothing but a label would be stripped to an empty line, and an SRT entry
    /// with no text is worse than one with a stale prefix.
    func testACueThatIsOnlyALabelKeepsItsText() {
        XCTAssertEqual(stripped("[Speaker 1] "), "[Speaker 1] ")
    }

    func testTimingsSurviveAndTheOldSpeakerIsDropped() {
        let cues = [SrtSegment(start: 4.5, end: 9.25, text: "[Speaker 2] hi", speaker: "Speaker 2")]
        let result = AppState.strippingSpeakerPrefixes(from: cues)
        XCTAssertEqual(result[0].start, 4.5)
        XCTAssertEqual(result[0].end, 9.25)
        XCTAssertEqual(result[0].text, "hi")
        XCTAssertNil(result[0].speaker)
    }

    /// End to end through the codec, because that is the shape a re-run actually sees: parse
    /// the stored SRT, strip, re-label, serialize - and get one prefix, not two.
    func testARoundTripThroughTheCodecDoesNotStackPrefixes() throws {
        let original = """
        1
        00:00:00,000 --> 00:00:02,000
        [Speaker 1] first line

        2
        00:00:02,000 --> 00:00:04,000
        [Speaker 2] second line
        """

        let stripped = AppState.strippingSpeakerPrefixes(from: SrtCodec.parseAndRepairSrt(original))
        let relabelled = stripped.enumerated().map { index, cue in
            SrtSegment(start: cue.start, end: cue.end, text: cue.text, speaker: "Speaker \(index + 1)")
        }
        let rebuilt = try XCTUnwrap(SrtCodec.serializeSrt(relabelled))

        XCTAssertTrue(rebuilt.contains("[Speaker 1] first line"))
        XCTAssertTrue(rebuilt.contains("[Speaker 2] second line"))
        XCTAssertFalse(rebuilt.contains("[Speaker 1] [Speaker"))
    }
}
