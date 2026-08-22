import XCTest
@testable import NoCornyTracer

/// The recordings list is JSON-encoded into `UserDefaults` on every state change, and
/// processing a single recording changes state about fourteen times. Anything riding along
/// inside a `Recording` is therefore rewritten fourteen times and then lives in
/// `~/Library/Preferences` indefinitely -- which is a fine place for a window size and the
/// wrong place for an hour of somebody's meeting.
final class TranscriptStorageTests: XCTestCase {

    private var store: TranscriptStore!
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = TranscriptStore(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func recording() -> Recording {
        Recording(fileURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).mp4"))
    }

    // MARK: - What gets persisted

    func testEncodingARecordingCarriesNoTranscript() throws {
        var rec = recording()
        rec.legacyInlineTranscript = "1\n00:00:00,000 --> 00:00:02,000\nthe merger closes on friday"
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(rec), encoding: .utf8))
        XCTAssertFalse(json.contains("merger"), "speech reached the preferences plist: \(json)")
        XCTAssertFalse(json.contains("transcriptSrt"), "the inline key is back: \(json)")
    }

    /// Everything else still has to survive the round trip, or moving the transcript out
    /// would have cost the library.
    func testTheRestOfTheRecordingStillRoundTrips() throws {
        var rec = recording()
        rec.tracerSlug = "Xk3mQ9a"
        rec.transcriptEngine = "whisper-large-v3"
        rec.expectedSpeakers = .two
        rec.diarizationMicPath = "/videos/Xk3mQ9a/mic.m4a"
        rec.uploadStatus = .uploaded

        let decoded = try JSONDecoder().decode(Recording.self, from: JSONEncoder().encode(rec))
        XCTAssertEqual(decoded.id, rec.id)
        XCTAssertEqual(decoded.tracerSlug, "Xk3mQ9a")
        XCTAssertEqual(decoded.transcriptEngine, "whisper-large-v3")
        XCTAssertEqual(decoded.expectedSpeakers, .two)
        XCTAssertEqual(decoded.diarizationMicPath, "/videos/Xk3mQ9a/mic.m4a")
        XCTAssertEqual(decoded.uploadStatus, .uploaded)
    }

    /// A list written by the build that kept transcripts inline still has to hand its
    /// transcript over, or upgrading would silently lose every one of them.
    func testAListFromAnOlderBuildStillYieldsItsInlineTranscript() throws {
        let rec = recording()
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(rec)) as? [String: Any]
        )
        fields["transcriptSrt"] = "1\n00:00:00,000 --> 00:00:02,000\nhello"
        let data = try JSONSerialization.data(withJSONObject: fields)

        let decoded = try JSONDecoder().decode(Recording.self, from: data)
        XCTAssertEqual(decoded.legacyInlineTranscript, "1\n00:00:00,000 --> 00:00:02,000\nhello")
    }

    // MARK: - The store itself

    func testSaveLoadAndRemove() throws {
        let id = UUID()
        XCTAssertFalse(store.hasTranscript(for: id))
        XCTAssertNil(store.load(for: id))

        store.save("1\n00:00:00,000 --> 00:00:02,000\nhello", for: id)
        XCTAssertTrue(store.hasTranscript(for: id))
        XCTAssertEqual(store.load(for: id), "1\n00:00:00,000 --> 00:00:02,000\nhello")

        store.remove(for: id)
        XCTAssertFalse(store.hasTranscript(for: id))
        XCTAssertNil(store.load(for: id))
    }

    /// Saving nothing has to remove the file rather than leave an empty one, or `load` and
    /// `hasTranscript` start disagreeing and the Recordings list offers a control that fails.
    func testSavingNothingClearsWhatWasThere() throws {
        let id = UUID()
        store.save("something", for: id)
        store.save(nil, for: id)
        XCTAssertFalse(store.hasTranscript(for: id))

        store.save("something", for: id)
        store.save("", for: id)
        XCTAssertFalse(store.hasTranscript(for: id))
    }

    func testTranscriptsAreKeptApartByRecording() throws {
        let first = UUID()
        let second = UUID()
        store.save("first transcript", for: first)
        store.save("second transcript", for: second)
        XCTAssertEqual(store.load(for: first), "first transcript")
        XCTAssertEqual(store.load(for: second), "second transcript")

        store.remove(for: first)
        XCTAssertNil(store.load(for: first))
        XCTAssertEqual(store.load(for: second), "second transcript")
    }
}
