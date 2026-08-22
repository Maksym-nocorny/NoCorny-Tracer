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
}
