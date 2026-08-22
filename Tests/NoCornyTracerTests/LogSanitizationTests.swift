import XCTest
@testable import NoCornyTracer

/// The diagnostic log is about to become something we ask users to send us, so what can
/// reach it is a privacy question rather than a tidiness one. These are the three things
/// that must never survive: their own speech, a working link to their recording, and
/// their email.
final class LogSanitizationTests: XCTestCase {

    private func sanitized(_ message: String) -> String {
        LogManager.shared.sanitize(message)
    }

    func testDropboxShareLinkIsRedacted() {
        let line = sanitized(
            "🔗 Shared link: ✅ https://www.dropbox.com/scl/fi/abc123/Recording.mp4?rlkey=SECRETKEY&dl=0"
        )
        XCTAssertFalse(line.contains("rlkey"), "the share credential survived: \(line)")
        XCTAssertFalse(line.contains("dropbox.com"))
        XCTAssertTrue(line.contains("[LINK]"))
    }

    func testDirectDropboxContentLinkIsRedacted() {
        let line = sanitized("streaming from https://dl.dropboxusercontent.com/scl/fi/xyz/v.mp4?rlkey=abc")
        XCTAssertFalse(line.contains("rlkey"))
        XCTAssertTrue(line.contains("[LINK]"))
    }

    func testPublicRecordingPageIsRedacted() {
        let line = sanitized("registered at https://tracer.nocorny.com/v/2wfLsnk")
        XCTAssertFalse(line.contains("2wfLsnk"), "the slug identifies the recording: \(line)")
        XCTAssertTrue(line.contains("[LINK]"))
    }

    func testEmailIsRedacted() {
        let line = sanitized("Signed in as alice@example.com")
        XCTAssertFalse(line.contains("alice@example.com"))
        XCTAssertTrue(line.contains("[EMAIL]"))
    }

    func testHomeDirectoryIsRedacted() {
        let line = sanitized("wrote \(NSHomeDirectory())/Movies/clip.mp4")
        XCTAssertFalse(line.contains(NSHomeDirectory()))
        XCTAssertTrue(line.contains("/Users/[USER]"))
    }

    /// Redaction must not eat ordinary diagnostics -- an over-eager sanitizer that
    /// blanks the useful half makes the reports worthless in a quieter way.
    func testOrdinaryDiagnosticsSurviveIntact() {
        let line = sanitized("🤖 Combined: Raw SRT (1423 chars)")
        XCTAssertTrue(line.contains("1423 chars"))
        XCTAssertFalse(line.contains("[LINK]"))
    }

    func testUnrelatedURLsAreLeftAlone() {
        let line = sanitized("fetched https://api.github.com/repos/x/releases/latest")
        XCTAssertTrue(line.contains("api.github.com"))
    }

    // MARK: - Bare slugs
    //
    // A slug needs no host in front of it to be a credential: paste it after
    // tracer.nocorny.com/v/ and the recording plays. Redacting only whole URLs left it in
    // plain sight in every line the pipeline writes about a recording, and the bug
    // reporter's flow filter selects exactly those lines.

    func testReservationSlugAndFolderAreRedacted() {
        let line = sanitized("🌐 Tracer: ✅ initVideo - slug=Xk3mQ9a folder=/videos/Xk3mQ9a")
        XCTAssertFalse(line.contains("Xk3mQ9a"), "the slug opens the recording: \(line)")
        XCTAssertTrue(line.contains("slug=[SLUG]"))
        XCTAssertTrue(line.contains("/videos/[SLUG]"))
    }

    func testResumedReservationSlugIsRedacted() {
        let line = sanitized("📤 Upload: Resuming previous reservation slug=Xk3mQ9a")
        XCTAssertFalse(line.contains("Xk3mQ9a"), "the slug opens the recording: \(line)")
    }

    func testAPIPathSlugIsRedacted() {
        let line = sanitized("🌐 Tracer: PATCH /api/videos/Xk3mQ9a → 200")
        XCTAssertFalse(line.contains("Xk3mQ9a"), "the slug opens the recording: \(line)")
        XCTAssertTrue(line.contains("200"), "the status code is the half worth reporting: \(line)")
    }

    func testRelabelledSlugIsRedacted() {
        let line = sanitized("🎛️ Diarization: ✅ re-labelled slug=Xk3mQ9a as 2 people")
        XCTAssertFalse(line.contains("Xk3mQ9a"), "the slug opens the recording: \(line)")
        XCTAssertTrue(line.contains("2 people"))
    }

    /// Two lines shipped with the slug bare, and those logs are on disk when someone
    /// upgrades and files a report -- which is the moment a report gets filed at all.
    func testBareSlugFromAnOlderBuildIsRedacted() {
        XCTAssertFalse(sanitized("🎛️ Diarization: ✅ re-labelled Xk3mQ9a as 2 people").contains("Xk3mQ9a"))
        XCTAssertFalse(sanitized("🗑️ Tracer: deleted Xk3mQ9a").contains("Xk3mQ9a"))
        XCTAssertFalse(sanitized("❌ Tracer: delete Xk3mQ9a failed").contains("Xk3mQ9a"))
    }

    /// Dropbox renders the upstream response body into `localizedDescription`, and the body
    /// quotes back the slug-keyed path the upload was aimed at.
    func testDropboxErrorBodyPathIsRedacted() {
        let line = sanitized(
            #"⚠️ Upload Attempt 2 failed Details: HTTP 409: {"error_summary": "path/conflict/file/.", "path": "/videos/Xk3mQ9a/video.mp4"}"#
        )
        XCTAssertFalse(line.contains("Xk3mQ9a"), "the slug opens the recording: \(line)")
        XCTAssertTrue(line.contains("path/conflict"), "the failure reason is what the report is for: \(line)")
    }

    // MARK: - Generated titles
    //
    // "Layoff plan review with Sarah" needs no transcript attached to be the leak. Call
    // sites log a length now; the sink covers logs written by older builds.

    func testGeneratedTitleDoesNotSurvive() {
        let line = sanitized(#"🤖 Combined: ✅ Name: "Q3 budget call with Acme legal", restored SRT length: 4821"#)
        XCTAssertFalse(line.contains("Q3 budget call"), "the title named the meeting: \(line)")
        XCTAssertFalse(line.contains("Acme"))
        XCTAssertTrue(line.contains("4821"), "the length is the diagnostic half: \(line)")
    }

    func testFinalPatchTitleDoesNotSurvive() {
        let line = sanitized(#"🌐 Tracer: ✅ Final PATCH - title: "Layoff plan review with Sarah""#)
        XCTAssertFalse(line.contains("Layoff"), "the title named the meeting: \(line)")
        XCTAssertFalse(line.contains("Sarah"))
    }
}
