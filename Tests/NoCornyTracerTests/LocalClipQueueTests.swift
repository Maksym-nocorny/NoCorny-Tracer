import XCTest
@testable import NoCornyTracer

/// The signed-out drawer's "N clips waiting locally" counter: recordings that still
/// have a file on this Mac and are not yet in Dropbox. File existence is injected,
/// so nothing here touches the real disk.
final class LocalClipQueueTests: XCTestCase {

    private func recording(status: UploadStatus, path: String) -> Recording {
        Recording(fileURL: URL(fileURLWithPath: path), uploadStatus: status)
    }

    func testCountsLocalFilesThatAreNotUploadedYet() {
        let onDisk: Set<String> = ["/rec/a.mp4", "/rec/b.mp4", "/rec/c.mp4", "/rec/e.mp4"]
        let recordings = [
            recording(status: .notUploaded, path: "/rec/a.mp4"),  // waits
            recording(status: .uploading, path: "/rec/b.mp4"),    // still local until done
            recording(status: .failed, path: "/rec/c.mp4"),       // waits (retryable)
            recording(status: .notUploaded, path: "/rec/d.mp4"),  // file gone — not countable
            recording(status: .uploaded, path: "/rec/e.mp4")      // done — never counts
        ]
        let count = LocalClipQueue.waitingCount(recordings: recordings) {
            onDisk.contains($0.path)
        }
        XCTAssertEqual(count, 3)
    }

    func testUploadedNeverCountsEvenWithTheFileStillPresent() {
        let recordings = [recording(status: .uploaded, path: "/rec/a.mp4")]
        let count = LocalClipQueue.waitingCount(recordings: recordings) { _ in true }
        XCTAssertEqual(count, 0)
    }

    func testMissingFilesNeverCount() {
        let recordings = [
            recording(status: .notUploaded, path: "/rec/a.mp4"),
            recording(status: .failed, path: "/rec/b.mp4")
        ]
        let count = LocalClipQueue.waitingCount(recordings: recordings) { _ in false }
        XCTAssertEqual(count, 0)
    }

    func testEmptyLibraryIsZero() {
        XCTAssertEqual(LocalClipQueue.waitingCount(recordings: []) { _ in true }, 0)
    }
}
