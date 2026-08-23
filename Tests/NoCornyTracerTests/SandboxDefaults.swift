import Foundation

/// A preferences store for tests that does not litter the developer's Preferences folder.
///
/// The first attempt gave every test a suite named after a fresh UUID and cleared it with
/// `removePersistentDomain`. That clears the keys and leaves the plist: 69 files had already
/// accumulated in ~/Library/Preferences, three more per run - from a seam whose entire purpose
/// was to stop tests touching the developer's real defaults.
///
/// One fixed name instead, wiped on the way in. At most one leftover file ever exists, and it
/// is empty. Tests in a target run serially, so sharing the name is safe; wiping on creation
/// rather than on teardown also means a crashed test cannot leave state for the next one.
enum SandboxDefaults {
    static let suiteName = "com.nocorny.tracer.tests"

    static func make() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
