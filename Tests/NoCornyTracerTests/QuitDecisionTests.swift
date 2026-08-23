import XCTest
import AVFoundation
@testable import NoCornyTracer

/// Both regressions of round ten lived here, and both cost a whole recording.
final class QuitDecisionTests: XCTestCase {

    func testNothingInFlightMeansQuitImmediately() {
        XCTAssertFalse(QuitDecision.isBusy(isRecording: false, isStopping: false, isFinishing: false))
    }

    func testARunningRecordingIsWaitedFor() {
        XCTAssertTrue(QuitDecision.isBusy(isRecording: true, isStopping: false, isFinishing: false))
    }

    /// The window between "the capture stopped" and "the file is finalised". Quitting here
    /// used to terminate on top of a file with no moov atom and no row saved: the recording
    /// was simply gone.
    func testATeardownInFlightIsWaitedFor() {
        XCTAssertTrue(QuitDecision.isBusy(isRecording: true, isStopping: true, isFinishing: false),
                      "quitting mid-teardown would kill the finalisation")
        XCTAssertTrue(QuitDecision.isBusy(isRecording: false, isStopping: true, isFinishing: false))
    }

    /// And the window after it, where the system audio is being mixed in - minutes on a long
    /// meeting, during which the app looks completely idle.
    func testAMergeInFlightIsWaitedFor() {
        XCTAssertTrue(QuitDecision.isBusy(isRecording: false, isStopping: false, isFinishing: true))
    }

    func testQuittingStopsARecordingNobodyElseIsStopping() {
        XCTAssertTrue(QuitDecision.shouldStartAStop(isRecording: true, isStopping: false))
    }

    /// Starting a second stop gets nil back - the first one holds the door - and the handler
    /// read that nil as "there was nothing to do". It has to wait for the first instead.
    func testQuittingDoesNotStartASecondStop() {
        XCTAssertFalse(QuitDecision.shouldStartAStop(isRecording: true, isStopping: true),
                       "a second stop returns nil, and nil read as 'done' is how the file was lost")
        XCTAssertFalse(QuitDecision.shouldStartAStop(isRecording: false, isStopping: true))
    }
}

/// A microphone that vanished takes the format with it.
final class InputFormatTests: XCTestCase {

    func testAnOrdinaryFormatIsUsable() {
        XCTAssertTrue(AudioCaptureManager.isUsableInputFormat(sampleRate: 48_000, channelCount: 2))
        XCTAssertTrue(AudioCaptureManager.isUsableInputFormat(sampleRate: 16_000, channelCount: 1))
    }

    /// What the node reports when the last input device is gone. Installing a tap on it
    /// raises, so the recording dies rather than losing its voice track.
    func testTheFormatOfAVanishedDeviceIsRefused() {
        XCTAssertFalse(AudioCaptureManager.isUsableInputFormat(sampleRate: 0, channelCount: 0))
        XCTAssertFalse(AudioCaptureManager.isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
        XCTAssertFalse(AudioCaptureManager.isUsableInputFormat(sampleRate: 0, channelCount: 2))
    }
}
