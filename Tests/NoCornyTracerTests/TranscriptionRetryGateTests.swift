import XCTest
@testable import NoCornyTracer

/// The synchronous gate under `retryTranscription`. The `.queued` status write lands
/// through an async hop, so between click and landing the row still reads `.failed` —
/// and two quick clicks used to start two parallel AI pipelines over the same file.
/// The claim is taken synchronously before the retry's Task starts, so the second click
/// is a no-op by construction.
final class TranscriptionRetryGateTests: XCTestCase {

    func testTheSecondClaimOnTheSameRecordingIsRefused() {
        let state = AppState(defaults: SandboxDefaults.make(), connectsToTracer: false)
        let id = UUID()

        XCTAssertTrue(state.claimTranscriptionRetry(id))
        XCTAssertFalse(state.claimTranscriptionRetry(id),
                       "the double click started a second pipeline over the same file")
        XCTAssertTrue(state.retryingTranscriptions.contains(id),
                      "the row cluster reads this set to swap the retry button for a spinner")
    }

    func testDifferentRecordingsDoNotShareTheSlot() {
        let state = AppState(defaults: SandboxDefaults.make(), connectsToTracer: false)

        XCTAssertTrue(state.claimTranscriptionRetry(UUID()))
        XCTAssertTrue(state.claimTranscriptionRetry(UUID()),
                      "a retry on one recording blocked retries on every other")
    }

    func testReleaseFreesTheSlotForTheNextRetry() {
        let state = AppState(defaults: SandboxDefaults.make(), connectsToTracer: false)
        let id = UUID()

        XCTAssertTrue(state.claimTranscriptionRetry(id))
        state.releaseTranscriptionRetry(id)
        XCTAssertFalse(state.retryingTranscriptions.contains(id))
        XCTAssertTrue(state.claimTranscriptionRetry(id),
                      "a finished retry left its claim behind and disabled the button for good")
    }
}
