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
/// Every line in the SHIPPED build (v3.16.2) that writes a generated title, taken from
/// that build's source rather than from a list someone handed me. The last round of tests
/// asserted only the shapes a review had already quoted, so they passed while four other
/// shapes leaked - and those four are naming-FAILURE lines, which appear in precisely the
/// reports filed about bad titles.
final class ShippedTitleLogLinesTests: XCTestCase {

    private let secret = "Layoff plan review with Sarah"

    private func shippedLines() -> [String] {
        [
            "🤖 Combined: ✅ Second pass succeeded — name=\"\(secret)\", srtLen=4821",
            "🤖 Combined: ✅ First pass — name=\"\(secret)\", srtLen=4821",
            "🤖 AI Naming: ✅ Named: \"\(secret)\"",
            "🌐 Tracer: ✅ Final PATCH — title: \"\(secret)\"",
            "🔄 Retry: Retrying previous upload for \(secret)",
            "🤖 Combined: ⚠️ Language mismatch — SRT is uk, name \"\(secret)\" is en. Retrying with uk hint.",
            "🤖 Combined: ✅ Name: \"\(secret)\", restored SRT length: 4821",
            "🤖 Combined: ⚠️ Attempt 2 failed (timeout) — returning best earlier result \"\(secret)\"",
            "🤖 Naming: ⚠️ name script latin ≠ transcript script cyrillic — one retry with hint, holding \"\(secret)\"",
            "🤖 Naming: ⚠️ language still mismatched — accepting \"\(secret)\" rather than losing the title",
            "🤖 Naming (image-only): ✅ \"\(secret)\"",
        ]
    }

    func testNoShippedTitleLineSurvives() {
        for line in shippedLines() {
            let clean = LogManager.shared.sanitize(line)
            XCTAssertFalse(
                clean.contains(secret),
                "a meeting title survived sanitizing:\n  in:  \(line)\n  out: \(clean)"
            )
        }
    }

    /// Redaction has to stop at titles. A sanitizer that eats the numbers makes reports
    /// useless in a quieter way than one that leaks.
    func testDiagnosticsAroundTheTitleSurvive() {
        let clean = LogManager.shared.sanitize(
            "🤖 Combined: ✅ Name: \"\(secret)\", restored SRT length: 4821"
        )
        XCTAssertTrue(clean.contains("4821"), "lost the length: \(clean)")
        XCTAssertTrue(clean.contains("Combined"), "lost the context: \(clean)")
    }

    /// A JSON error body is not a title. The previous phrasing-based rule mangled any body
    /// carrying a "name" key, which Dropbox and Groq both use.
    func testJsonErrorBodiesAreNotMangled() {
        let body = "❌ Dropbox: HTTP 409: {\"error\":\"path/conflict\",\"name\":\"video.mp4\"}"
        let clean = LogManager.shared.sanitize(body)
        XCTAssertTrue(clean.contains("path/conflict"), "corrupted the error body: \(clean)")
        XCTAssertTrue(clean.contains("video.mp4"), "corrupted the error body: \(clean)")
    }
}

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
