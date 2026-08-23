import XCTest
@testable import NoCornyTracer

/// Runs the composer against this machine's real log, because that is the only way to
/// check the thing that actually matters: what would leave a user's Mac if they pressed
/// the button. A synthetic fixture only proves the filter works on lines someone thought
/// to write down.
final class BugReportComposerTests: XCTestCase {

    /// The SHIPPED app's log, not this process's. Under tests the logger writes to a scratch
    /// file so the suite stops appending hundreds of fake sessions to the developer's real
    /// diagnostic log - but these tests are about that real log, and pointing them at the
    /// scratch one turned them into skips without anyone noticing.
    private var realLog: URL { LogManager.productionLogFileURL }

    private var logExists: Bool {
        FileManager.default.fileExists(atPath: realLog.path)
    }

    func testNoCredentialsOrSpeechSurviveIntoAReport() throws {
        try XCTSkipUnless(logExists, "no app.log on this machine")

        // Prove the test is not passing because the log happens to be clean. Older builds
        // wrote share links, so a real log usually still holds some; if this machine's
        // does not, the assertions below prove nothing and the test says so.
        let raw = (try? String(contentsOf: realLog, encoding: .utf8)) ?? ""
        try XCTSkipUnless(raw.contains("rlkey"), "this log predates the leak or is already clean")

        // Every line of the real log through the redactor the report uses. Deliberately not
        // through `composeLogTail`, which also applies the session scope: scoping alone would
        // make this pass by excluding the leaky lines rather than by cleaning them, and then
        // it would keep passing if the redactor rotted. Scope is tested separately, on a
        // fixture built so redaction cannot do its job for it.
        let redacted = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { BugReportComposer.redactForTests(String($0)) }
            .joined(separator: "\n")

        // The rlkey is the capability: whoever holds the URL can watch the recording.
        XCTAssertFalse(redacted.contains("rlkey"), "a Dropbox share credential survived redaction")
        XCTAssertFalse(redacted.contains("dropbox.com"), "a Dropbox link survived redaction")
        XCTAssertFalse(redacted.contains("dropboxusercontent.com"))
        // The user's own words. The marker itself is fine and expected: the fixed source logs
        // "Raw SRT (1423 chars)" and stops there, and there is nothing in that to redact. What
        // must never survive is the form that carries the speech after it.
        XCTAssertFalse(redacted.contains("chars) preview:"), "a transcript preview survived redaction")
        XCTAssertFalse(redacted.lowercased().contains("preview:"))
        XCTAssertFalse(redacted.contains("First 200 chars:"))
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
