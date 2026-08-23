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
        // The line that makes these tests belong to the scope rule rather than to the
        // sanitizer. Everything above is redactable, so an assertion on it passes whether
        // scoping works or not - which is exactly what happened: the mutation proof quoted
        // in one commit stopped being true in the next, when a carve-out fix made the last
        // un-redactable line redactable. A continuation line of a model reply carries no
        // marker of its own and no pattern can recognise it, so only scope can keep it out.
        // Continuation lines whose payload line has already scrolled out of the window.
        // Nothing marks them, nothing precedes them to drop them, and no pattern can tell
        // this from ordinary prose - so redaction genuinely cannot touch it and only the
        // scope rule can keep it out. That is what makes the assertions below mean anything.
        #"  так от, я хочу сказати що дизайн тут геть не працює"#,
        #"  і треба переробити всю нижню панель до пʼятниці"#,
    ]

    /// Guards the guard: if this ever passes, the fixture has stopped testing scope.
    ///
    /// Measured through the composer's own redactor, not through `sanitize` alone. The
    /// report runs sanitize PLUS a transcript-preview pass, so a guard that only asked
    /// sanitize would still call the fixture "un-cleanable" after a strengthened composer
    /// had quietly started cleaning it - which is the exact way these tests died once.
    func testTheFixtureContainsSomethingRedactionCannotClean() {
        let unclean = oldLeaks.filter { BugReportComposer.redactForTests($0).contains("дизайн") }
        XCTAssertFalse(
            unclean.isEmpty,
            "every fixture line is now redactable, so the scope assertions below prove nothing"
        )
    }

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
        try? FileManager.default.removeItem(at: dir)
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
        XCTAssertFalse(report.contains("дизайн"), "an older build's speech reached the report:\n\(report)")
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
        XCTAssertFalse(report.contains("дизайн"), "a session between ours rode along:\n\(report)")
        XCTAssertTrue(report.contains("second of ours"))
    }

    /// Same version, different build number: still not us.
    func testADifferentBuildOfTheSameVersionIsExcluded() throws {
        let (v, b) = ourVersion
        try write([header(v, "\(b)-beta1")] + oldLeaks + [header(v, b), "[2026-08-01T11:00:00Z] 📝: ours"])
        let report = BugReportComposer.composeLogTail()
        XCTAssertFalse(report.contains("дизайн"), "another build of the same version rode along")
    }

    /// Lines before any header belong to a session whose header scrolled out of the window.
    /// Whose build wrote them cannot be known, so they are not eligible.
    func testLinesWithNoHeaderAtAllAreNotEligible() throws {
        try write(oldLeaks)
        XCTAssertEqual(BugReportComposer.availability, .onlyOlderVersions)
        XCTAssertFalse(BugReportComposer.composeLogTail().contains("дизайн"))
    }

    func testAnEmptyLogIsReportedAsSuch() throws {
        try write([])
        XCTAssertEqual(BugReportComposer.availability, .noLogYet)
    }

    /// A foreign header that lost its version - two processes appending at once clobber a
    /// line mid-write - used to be adopted by whatever session was open, because nothing
    /// closed one. Everything the foreign build then logged rode into our report.
    ///
    /// This branch shipped untested: deleting it outright passed the whole suite, which is
    /// how every other hole in this saga was born.
    func testATornHeaderClosesTheSessionInsteadOfAdoptingWhatFollows() throws {
        let (v, b) = ourVersion
        // Truncated exactly where a clobbered write would truncate: the marker prefix is
        // there, the version that identifies whose build it is never got written.
        let tornHeader = "[2026-08-01T10:45:00Z] 📝: 🚀 NoCorny Tracer"
        try write([header(v, b),
                   "[2026-08-01T10:30:00Z] 📝: 🎬 ours before the tear",
                   tornHeader] + oldLeaks)
        let report = BugReportComposer.composeLogTail()
        XCTAssertFalse(report.contains("дизайн"), "lines after a torn header joined our session:\n\(report)")
        XCTAssertFalse(report.contains("Acme"), "glossary terms after a torn header rode along")
        XCTAssertTrue(report.contains("ours before the tear"), "dropped our own lines before the tear")
    }

    /// The same tear, with one of ours after it: the report must resume, not stay closed.
    func testOurNextSessionAfterATornHeaderIsStillCollected() throws {
        let (v, b) = ourVersion
        try write([header(v, b),
                   "[2026-08-01T10:30:00Z] 📝: 🎬 ours before the tear",
                   "[2026-08-01T10:45:00Z] 📝: 🚀 NoCorny Tracer"] + oldLeaks
                  + [header(v, b), "[2026-08-01T12:00:00Z] 📝: 🎬 ours after the tear"])
        let report = BugReportComposer.composeLogTail()
        XCTAssertFalse(report.contains("дизайн"), "the torn session rode along")
        XCTAssertTrue(report.contains("ours after the tear"), "a tear stopped us collecting our own later session")
        XCTAssertEqual(BugReportComposer.availability, .ready)
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
