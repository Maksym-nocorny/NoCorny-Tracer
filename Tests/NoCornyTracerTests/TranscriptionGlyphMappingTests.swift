import XCTest
@testable import NoCornyTracer

/// The state→glyph mapping of the shared transcription axis cluster (Figma 533:1606),
/// extracted as a pure function so both surfaces that render it — the Gallery drawer
/// row and the old Recordings list — provably draw the same thing for the same state.
final class TranscriptionGlyphMappingTests: XCTestCase {

    func testIdleDrawsNothing() {
        XCTAssertEqual(TranscriptionStatusCluster.glyph(for: .idle, fraction: nil), .none)
        // A stray fraction for an idle row must not resurrect the cluster.
        XCTAssertEqual(TranscriptionStatusCluster.glyph(for: .idle, fraction: 0.5), .none)
    }

    func testQueuedIsTheDimSpark() {
        XCTAssertEqual(TranscriptionStatusCluster.glyph(for: .queued, fraction: nil), .queued)
    }

    func testTranscribingWithoutAFractionStaysBare() {
        // Engines that cannot measure themselves never report one; the label still
        // says "working" without inventing a number.
        XCTAssertEqual(
            TranscriptionStatusCluster.glyph(for: .transcribing, fraction: nil),
            .transcribing(percent: nil)
        )
        // Zero is "not reported yet", not "0%".
        XCTAssertEqual(
            TranscriptionStatusCluster.glyph(for: .transcribing, fraction: 0),
            .transcribing(percent: nil)
        )
    }

    func testTranscribingFractionBecomesAPercent() {
        XCTAssertEqual(
            TranscriptionStatusCluster.glyph(for: .transcribing, fraction: 0.34),
            .transcribing(percent: 34)
        )
    }

    func testRunawayFractionClampsToOneHundred() {
        XCTAssertEqual(
            TranscriptionStatusCluster.glyph(for: .transcribing, fraction: 1.7),
            .transcribing(percent: 100)
        )
    }

    func testDoneKeepsItsTick() {
        // The tick is persistent on purpose: this is the second axis, and a row with
        // no transcription mark reads as "never transcribed".
        XCTAssertEqual(TranscriptionStatusCluster.glyph(for: .done, fraction: nil), .done)
    }

    func testFailedIsTheAlert() {
        XCTAssertEqual(TranscriptionStatusCluster.glyph(for: .failed, fraction: nil), .failed)
    }

    // MARK: Mini progress bar fill (round 7)

    /// Same convention as the percent label: nil and 0 are "not measured yet" —
    /// the bar goes indeterminate rather than lying at 0%.
    func testUnmeasuredFractionHasNoFill() {
        XCTAssertNil(TranscriptionStatusCluster.barFillWidth(fraction: nil))
        XCTAssertNil(TranscriptionStatusCluster.barFillWidth(fraction: 0))
    }

    func testFractionScalesAcrossTheBar() {
        XCTAssertEqual(TranscriptionStatusCluster.barFillWidth(fraction: 0.5, barWidth: 64), 32)
        XCTAssertEqual(TranscriptionStatusCluster.barFillWidth(fraction: 1.0, barWidth: 64), 64)
    }

    /// Engines can overshoot 1.0 on the last chunk — the fill must not escape
    /// the track.
    func testRunawayFractionClampsToTheTrack() {
        XCTAssertEqual(TranscriptionStatusCluster.barFillWidth(fraction: 1.7, barWidth: 64), 64)
    }
}
