import XCTest
@testable import NoCornyTracer

/// The scope rule, exercised against a log this process did not write.
///
/// The previous tests read the developer's real log, and under `swift test` the bundle
/// version is the test runner's - so they scoped to the runner's own startup banners and
/// passed without ever touching the rule. Three rounds of review found leaks while those
/// tests were green.
final class ReportScopeFixtureTests: XCTestCase {

    private var dir: URL!
    private var current: URL!
    private var previous: URL!

    /// A line the leaky v3.16.2 wrote, in every shape it wrote them.
    private let oldLeaks = [
        #"[2026-08-01T10:00:01Z] 📝: 🤖 Combined: ✅ Name: "Layoff plan review with Sarah""#,
        #"[2026-08-01T10:00:02Z] 📝: 🤖 Naming (image-only): ✅ "Layoff plan review with Sarah""#,
        #"[2026-08-01T10:00:03Z] ❌ ERROR: 🤖 Naming: ⚠️ accepting "Layoff plan review with Sarah" rather than losing the title"#,
        #"[2026-08-01T10:00:04Z] 📝: 🤖 Glossary: 3 terms — Sarah Kovalenko, Acme Legal, Project Halo"#,
        #"[2026-08-01T10:00:05Z] 📝: 🤖 Chunked: ✅ name="Layoff plan review with Sarah", srt 4821 chars"#,
    ]

    private func header(_ version: String, _ build: String) -> String {
        "[2026-08-01T10:00:00Z] 📝: 🚀 NoCorny Tracer v\(version) (\(build)) Started"
    }

    private var ourVersion: (String, String) { LogManager.sessionIdentity }

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        current = dir.appendingPathComponent("app.log")
        previous = dir.appendingPathComponent("app.old.log")
        try "".write(to: previous, atomically: true, encoding: .utf8)
        BugReportComposer.logSourceOverride = (current, previous)
    }

    override func tearDown() {
        BugReportComposer.logSourceOverride = nil
    }

    private func write(_ lines: [String]) throws {
        try lines.joined(separator: "\n").write(to: current, atomically: true, encoding: .utf8)
    }

    /// The case the whole design exists for.
    func testAnOlderBuildsSessionIsExcludedEntirely() throws {
        let (v, b) = ourVersion
        try write([header("3.16.2", "3.16.2")] + oldLeaks + [header(v, b),
                  "[2026-08-01T11:00:00Z] 📝: 🎬 Recording: started"])
        let report = BugReportComposer.composeLogTail()
        XCTAssertFalse(report.contains("Sarah"), "an older build's line reached the report:\n\(report)")
        XCTAssertFalse(report.contains("Acme"), "glossary terms reached the report")
        XCTAssertTrue(report.contains("Recording: started"), "lost our own lines")
    }

    /// A foreign session BETWEEN two of ours - a downgrade, a second install, someone
    /// running an old build once. A contiguous slice from the earliest match takes it whole.
    func testAForeignSessionBetweenTwoOfOursIsExcluded() throws {
        let (v, b) = ourVersion
        try write([header(v, b), "[2026-08-01T10:30:00Z] 📝: 🎬 first of ours"]
                  + [header("3.16.2", "3.16.2")] + oldLeaks
                  + [header(v, b), "[2026-08-01T12:00:00Z] 📝: 🎬 second of ours"])
        let report = BugReportComposer.composeLogTail()
        XCTAssertFalse(report.contains("Sarah"), "a session between ours rode along:\n\(report)")
        XCTAssertTrue(report.contains("second of ours"))
    }

    /// Same version, different build number: still not us.
    func testADifferentBuildOfTheSameVersionIsExcluded() throws {
        let (v, b) = ourVersion
        try write([header(v, "\(b)-beta1")] + oldLeaks + [header(v, b), "[2026-08-01T11:00:00Z] 📝: ours"])
        let report = BugReportComposer.composeLogTail()
        XCTAssertFalse(report.contains("Sarah"), "another build of the same version rode along")
    }

    /// Lines before any header belong to a session whose header scrolled out of the window.
    /// Whose build wrote them cannot be known, so they are not eligible.
    func testLinesWithNoHeaderAtAllAreNotEligible() throws {
        try write(oldLeaks)
        XCTAssertEqual(BugReportComposer.availability, .onlyOlderVersions)
        XCTAssertFalse(BugReportComposer.composeLogTail().contains("Sarah"))
    }

    func testAnEmptyLogIsReportedAsSuch() throws {
        try write([])
        XCTAssertEqual(BugReportComposer.availability, .noLogYet)
    }

    /// The rule must not be so eager that our own session is dropped.
    func testOurOwnSessionSurvivesIntact() throws {
        let (v, b) = ourVersion
        try write([header(v, b),
                   "[2026-08-01T11:00:00Z] ❌ ERROR: 🤖 Combined: ⚠️ Attempt 2 failed — blocked(reason: \"SAFETY\")",
                   "[2026-08-01T11:00:01Z] 📝: 📤 Upload: ✅ Uploaded (52.4 MB in 8.1s)"])
        let report = BugReportComposer.composeLogTail()
        XCTAssertTrue(report.contains("SAFETY"), "redacted the diagnosis: \(report)")
        XCTAssertTrue(report.contains("52.4 MB"), "lost the diagnostics")
        XCTAssertEqual(BugReportComposer.availability, .ready)
    }
}
