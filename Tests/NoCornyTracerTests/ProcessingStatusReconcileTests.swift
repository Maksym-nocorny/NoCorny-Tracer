import XCTest
@testable import NoCornyTracer

/// The server's `processingStatus` against local knowledge. The strings are the contract
/// the app itself PATCHes up ("uploading" / "processing" / "upload_failed" / "ready"), and
/// the one rule that outranks all of them: a live local run is never clobbered, because
/// this sync fires right after a recording is processed and the server row can lag a beat
/// behind the PATCH carrying the very result being synced.
///
/// "ready" additionally has to prove itself: it only becomes a local `.done` when a
/// transcript actually exists (server SRT or the local store). A "ready" stamped over a
/// failed run used to repaint a local `.failed` as a green tick over nothing, taking the
/// Retry button (which lives only on `.failed`) with it.
final class ProcessingStatusReconcileTests: XCTestCase {

    private func local(
        upload: UploadStatus = .uploaded,
        transcription: TranscriptionStatus? = nil
    ) -> Recording {
        var r = Recording(fileURL: URL(fileURLWithPath: "/tmp/reconcile-row.mp4"),
                          uploadStatus: upload)
        r.transcriptionStatus = transcription
        return r
    }

    // MARK: - Settled rows take the server's word (when it has the transcript to prove it)

    func testReadyWithATranscriptMarksTranscriptionDone() {
        let verdict = AppState.reconciledTranscription(serverStatus: "ready", local: local(),
                                                       hasTranscript: true)
        XCTAssertEqual(verdict.transcription, .done)
        XCTAssertNil(verdict.upload, "'ready' rewrote the upload axis it says nothing about")
    }

    func testReadyWithATranscriptAlsoSettlesALocallyFailedTranscription() {
        // The pipeline finished on another Mac (or a retry landed server-side): the server
        // row carries the real transcript, the local `.failed` is stale and the red retry
        // icon would be a lie.
        let verdict = AppState.reconciledTranscription(serverStatus: "ready",
                                                       local: local(transcription: .failed),
                                                       hasTranscript: true)
        XCTAssertEqual(verdict.transcription, .done)
    }

    // MARK: - "ready" without a transcript proves nothing

    func testReadyWithoutATranscriptDoesNotClobberAFailedTranscription() {
        // The exact shape of the bug this rule closes: a run whose transcription failed
        // stamped "ready" anyway, and the next sync repainted `.failed` as `.done` — a
        // green tick over a transcript that does not exist, Retry gone for good.
        let verdict = AppState.reconciledTranscription(serverStatus: "ready",
                                                       local: local(transcription: .failed),
                                                       hasTranscript: false)
        XCTAssertNil(verdict.transcription,
                     "'ready' with no transcript anywhere rewrote a local .failed")
        XCTAssertNil(verdict.upload)
    }

    func testReadyWithoutATranscriptInventsNothingForAnUnknownRow() {
        // A row this Mac has never seen: with no transcript to show, "ready" leaves the
        // transcription axis honestly unknown rather than inventing a green tick.
        let verdict = AppState.reconciledTranscription(serverStatus: "ready", local: local(),
                                                       hasTranscript: false)
        XCTAssertNil(verdict.transcription)
        XCTAssertNil(verdict.upload)
    }

    func testUploadFailedMarksTheUploadAxisOnly() {
        let verdict = AppState.reconciledTranscription(serverStatus: "upload_failed", local: local(),
                                                       hasTranscript: false)
        XCTAssertNil(verdict.transcription,
                     "'upload_failed' invented a transcription verdict it does not carry")
        XCTAssertEqual(verdict.upload, .failed)
    }

    // MARK: - Mid-pipeline statuses touch nothing

    func testMidPipelineStatusesTouchNothing() {
        for status in ["processing", "uploading", nil, "something_new"] as [String?] {
            for evidence in [true, false] {
                let verdict = AppState.reconciledTranscription(serverStatus: status, local: local(),
                                                               hasTranscript: evidence)
                XCTAssertNil(verdict.transcription, "server status \(status ?? "nil") rewrote local state")
                XCTAssertNil(verdict.upload, "server status \(status ?? "nil") rewrote local state")
            }
        }
    }

    // MARK: - A live local run outranks the server

    func testALiveLocalUploadIsNeverClobbered() {
        for status in ["ready", "upload_failed"] {
            let verdict = AppState.reconciledTranscription(serverStatus: status,
                                                           local: local(upload: .uploading),
                                                           hasTranscript: true)
            XCTAssertNil(verdict.transcription,
                         "'\(status)' overrode a task running in this very process")
            XCTAssertNil(verdict.upload)
        }
    }

    func testALiveLocalTranscriptionIsNeverClobbered() {
        for transcription in [TranscriptionStatus.queued, .transcribing] {
            for status in ["ready", "upload_failed"] {
                let verdict = AppState.reconciledTranscription(
                    serverStatus: status,
                    local: local(transcription: transcription),
                    hasTranscript: true
                )
                XCTAssertNil(verdict.transcription,
                             "a lagging server row stamped '\(status)' over a \(transcription) run")
                XCTAssertNil(verdict.upload)
            }
        }
    }

    /// Settled transcription statuses do NOT block the reconcile - only live ones do.
    func testASettledTranscriptionDoesNotBlockTheServer() {
        for transcription in [TranscriptionStatus.idle, .done, .failed, nil] as [TranscriptionStatus?] {
            let verdict = AppState.reconciledTranscription(
                serverStatus: "ready",
                local: local(transcription: transcription),
                hasTranscript: true
            )
            XCTAssertEqual(verdict.transcription, .done)
        }
    }
}

/// The other half of the same contract, at the source: what the final PATCH may claim.
/// "ready" is the pipeline's word that the whole run finished, and a run whose
/// transcription failed does not get to say it — nil means the PATCH carries title and
/// fields but leaves the server's `processingStatus` exactly as it stands.
final class FinalPatchStatusTests: XCTestCase {

    func testASuccessfulRunEarnsReady() {
        XCTAssertEqual(AppState.finalPatchStatus(transcriptionSucceeded: true), "ready")
    }

    func testAFailedRunSendsNoStatusAtAll() {
        XCTAssertNil(AppState.finalPatchStatus(transcriptionSucceeded: false),
                     "a failed transcription stamped the server 'ready' — the lie the reconcile then read back")
    }
}
