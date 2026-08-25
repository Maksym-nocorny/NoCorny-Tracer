import XCTest

/// The Sparkle keys embedded into the binary from Sources/NoCornyTracer/Info.plist
/// (linker __info_plist section). Losing one is silent and expensive: 4.0.0/4.1.0
/// shipped without `SUEnableAutomaticChecks`, so Sparkle raised its permission
/// prompt — which this almost-never-active app (nonactivating panels) opened
/// BEHIND every window. The unanswered prompt then blocked BOTH the manual
/// "Check for Updates" click and all scheduled checks: nobody saw a window,
/// nobody got updates. These tests read the SOURCE plist so the guard also
/// holds when the cached binary is stale (SwiftPM does not track the plist).
final class InfoPlistSparkleKeysTests: XCTestCase {

    private func loadPlist() throws -> [String: Any] {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/NoCornyTracerTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/NoCornyTracer/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any], "Info.plist is not a dictionary")
    }

    func testFeedURLAndSigningKeyArePresent() throws {
        let plist = try loadPlist()
        let feed = try XCTUnwrap(plist["SUFeedURL"] as? String)
        XCTAssertTrue(feed.hasPrefix("https://"), "Sparkle requires an HTTPS feed, got: \(feed)")
        let key = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertFalse(key.isEmpty, "An empty EdDSA key means unverifiable updates")
    }

    /// Without this key Sparkle asks permission with a prompt this app cannot
    /// surface — and an unanswered prompt disables the whole update pipeline.
    func testAutomaticChecksAreOnByDefault() throws {
        let plist = try loadPlist()
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
    }

    /// The silent cycle (4.2.0): scheduled checks download and stage updates in
    /// the background; the "Relaunch to update" chip is the only scheduled UI.
    func testSilentAutoUpdateIsOnByDefault() throws {
        let plist = try loadPlist()
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true)
    }
}
