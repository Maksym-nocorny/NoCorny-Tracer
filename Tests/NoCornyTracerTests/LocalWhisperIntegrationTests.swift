import XCTest
@testable import NoCornyTracer

/// End-to-end run of the on-device engine against a real recording. Skipped unless
/// NCT_TEST_VIDEO points at one, because it downloads a 1.5 GB model and takes minutes;
/// it is here to be run deliberately, not on every `swift test`.
///
///     NCT_TEST_VIDEO=/path/clip.mp4 swift test --filter LocalWhisperIntegration
final class LocalWhisperIntegrationTests: XCTestCase {

    func testTranscribesARealRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["NCT_TEST_VIDEO"] else {
            throw XCTSkip("set NCT_TEST_VIDEO to run this")
        }
        let videoURL = URL(fileURLWithPath: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "no file at \(path)")
        XCTAssertTrue(LocalWhisperEngine.isAvailable, "Apple Silicon only")

        if !LocalWhisperEngine.isModelDownloaded() {
            print("⬇️  model not present, downloading…")
            var lastDecile = -1
            try await LocalWhisperEngine.downloadModel { progress in
                let decile = Int(progress * 10)
                if decile > lastDecile {
                    lastDecile = decile
                    print("⬇️  \(decile * 10)%")
                }
            }
            print("⬇️  download + prewarm done")
        }

        // The test process has its own defaults domain, so a `defaults write` against the
        // app's bundle id never reaches it. Set the preference here instead.
        if let lang = ProcessInfo.processInfo.environment["NCT_TEST_LANG"] {
            UserDefaults.standard.set(lang, forKey: "transcriptionLanguage")
        } else {
            UserDefaults.standard.removeObject(forKey: "transcriptionLanguage")
        }
        if let chunk = ProcessInfo.processInfo.environment["NCT_TEST_CHUNKING"] {
            UserDefaults.standard.set(chunk, forKey: "whisperChunking")
        } else {
            UserDefaults.standard.removeObject(forKey: "whisperChunking")
        }
        print("🌐 language = \(LocalWhisperEngine.preferredLanguage ?? "auto (detected once)")")

        let started = Date()
        let engine = LocalWhisperEngine()
        let result = await engine.transcribe(videoURL: videoURL, multiSpeaker: false)
        let wall = Date().timeIntervalSince(started)

        print("⏱  \(String(format: "%.1f", wall))s wall, errorCode=\(result.errorCode ?? "none"), fatal=\(result.fatal)")
        XCTAssertTrue(result.success, "engine reported failure: \(result.errorCode ?? "?")")
        XCTAssertEqual(result.name, nil, "the local engine must not invent a title")
        XCTAssertEqual(result.model, "whisperkit-large-v3-turbo")

        let srt = try XCTUnwrap(result.srt, "no transcript produced")
        let cues = SrtCodec.parseAndRepairSrt(srt)
        print("📝 \(cues.count) cues, \(srt.count) chars")
        XCTAssertGreaterThan(cues.count, 5, "suspiciously few cues for a real recording")

        // Cues must land inside the recording and move forward.
        for (a, b) in zip(cues, cues.dropFirst()) {
            XCTAssertLessThanOrEqual(a.start, b.start, "cues are out of order")
        }
        XCTAssertGreaterThanOrEqual(cues.first!.start, 0)

        // Write it out so the result can be read next to the cloud transcript.
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local-transcript.srt")
        try srt.write(to: out, atomically: true, encoding: .utf8)
        print("💾 \(out.path)")
    }
}
