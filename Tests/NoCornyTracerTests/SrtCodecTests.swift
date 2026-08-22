import XCTest
@testable import NoCornyTracer

/// Tests aimed at the failure modes this code exists to absorb: the model returning
/// SRT that is nearly-but-not-quite well formed, and cue times that have to survive a
/// round trip through a trimmed timeline.
final class SrtCodecTests: XCTestCase {

    // MARK: parseAndRepairSrt

    func testParsesWellFormedSrt() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        Hello there

        2
        00:00:02,000 --> 00:00:04,500
        Second cue
        """
        let segs = SrtCodec.parseAndRepairSrt(srt)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "Hello there")
        XCTAssertEqual(segs[1].start, 2.0, accuracy: 0.001)
        XCTAssertEqual(segs[1].end, 4.5, accuracy: 0.001)
    }

    func testStripsMarkdownFence() {
        let srt = """
        ```srt
        1
        00:00:00,000 --> 00:00:01,000
        Fenced
        ```
        """
        XCTAssertEqual(SrtCodec.parseAndRepairSrt(srt).first?.text, "Fenced")
    }

    /// Gemini in JSON mode drops the blank line between entries, most often on Cyrillic
    /// content. Under a standard parser the whole file collapses into a single cue.
    func testRecoversMissingBlankLineBetweenEntries() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        Привіт
        2
        00:00:02,000 --> 00:00:04,000
        Як справи
        """
        let segs = SrtCodec.parseAndRepairSrt(srt)
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "Привіт")
        XCTAssertEqual(segs[1].text, "Як справи")
    }

    func testEmptyAndNoSpeechYieldNothing() {
        XCTAssertTrue(SrtCodec.parseAndRepairSrt("").isEmpty)
        XCTAssertTrue(SrtCodec.parseAndRepairSrt("   \n  ").isEmpty)
        XCTAssertTrue(SrtCodec.parseAndRepairSrt("NO_SPEECH").isEmpty)
    }

    /// No real newlines at all — the regex sweep is the only thing that can save this.
    func testRecoversFromInlineTimestamps() {
        let raw = "00:00:00,000 --> 00:00:02,000 First cue 00:00:02,000 --> 00:00:04,000 Second cue"
        let segs = SrtCodec.parseAndRepairSrt(raw)
        XCTAssertGreaterThanOrEqual(segs.count, 2)
        XCTAssertTrue(segs[0].text.contains("First"))
    }

    // MARK: serialize / round trip

    func testSerializeRoundTrip() {
        let original = [
            SrtSegment(start: 0, end: 1.5, text: "One"),
            SrtSegment(start: 1.5, end: 3.25, text: "Two"),
        ]
        guard let srt = SrtCodec.serializeSrt(original) else {
            return XCTFail("serializeSrt returned nil for a non-empty input")
        }
        let reparsed = SrtCodec.parseAndRepairSrt(srt)
        XCTAssertEqual(reparsed.count, 2)
        XCTAssertEqual(reparsed[0].end, 1.5, accuracy: 0.001)
        XCTAssertEqual(reparsed[1].end, 3.25, accuracy: 0.001)
        XCTAssertEqual(reparsed[1].text, "Two")
    }

    func testTimestampFormatting() {
        XCTAssertEqual(SrtCodec.formatSrtTimestamp(0), "00:00:00,000")
        XCTAssertEqual(SrtCodec.formatSrtTimestamp(3661.5), "01:01:01,500")
    }

    func testTimestampParsingAcceptsBothSeparators() {
        XCTAssertEqual(SrtCodec.parseSrtTimestamp("00:00:02,500"), 2.5, accuracy: 0.001)
        XCTAssertEqual(SrtCodec.parseSrtTimestamp("00:00:02.500"), 2.5, accuracy: 0.001)
        XCTAssertEqual(SrtCodec.parseSrtTimestamp("01:02:03,000"), 3723.0, accuracy: 0.001)
    }

    func testLastSrtEndSeconds() {
        let srt = """
        1
        00:00:00,000 --> 00:00:02,000
        A

        2
        00:00:10,000 --> 00:00:12,750
        B
        """
        XCTAssertEqual(SrtCodec.lastSrtEndSeconds(srt) ?? -1, 12.75, accuracy: 0.001)
    }

    // MARK: restoreSrtTimestamps

    /// The whole point of trimming: cues are produced against audio with the silence
    /// removed, and have to land back where the speech actually was. Here 0-2s of
    /// stitched audio came from 10-12s of the recording.
    func testRestoreMapsCuesBackOntoTheOriginalTimeline() {
        let mapping = [
            TimestampMapping(
                stitchedStartSamples: 0,
                stitchedEndSamples: 32_000,        // 2s at 16 kHz
                originalStartSamples: 160_000      // 10s in
            )
        ]
        let stitched = """
        1
        00:00:00,000 --> 00:00:02,000
        Spoken here
        """
        let restored = SrtCodec.restoreSrtTimestamps(
            stitched, mapping: mapping, speedupFactor: 1.0, originalDuration: 60
        )
        let segs = SrtCodec.parseAndRepairSrt(restored ?? "")
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].start, 10.0, accuracy: 0.05)
        XCTAssertEqual(segs[0].end, 12.0, accuracy: 0.05)
    }

    func testRestoreNeverExceedsTheRecordingLength() {
        let mapping = [
            TimestampMapping(
                stitchedStartSamples: 0,
                stitchedEndSamples: 160_000,
                originalStartSamples: 0
            )
        ]
        // A cue claiming to end past the end of the recording must be clamped, not shipped.
        let stitched = """
        1
        00:00:00,000 --> 00:01:00,000
        Overlong
        """
        let restored = SrtCodec.restoreSrtTimestamps(
            stitched, mapping: mapping, speedupFactor: 1.0, originalDuration: 10
        )
        let segs = SrtCodec.parseAndRepairSrt(restored ?? "")
        for seg in segs {
            XCTAssertLessThanOrEqual(seg.end, 10.001, "cue ends after the recording does")
        }
    }

    // MARK: speaker labels

    /// The `[Name] ` prefix is a contract with the web player's
    /// `/^\[([^\]]{1,40})\]\s+/`. Written only for cues that actually have a speaker: an
    /// unlabelled transcript must serialize byte-for-byte as it did before diarization existed.
    func testSpeakerPrefixOnlyWhenLabelled() {
        let srt = SrtCodec.serializeSrt([
            SrtSegment(start: 0, end: 1.5, text: "Hello there", speaker: "Speaker 1"),
            SrtSegment(start: 1.5, end: 3, text: "No label here"),
        ])
        XCTAssertNotNil(srt)
        XCTAssertTrue(srt!.contains("[Speaker 1] Hello there"))
        XCTAssertTrue(srt!.contains("\nNo label here"))
        XCTAssertFalse(srt!.contains("[] No label here"))
    }

    /// The web strips the prefix, we do not: a round trip through our own parser has to leave
    /// it sitting in the cue text, or re-serializing a labelled transcript would lose the
    /// speakers on the way through.
    func testSpeakerPrefixSurvivesRoundTrip() {
        let srt = SrtCodec.serializeSrt([
            SrtSegment(start: 0, end: 2, text: "First line", speaker: "Speaker 1"),
            SrtSegment(start: 2, end: 4, text: "Second line", speaker: "Speaker 2"),
        ])
        let segs = SrtCodec.parseAndRepairSrt(srt ?? "")
        XCTAssertEqual(segs.count, 2)
        XCTAssertEqual(segs[0].text, "[Speaker 1] First line")
        XCTAssertEqual(segs[1].text, "[Speaker 2] Second line")
        XCTAssertNil(segs[0].speaker, "parsing does not restore the field, the prefix IS the record")
        XCTAssertEqual(SrtCodec.serializeSrt(segs), srt)
    }

    // MARK: dedupe helper

    func testNormalizedForDedupeIgnoresCaseAndPunctuation() {
        XCTAssertEqual(
            SrtCodec.normalizedForDedupe("Hello, world!"),
            SrtCodec.normalizedForDedupe("hello world")
        )
    }
}
