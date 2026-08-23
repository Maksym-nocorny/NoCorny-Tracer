import Foundation

/// A preferences store for tests that does not litter the developer's Preferences folder.
///
/// The first attempt gave every test a suite named after a fresh UUID and cleared it with
/// `removePersistentDomain`. That clears the keys and leaves the plist: 69 files had already
/// accumulated in ~/Library/Preferences, three more per run - from a seam whose entire purpose
/// was to stop tests touching the developer's real defaults.
///
/// One fixed name instead, wiped on the way in: at most one leftover file ever exists, rather
/// than one per test per run. It is not necessarily empty - a test that writes after the wipe
/// leaves those keys behind until the next wipe - but it is one file with a name that says
/// whose it is.
///
/// Wiping on creation rather than on teardown means a crashed test cannot leave state for the
/// next one. Under a plain `swift test` the classes run serially, so one shared name is safe;
/// under `--parallel` they are spread across processes sharing this one domain, and the wipe
/// could in principle race. Not reproduced in practice, and the parallel run is not how this
/// suite is used.
enum SandboxDefaults {
    static let suiteName = "com.nocorny.tracer.tests"

    static func make() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

import XCTest
@testable import NoCornyTracer

/// The suite writes to the log exactly the way the app does, and it had put 477 sessions into
/// the developer's real diagnostic log in one afternoon - the file bug reports are cut from,
/// and the file some of these tests read to prove nothing sensitive survives into a report.
/// The first attempt at detecting a test process checked an environment variable that SwiftPM
/// does not set, and silently never fired.
final class TestLogIsolationTests: XCTestCase {
    func testTheSuiteKnowsItIsATestProcess() {
        XCTAssertTrue(LogManager.isRunningUnderTests,
                      "the suite is writing into the developer's real diagnostic log")
    }
}
