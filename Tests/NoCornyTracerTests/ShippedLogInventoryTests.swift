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

    /// Every title-bearing shape the shipped v3.16.2 writes. Scoping keeps these out of a
    /// report entirely; this is the net under that, and it exists because the narrow
    /// label-based rule silently reopened five of them.
    func testEveryShippedTitleShapeIsRedacted() {
        let secret = "Layoff plan review with Sarah"
        let shapes = [
            "🤖 Combined: ✅ Second pass succeeded — name=\"\(secret)\", srtLen=4821",
            "🤖 Combined: ✅ First pass — name=\"\(secret)\", srtLen=4821",
            "🤖 AI Naming: ✅ Named: \"\(secret)\"",
            "🌐 Tracer: ✅ Final PATCH — title: \"\(secret)\"",
            "🔄 Retry: Retrying previous upload for \(secret)",
            "🤖 Combined: ⚠️ Language mismatch — SRT is uk, name \"\(secret)\" is en. Retrying with uk hint.",
            "🤖 Combined: ✅ Name: \"\(secret)\", restored SRT length: 4821",
            "🤖 Naming: ⚠️ name script latin ≠ transcript script cyrillic — one retry with hint, holding \"\(secret)\"",
            "🤖 Naming: ⚠️ language still mismatched — accepting \"\(secret)\" rather than losing the title",
            "🤖 Naming (image-only): ✅ \"\(secret)\"",
            "🤖 Chunked: ✅ name=\"\(secret)\", srt 4821 chars from 190 cues",
            "🤖 Glossary: 3 terms — Sarah Kovalenko, Acme Legal, Project Halo",
        ]
        for shape in shapes {
            let clean = LogManager.shared.sanitize(shape)
            // Each shape carries exactly one of these; asserting both on every shape is
            // how an assertion looks busy while proving nothing.
            if shape.contains("Glossary") {
                XCTAssertFalse(clean.contains("Sarah Kovalenko"), "glossary term survived:\n  out: \(clean)")
                XCTAssertFalse(clean.contains("Acme Legal"), "glossary term survived:\n  out: \(clean)")
            } else {
                XCTAssertFalse(clean.contains(secret), "title survived:\n  in:  \(shape)\n  out: \(clean)")
            }
        }
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

/// The error carve-out is a hole by construction: a naming line that looks like an error
/// keeps its quoted runs. That is correct for `blocked(reason: "SAFETY")`, and it is only
/// safe if no line that carries a TITLE can also look like an error. These are the ways it
/// could go wrong, taken from the shipped build's own wording.
final class ErrorCarveOutTests: XCTestCase {

    private let secret = "Layoff plan review with Sarah"

    /// The shipped naming-failure lines all contain the word "failed" or "mismatched" and a
    /// title. If "failed" alone triggered the carve-out, every one of them would leak.
    func testNamingFailureLinesStillLoseTheirTitle() {
        let shapes = [
            "🤖 Combined: ⚠️ Attempt 2 failed (timeout) — returning best earlier result \"\(secret)\"",
            "🤖 Naming: ⚠️ language still mismatched — accepting \"\(secret)\" rather than losing the title",
            "🤖 Naming: ⚠️ name script latin ≠ transcript script cyrillic — one retry with hint, holding \"\(secret)\"",
        ]
        for shape in shapes {
            let clean = LogManager.shared.sanitize(shape)
            XCTAssertFalse(clean.contains(secret), "the carve-out let a title through:\n  \(clean)")
        }
    }

    /// A title that happens to contain the word "error" must not buy itself an exemption.
    func testATitleContainingErrorWordsIsStillRedacted() {
        let awkward = "Error handling walkthrough for the failed() case"
        let clean = LogManager.shared.sanitize("🤖 Combined: ✅ Name: \"\(awkward)\", restored SRT length: 4821")
        XCTAssertFalse(clean.contains(awkward), "a title named itself out of redaction:\n  \(clean)")
    }

    /// Being inside parentheses is not enough on its own - a payload is a LABELLED
    /// argument. Mutation testing found this uncovered: dropping the label check broke no
    /// test, which meant a title in brackets would have walked out.
    func testQuotedTextInsideParensButUnlabelledIsStillATitle() {
        for line in [
            "🤖 Combined: ⚠️ Attempt 2 failed (timeout while naming \"\(secret)\")",
            "🤖 Naming: ⚠️ retry (was \"\(secret)\")",
        ] {
            let clean = LogManager.shared.sanitize(line)
            XCTAssertFalse(clean.contains(secret), "brackets alone bought an exemption:\n  \(clean)")
        }
    }

    /// The known trapdoor, pinned rather than fixed: a LABELLED argument is treated as a
    /// diagnosis, so a title logged as one would survive. Unreachable today - no call site
    /// on this branch logs a title at all, and no line the shipped build writes puts one
    /// inside parentheses behind a label - but if that ever changes, this test says so
    /// instead of a user finding out.
    func testALabelledTitleArgumentIsAKnownGap() {
        let clean = LogManager.shared.sanitize("🤖 Combined: ⚠️ failed (name: \"\(secret)\")")
        XCTAssertTrue(
            clean.contains(secret),
            "the labelled-argument gap closed - good, but update the comment that calls it a gap"
        )
    }

    /// The case the carve-out exists for.
    func testErrorDiagnosesSurvive() {
        for line in [
            "🤖 Combined: ⚠️ Attempt 2 failed — blocked(reason: \"SAFETY\")",
            "🤖 Naming: ❌ serverError(status: 400, body: \"quota exceeded\")",
        ] {
            let clean = LogManager.shared.sanitize(line)
            XCTAssertFalse(clean.contains("[TITLE]"), "redacted a diagnosis:\n  \(clean)")
        }
        XCTAssertTrue(LogManager.shared.sanitize("🤖 Combined: ⚠️ blocked(reason: \"RECITATION\")").contains("RECITATION"))
    }
}
