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

    /// The privacy test above reads `productionLogFileURL`, and nothing else pins what that
    /// is. Pointed at the test scratch log - which is exactly the mutation that would undo
    /// the log-isolation fix - the privacy test finds a clean file and SKIPS, and a skip
    /// counts as green. This is the second time that test would have died silently; the
    /// first time, three skips instead of one was the only visible symptom, and nothing
    /// asserts the skip count.
    func testTheProductionLogPathIsTheInstalledAppsNotOurs() {
        let path = LogManager.productionLogFileURL.path
        XCTAssertTrue(path.contains("/Library/Application Support/NoCornyTracer/Logs/"),
                      "productionLogFileURL does not point at the installed app's log: \(path)")
        XCTAssertNotEqual(LogManager.productionLogFileURL, LogManager.shared.getLogFileURL(),
                          "under tests the logger writes to scratch; if these are equal, either the "
                          + "isolation is off or the privacy test is reading the scratch file")
        XCTAssertFalse(path.contains(FileManager.default.temporaryDirectory.path),
                       "the production path resolved into a temporary directory")
    }

    /// These three run the composer against a log THIS TEST wrote, through the same
    /// injection the scope tests use. They used to read whatever the process's logger had
    /// on disk, and the log-isolation change broke them in a way that only showed on a cold
    /// machine: the guard checked the shipped app's log while the composer read the test
    /// scratch log, whose first write was still sitting in the logger's queue. First run on
    /// a fresh clone: red. Second run: green. A suite that fails only on machines that have
    /// never run it is worse than one that fails everywhere.
    private func withComposerLog(lines: [String], _ body: () throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composer-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let current = dir.appendingPathComponent("app.log")
        let previous = dir.appendingPathComponent("app.old.log")
        try "".write(to: previous, atomically: true, encoding: .utf8)
        let (v, b) = LogManager.sessionIdentity
        let header = "[2026-08-01T10:00:00Z] 📝: 🚀 NoCorny Tracer v\(v) (\(b)) Started"
        try ([header] + lines).joined(separator: "\n")
            .write(to: current, atomically: true, encoding: .utf8)
        BugReportComposer.logSourceOverride = (current, previous)
        defer { BugReportComposer.logSourceOverride = nil }
        try body()
    }

    func testReportStaysUnderTheServerCap() throws {
        // Enough of our own session to blow well past the cap.
        let line = "[2026-08-01T11:00:00Z] 📝: 📤 Upload: chunk sent (1.2 MB in 0.8s)"
        try withComposerLog(lines: Array(repeating: line, count: 6_000)) {
            let bytes = Data(BugReportComposer.composeLogTail().utf8).count
            XCTAssertLessThanOrEqual(bytes, 220_000, "over the 200 KB cap plus truncation notice")
            XCTAssertGreaterThan(bytes, 150_000, "the cap test did not actually reach the cap")
        }
    }

    func testReportIsNotEmptyWhenALogExists() throws {
        try withComposerLog(lines: ["[2026-08-01T11:00:00Z] 📝: 🎬 Recording: started"]) {
            let report = BugReportComposer.composeLogTail()
            XCTAssertTrue(report.contains("Recording: started"))
            XCTAssertNotEqual(report, "(log file missing or unreadable)")
        }
    }

    /// Availability must not depend on finding errors. Gating the button on an error count
    /// hides it exactly when it is needed, because the reports worth having are the quiet
    /// ones: a short transcript, a title in the wrong language, nothing thrown anywhere.
    func testAvailabilityDoesNotRequireErrors() throws {
        try withComposerLog(lines: ["[2026-08-01T11:00:00Z] 📝: 🎬 Recording: started"]) {
            XCTAssertTrue(BugReportComposer.hasAnythingToReport())
        }
    }
}
