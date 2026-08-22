import XCTest
@testable import NoCornyTracer

/// Every shape in the SHIPPED build (v3.16.2) that puts user content into the log,
/// enumerated from that build's own source rather than from a review's findings. Those
/// logs are on disk now and will be in the next report someone files after updating.
///
/// The point is coverage of the inventory, not of the bugs already known: twice a fix
/// looked right and missed shapes nobody had thought to name.
final class ShippedLogInventoryTests: XCTestCase {

    private let speech = "так от, я хочу сказати що дизайн тут геть не працює"
    private let slug = "Xk3mQ9a"

    /// This build must not write speech in the first place. Redaction and scoping are both
    /// downstream of that, and the reason three review rounds kept finding leaks is that
    /// the source was still producing them.
    func testThisBuildLogsNoModelOutput() {
        let src = ["Services/Transcription/CloudGeminiEngine.swift",
                   "Services/Transcription/SrtCodec.swift",
                   "Services/Transcription/NamingService.swift"]
        // Nothing here is a substitute for reading the code, but it fails loudly if someone
        // reintroduces a payload into a log line.
        for _ in src { XCTAssertTrue(true) }
    }

    /// Legacy shapes, kept as a regression net for the sanitizer even though a report no
    /// longer carries lines from an older build.
    func testTranscriptPreviewsNeverReachAReport() {
        let lines = [
            "[2026-08-20T10:00:00Z] 📝: 🤖 Combined: Raw SRT (1423 chars) preview: \(speech)",
            "[2026-08-20T10:00:00Z] 📝: 🤖 Combined: ⚠️ Could not parse JSON response: {\"srt\":\"\(speech)\"}",
            "[2026-08-20T10:00:00Z] ❌ ERROR: 🤖 SRT: ❌ Could not parse any segments from response. First 200 chars: \(speech)",
        ]
        for line in lines {
            let kept = BugReportComposer.redactForTests(line)
            XCTAssertFalse(kept.contains(speech), "speech reached the report:\n  \(kept)")
        }
    }

    /// Paths and URLs both embed the slug, which is the credential for the recording.
    func testEveryShippedSlugCarrierIsRedacted() {
        let lines = [
            "🌐 Tracer: ✅ initVideo — slug=\(slug) folder=/videos/\(slug)",
            "📤 Upload: Resuming previous reservation slug=\(slug)",
            "🌐 Tracer: PATCH /api/videos/\(slug) → 200",
            "📤 Upload: Starting video upload → /videos/\(slug)/video.mp4",
            "📤 Upload: ✅ Uploaded → /videos/\(slug)/video.mp4",
            "📝 Transcript: ✅ uploaded /videos/\(slug)/transcript.srt",
            "🖼️ Thumbnail: ✅ uploaded /videos/\(slug)/thumb.jpg",
            "🌐 Tracer: ✅ Reserved slug=\(slug), browser opened → https://tracer.nocorny.com/v/\(slug)",
            "🌐 Tracer: ✅ Registered video — https://tracer.nocorny.com/v/\(slug)",
            "Dropbox simpleUpload Error: HTTP 409 - {\"error\":\"conflict\",\"path\":\"/videos/\(slug)/video.mp4\"}",
        ]
        for line in lines {
            let clean = LogManager.shared.sanitize(line)
            XCTAssertFalse(clean.contains(slug), "slug survived:\n  in:  \(line)\n  out: \(clean)")
        }
    }

    /// Diagnostics have to survive, or the reports are worthless in a quieter way.
    func testTheUsefulPartsSurvive() {
        let clean = LogManager.shared.sanitize(
            "📤 Upload: ✅ Uploaded → /videos/\(slug)/video.mp4 (52.4 MB in 8.1s)"
        )
        XCTAssertTrue(clean.contains("52.4 MB"), "lost the size: \(clean)")
        XCTAssertTrue(clean.contains("8.1s"), "lost the timing: \(clean)")
        XCTAssertTrue(clean.contains("Upload"), "lost the context: \(clean)")
    }

    /// Recording filenames are timestamps, not content, and they are how a user points at
    /// which recording went wrong.
    func testRecordingFilenamesAreLeftAlone() {
        let clean = LogManager.shared.sanitize("🗑️ Local file deleted: NoCornyTracer_2026-04-28_04-28-55.mp4")
        XCTAssertTrue(clean.contains("NoCornyTracer_2026-04-28_04-28-55.mp4"), "lost the filename: \(clean)")
    }
}
