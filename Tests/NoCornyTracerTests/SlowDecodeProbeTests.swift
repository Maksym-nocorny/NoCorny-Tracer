import XCTest
@testable import NoCornyTracer

/// When an on-device decode is handed to the cloud. The numbers come from Corder's
/// measurements on real Macs; the shape is what these pin: nothing is judged early, and a
/// healthy Mac is never handed off.
final class SlowDecodeProbeTests: XCTestCase {

    func testNothingIsJudgedBeforeTheProbeWindow() {
        // Zero seconds decoded after a minute is a cold GPU compile, not a slow Mac.
        XCTAssertFalse(SlowDecodeProbe.isTooSlow(decodedAudioSec: 0, wallSec: 60))
        XCTAssertFalse(SlowDecodeProbe.isTooSlow(decodedAudioSec: 0, wallSec: 179))
    }

    func testAHealthyMacIsNeverHandedOff() {
        // 2x real time, the low end of a healthy Apple Silicon Mac on the turbo model.
        XCTAssertFalse(SlowDecodeProbe.isTooSlow(decodedAudioSec: 360, wallSec: 180))
        // Exactly at the floor stays on-device: the floor is "slower than", not "at".
        XCTAssertFalse(SlowDecodeProbe.isTooSlow(decodedAudioSec: 90, wallSec: 180))
    }

    func testASlowMacIsHandedOffOnceTheWindowHasPassed() {
        // A fifth of real time: Corder's 8 GB Mac, 83 minutes over 12 minutes of speech.
        XCTAssertTrue(SlowDecodeProbe.isTooSlow(decodedAudioSec: 36, wallSec: 180))
        // Nothing decoded at all after the window is the slowest case there is.
        XCTAssertTrue(SlowDecodeProbe.isTooSlow(decodedAudioSec: 0, wallSec: 180))
    }

    func testTheWindowAndTheFloorAreTheMeasuredOnes() {
        XCTAssertEqual(SlowDecodeProbe.probeAfter, 180)
        XCTAssertEqual(SlowDecodeProbe.realtimeFloor, 0.5)
        XCTAssertLessThan(SlowDecodeProbe.interval, SlowDecodeProbe.probeAfter,
                          "a probe that looks less often than the window never fires on time")
    }

    // MARK: - Silence is not slowness

    private let speech: [(start: Double, end: Double)] = [(0, 60), (360, 400)]

    func testAPositionInsideSpeechIsTakenAsIs() {
        XCTAssertEqual(SlowDecodeProbe.creditedPosition(position: 30, speech: speech, duration: 400), 30)
    }

    /// The case from review: a minute of intro, five minutes of silence, then more talk. At
    /// the three-minute mark the last cue ends near 60 s; without credit for the silence a
    /// healthy Mac reads as 0.3x and is handed off for nothing.
    func testAPositionInSilenceIsCreditedUpToTheNextSpeech() {
        XCTAssertEqual(SlowDecodeProbe.creditedPosition(position: 60, speech: speech, duration: 400), 360)
        XCTAssertFalse(SlowDecodeProbe.isTooSlow(decodedAudioSec: 360, wallSec: 180))
    }

    func testSilenceAfterTheLastSpeechCreditsToTheEnd() {
        XCTAssertEqual(SlowDecodeProbe.creditedPosition(position: 400, speech: speech, duration: 420), 420)
    }

    func testNoSpeechAtAllCreditsToTheEnd() {
        XCTAssertEqual(SlowDecodeProbe.creditedPosition(position: 0, speech: [], duration: 100), 100)
    }

    /// The bar's fraction and the probe's rate are the same number seen twice; a bar that
    /// could not say where it was would silently disable the probe.
    func testTheMonotonicFractionIsReadableForTheProbe() {
        let m = MonotonicProgress()
        XCTAssertEqual(m.current, 0)
        _ = m.advance(to: 0.4)
        _ = m.advance(to: 0.2)   // an out-of-order window must not move it back
        XCTAssertEqual(m.current, 0.4)
    }
}
