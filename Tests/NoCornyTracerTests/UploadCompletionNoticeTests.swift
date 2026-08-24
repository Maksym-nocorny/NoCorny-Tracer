import XCTest
@testable import NoCornyTracer

/// The pure decision behind the after-upload toast: what gets copied to the
/// pasteboard and what the toast says (`UploadCompletionNotice.decision`).
final class UploadCompletionNoticeTests: XCTestCase {

    func testLinkGetsCopiedAndAnnounced() {
        let url = URL(string: "https://tracer.nocorny.com/v/demo-slug")!
        let decision = UploadCompletionNotice.decision(shareURL: url)
        XCTAssertEqual(decision.copyText, "https://tracer.nocorny.com/v/demo-slug")
        XCTAssertEqual(decision.message, "Uploaded — link copied")
    }

    func testDropboxFallbackLinkIsCopiedVerbatim() {
        // A recording whose slug never resolved still shares its raw Dropbox link.
        let url = URL(string: "https://www.dropbox.com/scl/fi/abc/video.mp4?raw=1")!
        let decision = UploadCompletionNotice.decision(shareURL: url)
        XCTAssertEqual(decision.copyText, url.absoluteString)
        XCTAssertEqual(decision.message, "Uploaded — link copied")
    }

    func testNoLinkAnnouncesWithoutCopying() {
        let decision = UploadCompletionNotice.decision(shareURL: nil)
        XCTAssertNil(decision.copyText, "nothing lands on the pasteboard")
        XCTAssertEqual(decision.message, "Uploaded",
                       "no claim of a copied link that does not exist")
    }
}
