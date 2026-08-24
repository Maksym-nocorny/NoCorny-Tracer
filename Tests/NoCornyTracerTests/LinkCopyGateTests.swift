import XCTest
@testable import NoCornyTracer

/// The Gallery drawer's row-click gate: a click copies `shareURL`, and a row without
/// one is inert. The gate must follow shareURL's priority chain exactly
/// (tracer page → Dropbox shared link → legacy Drive → nothing).
final class LinkCopyGateTests: XCTestCase {

    private func recording(
        tracerURL: String? = nil,
        dropboxSharedURL: String? = nil,
        driveFileID: String? = nil
    ) -> Recording {
        var recording = Recording(fileURL: URL(fileURLWithPath: "/tmp/clip.mp4"))
        recording.tracerURL = tracerURL
        recording.dropboxSharedURL = dropboxSharedURL
        recording.driveFileID = driveFileID
        return recording
    }

    func testTracerURLWinsOverEverything() {
        let rec = recording(
            tracerURL: "https://tracer.nocorny.com/v/xFel134",
            dropboxSharedURL: "https://www.dropbox.com/s/abc/video.mp4",
            driveFileID: "legacy123"
        )
        XCTAssertTrue(rec.canCopyLink)
        XCTAssertEqual(rec.shareURL?.absoluteString, "https://tracer.nocorny.com/v/xFel134")
    }

    func testDropboxLinkIsTheFallback() {
        let rec = recording(dropboxSharedURL: "https://www.dropbox.com/s/abc/video.mp4")
        XCTAssertTrue(rec.canCopyLink)
        XCTAssertEqual(rec.shareURL?.absoluteString, "https://www.dropbox.com/s/abc/video.mp4")
    }

    func testLegacyDriveIsTheLastResort() {
        let rec = recording(driveFileID: "legacy123")
        XCTAssertTrue(rec.canCopyLink)
        XCTAssertEqual(
            rec.shareURL?.absoluteString,
            "https://drive.google.com/file/d/legacy123/view"
        )
    }

    func testNoLinkAnywhereClosesTheGate() {
        let rec = recording()
        XCTAssertNil(rec.shareURL)
        XCTAssertFalse(rec.canCopyLink)
    }

    func testFreshLocalRecordingIsInert() {
        // The state every recording starts in: file on disk, nothing uploaded yet.
        let rec = Recording(fileURL: URL(fileURLWithPath: "/tmp/clip.mp4"))
        XCTAssertFalse(rec.canCopyLink)
    }
}
