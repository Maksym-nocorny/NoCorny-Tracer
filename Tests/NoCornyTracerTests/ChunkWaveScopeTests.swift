import XCTest
import AVFoundation
@testable import NoCornyTracer

private actor Asked {
    private(set) var flags: [Int: Bool] = [:]
    func record(_ index: Int, _ multiSpeaker: Bool) { flags[index] = multiSpeaker }
}

/// The wave hands every chunk a speaker scope. It used to describe a chunk run twice - once
/// to start the first `concurrency` of them, once to start the rest - and the first
/// description forgot the flag, so the opening chunks of every chunked run were transcribed
/// with "only the narrator" while the rest heard everyone. Under fifteen minutes of speech
/// that is the whole call, and the other person is simply not in the transcript. Separation
/// cannot put them back: it labels words, it does not recover them.
final class ChunkWaveScopeTests: XCTestCase {

    private var audioURL: URL!

    /// A real, tiny audio file, because the wave takes an asset and a track.
    override func setUpWithError() throws {
        audioURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wave-\(UUID().uuidString).caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: audioURL, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        try file.write(from: buffer)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: audioURL) }

    private func engine() -> CloudGeminiEngine {
        let proxy = GeminiProxyClient(tokenProvider: { nil })
        return CloudGeminiEngine(proxyClient: proxy, namingService: NamingService(proxyClient: proxy))
    }

    private func runWave(multiSpeaker: Bool, chunks: Int, concurrency: Int) async throws -> [Int: Bool] {
        let asset = AVURLAsset(url: audioURL)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let asked = Asked()
        let engine = engine()
        engine.chunkRunnerForTests = { plan, flag in
            await asked.record(plan.index, flag)
            var result = ChunkResult(index: plan.index, status: .failed)
            result.errorCode = "stubbed"
            result.fatal = true
            return result
        }
        _ = await engine.runChunkWave(
            plans: (0..<chunks).map {
                PlannedChunk(index: $0, ranges: [SampleRange(start: $0 * 16_000, end: ($0 + 1) * 16_000)])
            },
            totalChunks: chunks, sourceAsset: asset, sourceTrack: track,
            originalDuration: Double(chunks), glossary: [],
            concurrency: concurrency, scratchKey: "test-\(UUID().uuidString)",
            multiSpeaker: multiSpeaker
        )
        return await asked.flags
    }

    /// More chunks than the concurrency window, so the run crosses the boundary between the
    /// chunks started up front and the ones started as slots free up. That boundary is
    /// exactly where the two descriptions disagreed.
    func testEveryChunkIsAskedForTheScopeTheRunAskedFor() async throws {
        let asked = try await runWave(multiSpeaker: true, chunks: 7, concurrency: 3)
        XCTAssertEqual(asked.count, 7, "the wave did not run every chunk")
        for (index, flag) in asked {
            XCTAssertTrue(flag, "chunk \(index) was told to keep only the narrator")
        }
    }

    func testASingleSpeakerRunAsksNobodyForEveryone() async throws {
        let asked = try await runWave(multiSpeaker: false, chunks: 5, concurrency: 3)
        XCTAssertEqual(asked.count, 5)
        XCTAssertTrue(asked.values.allSatisfy { $0 == false })
    }

    /// The window boundary itself, spelled out: chunk 0 and chunk 3 are started by different
    /// loops, and both have to agree.
    func testTheFirstAndTheFourthChunkAgree() async throws {
        let asked = try await runWave(multiSpeaker: true, chunks: 4, concurrency: 3)
        XCTAssertEqual(asked[0], asked[3], "the seeded chunks and the refilled ones disagree")
        XCTAssertEqual(asked[0], true)
    }
}
