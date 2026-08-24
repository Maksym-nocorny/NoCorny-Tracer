import XCTest
@testable import NoCornyTracer

/// The server's `processingStatus` against local knowledge. The strings are the contract
/// the app itself PATCHes up ("uploading" / "processing" / "upload_failed" / "ready"), and
/// the one rule that outranks all of them: a live local run is never clobbered, because
/// this sync fires right after a recording is processed and the server row can lag a beat
/// behind the PATCH carrying the very result being synced.
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

    // MARK: - Settled rows take the server's word

    func testReadyMarksTranscriptionDone() {
        let verdict = AppState.reconciledTranscription(serverStatus: "ready", local: local())
        XCTAssertEqual(verdict.transcription, .done)
        XCTAssertNil(verdict.upload, "'ready' rewrote the upload axis it says nothing about")
    }

    func testReadyAlsoSettlesALocallyFailedTranscription() {
        // The pipeline finished on another Mac (or a retry landed server-side): the local
        // `.failed` is stale and the red retry icon would be a lie.
        let verdict = AppState.reconciledTranscription(serverStatus: "ready",
                                                       local: local(transcription: .failed))
        XCTAssertEqual(verdict.transcription, .done)
    }

    func testUploadFailedMarksTheUploadAxisOnly() {
        let verdict = AppState.reconciledTranscription(serverStatus: "upload_failed", local: local())
        XCTAssertNil(verdict.transcription,
                     "'upload_failed' invented a transcription verdict it does not carry")
        XCTAssertEqual(verdict.upload, .failed)
    }

    // MARK: - Mid-pipeline statuses touch nothing

    func testMidPipelineStatusesTouchNothing() {
        for status in ["processing", "uploading", nil, "something_new"] as [String?] {
            let verdict = AppState.reconciledTranscription(serverStatus: status, local: local())
            XCTAssertNil(verdict.transcription, "server status \(status ?? "nil") rewrote local state")
            XCTAssertNil(verdict.upload, "server status \(status ?? "nil") rewrote local state")
        }
    }

    // MARK: - A live local run outranks the server

    func testALiveLocalUploadIsNeverClobbered() {
        for status in ["ready", "upload_failed"] {
            let verdict = AppState.reconciledTranscription(serverStatus: status,
                                                           local: local(upload: .uploading))
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
                    local: local(transcription: transcription)
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
                local: local(transcription: transcription)
            )
            XCTAssertEqual(verdict.transcription, .done)
        }
    }
}
