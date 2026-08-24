import XCTest
@testable import NoCornyTracer

/// The transcription axis's launch reconcile, mirror of the upload one: `.queued` and
/// `.transcribing` found on disk at load time are claims by a run that died with the
/// process - no task survives it - and left as-is the row would spin forever on work
/// nobody is doing, with no path forward (retry only offers itself to `.failed`).
final class TranscriptionStrandedAtLaunchTests: XCTestCase {

    func testOnlyActiveStatusesCountAsStranded() {
        XCTAssertTrue(AppState.isTranscriptionStrandedAtLaunch(.queued))
        XCTAssertTrue(AppState.isTranscriptionStrandedAtLaunch(.transcribing))
        XCTAssertFalse(AppState.isTranscriptionStrandedAtLaunch(.done))
        XCTAssertFalse(AppState.isTranscriptionStrandedAtLaunch(.failed),
                       "re-flagging an already-failed row would overwrite its real error message")
        XCTAssertFalse(AppState.isTranscriptionStrandedAtLaunch(.idle))
        XCTAssertFalse(AppState.isTranscriptionStrandedAtLaunch(nil))
    }

    /// The whole path, through a real load: a stranded row comes back `.failed` with the
    /// message that offers a retry, and settled rows come back untouched.
    func testAStrandedRowLoadsAsFailedWithTheRetryMessage() throws {
        let sandbox = SandboxDefaults.make()
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        var queued = Recording(fileURL: URL(fileURLWithPath: "/tmp/stranded-queued.mp4"),
                               uploadStatus: .uploaded)
        queued.transcriptionStatus = .queued
        var midRun = Recording(fileURL: URL(fileURLWithPath: "/tmp/stranded-midrun.mp4"),
                               uploadStatus: .uploaded)
        midRun.transcriptionStatus = .transcribing
        var finished = Recording(fileURL: URL(fileURLWithPath: "/tmp/stranded-finished.mp4"),
                                 uploadStatus: .uploaded)
        finished.transcriptionStatus = .done
        sandbox.set(try JSONEncoder().encode([queued, midRun, finished]), forKey: "savedRecordings")

        let state = AppState(defaults: sandbox, connectsToTracer: false)

        for stranded in [queued, midRun] {
            let row = state.recordings.first { $0.id == stranded.id }
            XCTAssertEqual(row?.transcriptionStatus, .failed,
                           "a run nobody is doing still claims the recording")
            XCTAssertEqual(row?.transcriptionError, AppState.interruptedTranscriptionMessage)
        }
        let untouched = state.recordings.first { $0.id == finished.id }
        XCTAssertEqual(untouched?.transcriptionStatus, .done,
                       "the reconcile flagged a run that had finished cleanly")
        XCTAssertNil(untouched?.transcriptionError)
    }

    /// A row with no status at all predates the field and was not stranded by anything -
    /// deriving `.failed` for it would put a red retry icon on years of old recordings.
    func testARowWithoutAStatusIsLeftAlone() throws {
        let sandbox = SandboxDefaults.make()
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        let legacy = Recording(fileURL: URL(fileURLWithPath: "/tmp/stranded-legacy.mp4"),
                               uploadStatus: .uploaded)
        sandbox.set(try JSONEncoder().encode([legacy]), forKey: "savedRecordings")

        let state = AppState(defaults: sandbox, connectsToTracer: false)

        XCTAssertNil(state.recordings.first { $0.id == legacy.id }?.transcriptionStatus)
    }
}
