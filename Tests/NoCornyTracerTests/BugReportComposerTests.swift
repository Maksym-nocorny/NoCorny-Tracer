import XCTest
@testable import NoCornyTracer

/// Runs the composer against this machine's real log, because that is the only way to
/// check the thing that actually matters: what would leave a user's Mac if they pressed
/// the button. A synthetic fixture only proves the filter works on lines someone thought
/// to write down.
final class BugReportComposerTests: XCTestCase {

    private var logExists: Bool {
        FileManager.default.fileExists(atPath: LogManager.shared.getLogFileURL().path)
    }

    func testNoCredentialsOrSpeechSurviveIntoAReport() throws {
        try XCTSkipUnless(logExists, "no app.log on this machine")

        // Prove the test is not passing because the log happens to be clean. Older builds
        // wrote share links, so a real log usually still holds some; if this machine's
        // does not, the assertions below prove nothing and the test says so.
        let raw = (try? String(contentsOf: LogManager.shared.getLogFileURL(), encoding: .utf8)) ?? ""
        try XCTSkipUnless(raw.contains("rlkey"), "this log predates the leak or is already clean")

        let report = BugReportComposer.composeLogTail()

        // The rlkey is the capability: whoever holds the URL can watch the recording.
        XCTAssertFalse(report.contains("rlkey"), "a Dropbox share credential reached the report")
        XCTAssertFalse(report.contains("dropbox.com"), "a Dropbox link reached the report")
        XCTAssertFalse(report.contains("dropboxusercontent.com"))
        // The user's own words.
        XCTAssertFalse(report.contains("Raw SRT ("), "a transcript preview reached the report")
        XCTAssertFalse(report.lowercased().contains("preview:"))
    }

    func testReportStaysUnderTheServerCap() throws {
        try XCTSkipUnless(logExists, "no app.log on this machine")
        let bytes = Data(BugReportComposer.composeLogTail().utf8).count
        XCTAssertLessThanOrEqual(bytes, 220_000, "over the 200 KB cap plus truncation notice")
    }

    func testReportIsNotEmptyWhenALogExists() throws {
        try XCTSkipUnless(logExists, "no app.log on this machine")
        let report = BugReportComposer.composeLogTail()
        XCTAssertFalse(report.isEmpty)
        XCTAssertNotEqual(report, "(log file missing or unreadable)")
    }

    /// Availability must not depend on finding errors. Gating the button on an error count
    /// hides it exactly when it is needed, because the reports worth having are the quiet
    /// ones: a short transcript, a title in the wrong language, nothing thrown anywhere.
    func testAvailabilityDoesNotRequireErrors() throws {
        try XCTSkipUnless(logExists, "no app.log on this machine")
        XCTAssertTrue(BugReportComposer.hasAnythingToReport())
    }
}
