import XCTest
@testable import NoCornyTracer

/// The cache's two rules are the parts that can be wrong without anything looking wrong: an
/// eviction pass that keeps too much fills a disk quietly, one that drops too much sends every
/// re-run to Dropbox for a file that was here a moment ago. Neither needs audio to test - the
/// pass reads sizes and dates, and a directory of zero bytes has both.
final class DiarizationAudioCacheTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diarization-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEntry(
        _ id: UUID, bytes: Int, modified: Date, in cache: DiarizationAudioCache
    ) throws {
        try FileManager.default.createDirectory(at: cache.directory(for: id), withIntermediateDirectories: true)
        let file = cache.url(.mic, for: id)
        try Data(repeating: 0, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    // MARK: - Layout

    func testFilesLandUnderTheRecordingIDInTheFormatDropboxAlsoHolds() {
        let cache = DiarizationAudioCache(root: root)
        let id = UUID()

        XCTAssertEqual(cache.directory(for: id), root.appendingPathComponent(id.uuidString, isDirectory: true))
        XCTAssertEqual(cache.url(.mic, for: id).lastPathComponent, "mic.m4a")
        XCTAssertEqual(cache.url(.system, for: id).lastPathComponent, "system.m4a")
        XCTAssertEqual(cache.url(.mic, for: id).deletingLastPathComponent().lastPathComponent, id.uuidString)
    }

    func testAPathIsOnlyHandedOutWhenTheFileIsActuallyThere() throws {
        let cache = DiarizationAudioCache(root: root)
        let id = UUID()

        XCTAssertNil(cache.existingURL(.mic, for: id))
        XCTAssertFalse(cache.hasMicAudio(for: id))

        try makeEntry(id, bytes: 16, modified: Date(), in: cache)

        XCTAssertNotNil(cache.existingURL(.mic, for: id))
        XCTAssertTrue(cache.hasMicAudio(for: id))
        // Only the mic track was written, so the system slot stays empty rather than pointing
        // at a file the diarizer would fail to open.
        XCTAssertNil(cache.urls(for: id).system)
    }

    func testRemovingARecordingTakesBothTracksWithIt() throws {
        let cache = DiarizationAudioCache(root: root)
        let id = UUID()
        try makeEntry(id, bytes: 16, modified: Date(), in: cache)

        cache.remove(for: id)

        XCTAssertFalse(cache.hasMicAudio(for: id))
        XCTAssertEqual(cache.totalBytes(), 0)
    }

    // MARK: - Eviction

    func testOldestGoFirstUntilTheCacheFitsItsBudget() throws {
        let cache = DiarizationAudioCache(root: root, maxBytes: 300, maxAge: .greatestFiniteMagnitude)
        let now = Date()
        let oldest = UUID(), middle = UUID(), newest = UUID()
        try makeEntry(oldest, bytes: 200, modified: now.addingTimeInterval(-3000), in: cache)
        try makeEntry(middle, bytes: 200, modified: now.addingTimeInterval(-2000), in: cache)
        try makeEntry(newest, bytes: 200, modified: now.addingTimeInterval(-1000), in: cache)

        let evicted = cache.evict(now: now)

        XCTAssertEqual(evicted, [oldest, middle])
        XCTAssertFalse(cache.hasMicAudio(for: oldest))
        XCTAssertFalse(cache.hasMicAudio(for: middle))
        XCTAssertTrue(cache.hasMicAudio(for: newest))
        XCTAssertEqual(cache.totalBytes(), 200)
    }

    func testACacheInsideItsBudgetIsLeftAlone() throws {
        let cache = DiarizationAudioCache(root: root, maxBytes: 1000, maxAge: .greatestFiniteMagnitude)
        let id = UUID()
        try makeEntry(id, bytes: 400, modified: Date().addingTimeInterval(-9999), in: cache)

        XCTAssertEqual(cache.evict(), [])
        XCTAssertTrue(cache.hasMicAudio(for: id))
    }

    func testAnythingPastNinetyDaysGoesEvenWhenThereIsRoom() throws {
        let day = 24.0 * 60 * 60
        let cache = DiarizationAudioCache(root: root, maxBytes: .max)
        let now = Date()
        let stale = UUID(), fresh = UUID()
        try makeEntry(stale, bytes: 10, modified: now.addingTimeInterval(-91 * day), in: cache)
        try makeEntry(fresh, bytes: 10, modified: now.addingTimeInterval(-89 * day), in: cache)

        let evicted = cache.evict(now: now)

        XCTAssertEqual(evicted, [stale])
        XCTAssertTrue(cache.hasMicAudio(for: fresh))
    }

    /// Age and size are one pass, not two: an expired entry must not still be counted against
    /// the budget afterwards, or eviction takes a second, live recording with it.
    func testAnExpiredEntryIsNotAlsoChargedAgainstTheSizeBudget() throws {
        let day = 24.0 * 60 * 60
        let cache = DiarizationAudioCache(root: root, maxBytes: 300)
        let now = Date()
        let stale = UUID(), keep = UUID()
        try makeEntry(stale, bytes: 250, modified: now.addingTimeInterval(-120 * day), in: cache)
        try makeEntry(keep, bytes: 250, modified: now.addingTimeInterval(-1 * day), in: cache)

        let evicted = cache.evict(now: now)

        XCTAssertEqual(evicted, [stale])
        XCTAssertTrue(cache.hasMicAudio(for: keep))
    }

    func testStraysThatAreNotRecordingFoldersAreIgnored() throws {
        let cache = DiarizationAudioCache(root: root)
        try Data("not a recording".utf8).write(to: root.appendingPathComponent("README.txt"))
        let id = UUID()
        try makeEntry(id, bytes: 10, modified: Date(), in: cache)

        XCTAssertEqual(cache.entries().map(\.recordingID), [id])
        XCTAssertEqual(cache.totalBytes(), 10)
    }
}
