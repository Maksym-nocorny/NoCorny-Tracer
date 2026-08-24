import XCTest
@testable import NoCornyTracer

/// The two things the first real out-of-space failure exposed: the reason reached the user
/// as a raw JSON blob (when it reached them at all - the row just went quietly grey), and a
/// twenty-minute upload had no indicator anywhere that bytes were moving.
final class UploadFailureAndProgressTests: XCTestCase {

    // MARK: - Naming the one fixable failure

    /// The exact body Dropbox answered with on the real failure of 24.08.2026.
    private let dropboxBody = #"{"error":{".tag":"path","reason":{".tag":"insufficient_space"}},"error_summary":"path/insufficient_space/"}"#

    func testDropboxSayingFullIsRecognised() {
        XCTAssertTrue(DropboxUploadManager.isOutOfSpace(dropboxBody))
        XCTAssertTrue(DropboxUploadManager.isOutOfSpace(Data(dropboxBody.utf8)))
    }

    func testOtherFailuresAreNotMistakenForFull() {
        XCTAssertFalse(DropboxUploadManager.isOutOfSpace(#"{"error_summary":"path/conflict/file/"}"#))
        XCTAssertFalse(DropboxUploadManager.isOutOfSpace(""))
        XCTAssertFalse(DropboxUploadManager.isOutOfSpace(Data()))
    }

    /// What the user reads. It has to say what happened, that the recording is safe, and
    /// what to do - the three things the raw blob said none of.
    func testTheMessageIsActionable() {
        let message = DropboxUploadManager.DropboxError.outOfSpace.errorDescription ?? ""
        XCTAssertTrue(message.contains("Dropbox is full"), "does not say what happened")
        XCTAssertTrue(message.contains("stayed on this Mac"), "does not say the recording is safe")
        XCTAssertTrue(message.contains("retry"), "does not say what to do next")
        XCTAssertFalse(message.contains("{"), "raw JSON reached the user again")
    }

    // MARK: - One climbing number across a chunked upload

    func testProgressClimbsAcrossChunks() {
        let chunk: UInt64 = 50, total: UInt64 = 120
        // Mid-first-chunk, mid-second, mid-last (short) chunk.
        let early = DropboxUploadManager.overallFraction(completedBytes: 0, chunkFraction: 0.5, chunkBytes: chunk, totalBytes: total)
        let middle = DropboxUploadManager.overallFraction(completedBytes: 50, chunkFraction: 0.5, chunkBytes: chunk, totalBytes: total)
        let late = DropboxUploadManager.overallFraction(completedBytes: 100, chunkFraction: 0.5, chunkBytes: chunk, totalBytes: total)
        XCTAssertEqual(early, 25.0 / 120.0, accuracy: 0.001)
        XCTAssertEqual(middle, 75.0 / 120.0, accuracy: 0.001)
        XCTAssertLessThan(early, middle)
        XCTAssertLessThan(middle, late)
    }

    /// The last chunk is short. Counting it at full chunk size overshoots past 1 near the
    /// end and snaps back - which reads as the upload breaking right before it finishes.
    func testTheShortLastChunkDoesNotOvershoot() {
        let f = DropboxUploadManager.overallFraction(completedBytes: 100, chunkFraction: 1.0, chunkBytes: 50, totalBytes: 120)
        XCTAssertEqual(f, 1.0, accuracy: 0.001)
        let mid = DropboxUploadManager.overallFraction(completedBytes: 100, chunkFraction: 0.5, chunkBytes: 50, totalBytes: 120)
        XCTAssertEqual(mid, 110.0 / 120.0, accuracy: 0.001, "the in-flight part must be capped at what remains")
    }

    func testDegenerateInputsDoNotBlowUp() {
        XCTAssertEqual(DropboxUploadManager.overallFraction(completedBytes: 0, chunkFraction: 0.5, chunkBytes: 50, totalBytes: 0), 0)
        XCTAssertEqual(DropboxUploadManager.overallFraction(completedBytes: 200, chunkFraction: 2.0, chunkBytes: 50, totalBytes: 120), 1.0)
        XCTAssertEqual(DropboxUploadManager.overallFraction(completedBytes: 0, chunkFraction: -1, chunkBytes: 50, totalBytes: 120), 0)
    }
}
