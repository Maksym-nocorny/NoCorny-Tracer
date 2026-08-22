import XCTest
@testable import NoCornyTracer

/// The exact lines the review pulled out of a real log. If any of these survives, a bug
/// report hands someone a working link to another person's recording, or its title.
final class ReviewedLeakShapesTests: XCTestCase {
    func testEveryShapeTheReviewFoundIsRedacted() {
        let lines = [
            "🌐 Tracer: ✅ initVideo - slug=Xk3mQ9a folder=/videos/Xk3mQ9a",
            "📤 Upload: Resuming previous reservation slug=Xk3mQ9a",
            "🌐 Tracer: PATCH /api/videos/Xk3mQ9a → 200",
            "🎛️ Diarization: ✅ re-labelled slug=Xk3mQ9a as 2 people",
            "🤖 Combined: ✅ Name: \"Q3 budget call with Acme legal\", restored SRT length: 4821",
            "🌐 Tracer: ✅ Final PATCH - title: \"Layoff plan review with Sarah\"",
            "❌ Dropbox: HTTP 409: {\"error\":\"path/conflict\",\"path\":\"/videos/Xk3mQ9a/mic.m4a\"}",
            "🔗 Shared link: ✅ https://www.dropbox.com/scl/fi/a/v.mp4?rlkey=SECRET",
            "registered at https://tracer.nocorny.com/v/Xk3mQ9a",
        ]
        for line in lines {
            let clean = LogManager.shared.sanitize(line)
            XCTAssertFalse(clean.contains("Xk3mQ9a"), "slug survived: \(clean)")
            XCTAssertFalse(clean.contains("rlkey"), "share credential survived: \(clean)")
            XCTAssertFalse(clean.contains("Acme"), "title survived: \(clean)")
            XCTAssertFalse(clean.contains("Sarah"), "title survived: \(clean)")
        }
    }
}

/// The recordings list is written to UserDefaults on every change - fourteen times during
/// a single recording. A transcript has no business being in that payload: it is other
/// people's speech, in plaintext, in ~/Library/Preferences, rewritten constantly.
final class RecordingEncodingTests: XCTestCase {
    func testATranscriptIsNeverEncodedIntoTheRecordingsList() throws {
        var rec = Recording(
            id: UUID(),
            fileURL: URL(fileURLWithPath: "/tmp/clip.mp4"),
            createdAt: Date(),
            duration: 120,
            aiGeneratedName: "Some meeting",
            uploadStatus: .uploaded
        )
        rec.legacyInlineTranscript = "1\n00:00:00,000 --> 00:00:02,000\nконфіденційна розмова"

        let data = try JSONEncoder().encode([rec])
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("конфіденційна"), "speech reached the prefs payload")
        XCTAssertFalse(json.contains("transcriptSrt"), "transcript key reached the prefs payload")
        // The rest of the row must still round-trip.
        let back = try JSONDecoder().decode([Recording].self, from: data)
        XCTAssertEqual(back.first?.aiGeneratedName, "Some meeting")
    }
}
