import XCTest
@testable import NoCornyTracer

/// Developer benchmark for the on-device engine: the REAL `LocalWhisperEngine.transcribe`
/// (audio extraction, VAD, model load, decode, cue repair) against a real recording, once per
/// model variant, with a JSON report. Skipped unless `NCT_BENCH_VIDEO` is set, so it never
/// runs on a plain `swift test`: it downloads models and takes minutes.
///
///     NCT_BENCH_VIDEO=/path/take.mp4 \
///     NCT_BENCH_VARIANTS=openai_whisper-large-v3_turbo,openai_whisper-large-v3-v20240930_turbo \
///     NCT_BENCH_RUNS=2 NCT_BENCH_OUT=/tmp/nct-asr-bench.json \
///     swift test --filter LocalASRBench
///
/// Each variant is downloaded and compiled first (the prewarm budget, as a user's first
/// transcript after the download), so the timed runs measure a warm model. The first timed
/// run of a variant still includes the load from the warm cache; the second is decode alone.
final class LocalASRBenchTests: XCTestCase {

    func testBench() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["NCT_BENCH_VIDEO"], !path.isEmpty else {
            throw XCTSkip("set NCT_BENCH_VIDEO to run the on-device ASR benchmark")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "no file at \(path)")
        XCTAssertTrue(LocalWhisperEngine.isAvailable, "Apple Silicon only")

        let variants = (env["NCT_BENCH_VARIANTS"] ?? LocalWhisperEngine.defaultVariant)
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let runs = max(1, Int(env["NCT_BENCH_RUNS"] ?? "1") ?? 1)
        let outPath = env["NCT_BENCH_OUT"] ?? "/tmp/nct-asr-bench.json"
        let videoURL = URL(fileURLWithPath: path)
        let original = LocalWhisperEngine.variant
        defer { LocalWhisperEngine.variant = original }

        var report: [[String: Any]] = []
        for variant in variants {
            LocalWhisperEngine.variant = variant
            print("🧪 variant \(variant): \(LocalWhisperEngine.isModelDownloaded(variant: variant) ? "on disk" : "downloading")")

            let tPrep = Date()
            try await LocalWhisperEngine.downloadModel(prewarm: true) { p in
                if Int(p * 100) % 20 == 0 { print("⬇️  \(Int(p * 100))%") }
            }
            let prepSec = Date().timeIntervalSince(tPrep)
            print(String(format: "🧪 ready in %.0f s (download + compile)", prepSec))
            XCTAssertEqual(LocalWhisperEngine.activeVariant, variant, "the engine is not going to load the variant under test")

            for run in 0..<runs {
                let engine = LocalWhisperEngine()
                let t0 = Date()
                let result = await engine.transcribe(videoURL: videoURL, multiSpeaker: false)
                let wall = Date().timeIntervalSince(t0)
                let cues = result.srt.map { SrtCodec.parseAndRepairSrt($0) } ?? []
                let audioSec = cues.last.map { $0.end } ?? 0
                print(String(format: "🧪 %@ run %d: %.1f s wall, %d cues, success=%@ error=%@",
                             variant, run, wall, cues.count, result.success ? "yes" : "no", result.errorCode ?? "none"))
                XCTAssertTrue(result.success, "\(variant) run \(run): \(result.errorCode ?? "?")")
                report.append([
                    "variant": variant,
                    "run": run,
                    "prep_sec": prepSec,
                    "wall_sec": wall,
                    "latency_ms": result.latencyMs,
                    "cues": cues.count,
                    "last_cue_end_sec": audioSec,
                    "text": cues.map(\.text).joined(separator: "\n"),
                    "cues_timed": cues.map { ["start": $0.start, "end": $0.end, "text": $0.text] },
                ])
            }
        }

        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath))
        print("🧪 report: \(outPath)")
    }
}
