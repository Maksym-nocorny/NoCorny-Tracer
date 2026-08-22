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
/// Lines an OLDER build wrote are no longer sanitized - they are excluded from a report
/// entirely, which is the point. Three rounds of review found three separate shapes that
/// pattern-based redaction missed (a prefix nobody listed, a multi-line model reply, a
/// twelfth naming line), so the defence stopped being "clean whatever is there" and became
/// "only send what this build wrote", which is auditable.
final class ReportScopeTests: XCTestCase {

    private let secret = "Layoff plan review with Sarah"

    /// A sanity check on the rule that replaced redaction: a report is either empty or made
    /// only of lines this version emitted.
    func testAReportOnlyEverCarriesThisVersionsLines() {
        let report = BugReportComposer.composeLogTail()
        guard report != "(log file missing or unreadable)", !report.isEmpty else { return }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let headers = report.components(separatedBy: "\n").filter { $0.contains("🚀 NoCorny Tracer v") }
        for header in headers {
            XCTAssertTrue(
                header.contains("v\(version) "),
                "a report carried a session from another build:\n  \(header)"
            )
        }
    }

    /// Defence in depth: this build logs no titles, but if one is added by mistake later it
    /// still must not travel.
    func testALabelledTitleIsStillRedacted() {
        for line in [
            "🤖 Combined: ✅ name=\"\(secret)\", srtLen=4821",
            "🌐 Tracer: ✅ Final PATCH — title: \"\(secret)\"",
            "🤖 AI Naming: ✅ Named: \"\(secret)\"",
        ] {
            let clean = LogManager.shared.sanitize(line)
            XCTAssertFalse(clean.contains(secret), "title survived: \(clean)")
        }
    }

    /// The failure the blunt version caused: error payloads are the diagnosis, and a
    /// sanitizer that eats them makes reports useless without making them safer.
    func testErrorPayloadsSurviveOnNamingLines() {
        let cases = [
            "🤖 Combined: ⚠️ Attempt 2 failed — blocked(reason: \"SAFETY\")",
            "🤖 Naming: ❌ serverError(status: 400, body: \"{\\\"error\\\":\\\"bad request\\\"}\")",
        ]
        for line in cases {
            let clean = LogManager.shared.sanitize(line)
            XCTAssertFalse(clean.contains("[TITLE]"), "redacted a diagnostic: \(clean)")
        }
        XCTAssertTrue(LogManager.shared.sanitize(cases[0]).contains("SAFETY"))
    }

    /// A JSON body with a "name" key is not a title.
    func testJsonNameKeyIsNotMistakenForATitle() {
        let body = "❌ Groq: HTTP 400: {\"model\":\"whisper\",\"name\":\"transcription\"}"
        let clean = LogManager.shared.sanitize(body)
        XCTAssertTrue(clean.contains("transcription"), "mangled a JSON body: \(clean)")
        XCTAssertFalse(clean.contains("[TITLE]"), "mangled a JSON body: \(clean)")
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
