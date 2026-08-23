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

    // MARK: - Stopping a run the server has already answered

    private func runRefusedWave(chunks: Int, concurrency: Int) async throws -> (outcomes: [Int: ChunkResult], sent: Int) {
        let asset = AVURLAsset(url: audioURL)
        let track = try await asset.loadTracks(withMediaType: .audio).first!
        let asked = Asked()
        let engine = engine()
        engine.chunkRunnerForTests = { plan, _ in
            await asked.record(plan.index, true)
            var result = ChunkResult(index: plan.index, status: .failed)
            // What the proxy says when the plan does not include cloud transcription. It is
            // true of the account, so it is true of every chunk in this run.
            result.errorCode = "premium_required"
            result.fatal = true
            return result
        }
        let outcomes = await engine.runChunkWave(
            plans: (0..<chunks).map {
                PlannedChunk(index: $0, ranges: [SampleRange(start: $0 * 16_000, end: ($0 + 1) * 16_000)])
            },
            totalChunks: chunks, sourceAsset: asset, sourceTrack: track,
            originalDuration: Double(chunks), glossary: [],
            concurrency: concurrency, scratchKey: "test-\(UUID().uuidString)",
            multiSpeaker: true
        )
        return (outcomes, await asked.flags.count)
    }

    /// A refusal is about the account, so hearing it once answers the whole run. Sending the
    /// rest costs an AAC encode and an upload each, to be told the same thing again.
    func testARefusalStopsTheRunPayingForTheChunksItHasNotSentYet() async throws {
        let (outcomes, sent) = try await runRefusedWave(chunks: 12, concurrency: 3)
        XCTAssertLessThanOrEqual(sent, 3, "the wave kept sending chunks after the server had already refused")
        XCTAssertGreaterThan(sent, 0, "nothing was sent at all")
        XCTAssertEqual(outcomes.count, 12, "the chunks that were never sent went missing from the run")
    }

    /// Missing is not the same as skipped. The retry wave re-sends anything it finds missing
    /// or recoverably failed - so leaving the unsent ones absent would send every single one
    /// of them through the encode the stop just avoided.
    func testTheChunksThatWereNeverSentAreRecordedAsFinal() async throws {
        let (outcomes, _) = try await runRefusedWave(chunks: 12, concurrency: 3)
        for (index, outcome) in outcomes {
            XCTAssertTrue(outcome.fatal, "chunk \(index) would be retried against a server that already refused")
            XCTAssertEqual(outcome.errorCode, "premium_required", "chunk \(index) lost the verdict")
        }
    }

    /// And the verdict has to survive the aggregate, or the orchestrator never learns it may
    /// ask a different engine.
    func testTheRunsVerdictSurvivesIntoTheAggregate() async throws {
        let (outcomes, _) = try await runRefusedWave(chunks: 12, concurrency: 3)
        XCTAssertEqual(CloudGeminiEngine.refusalAmong(Array(outcomes.values)), "premium_required")
    }

    /// A run nobody refused must behave exactly as before: every chunk sent, nothing skipped.
    func testAnOrdinaryRunSendsEveryChunk() async throws {
        let asked = try await runWave(multiSpeaker: true, chunks: 12, concurrency: 3)
        XCTAssertEqual(asked.count, 12, "the stop fired on a run that was never refused")
    }

    /// The retry wave re-sends anything missing or recoverably failed. The chunks a stopped
    /// run never sent are recorded as final for exactly this reason: left recoverable, the
    /// second wave would send every one of them through the encode the stop just avoided.
    func testAStoppedRunSendsNothingToTheRetryWave() async throws {
        let (outcomes, _) = try await runRefusedWave(chunks: 12, concurrency: 3)
        let plans = (0..<12).map {
            PlannedChunk(index: $0, ranges: [SampleRange(start: $0 * 16_000, end: ($0 + 1) * 16_000)])
        }
        let retryable = CloudGeminiEngine.chunksWorthRetrying(plans, outcomes: outcomes)
        XCTAssertTrue(retryable.isEmpty, "a refused run would be re-sent chunk by chunk: \(retryable.count) chunks")
    }

    /// And an ordinary failure still gets its second chance.
    func testARecoverableFailureIsStillRetried() {
        let plans = (0..<3).map { PlannedChunk(index: $0, ranges: [SampleRange(start: 0, end: 16_000)]) }
        var flaky = ChunkResult(index: 0, status: .failed); flaky.errorCode = "timeout"; flaky.fatal = false
        var good = ChunkResult(index: 1, status: .transcribed)
        good.text = "hello"
        // Index 2 has no outcome at all - it never got an answer, so it is worth asking again.
        let retryable = CloudGeminiEngine.chunksWorthRetrying(plans, outcomes: [0: flaky, 1: good])
        XCTAssertEqual(retryable.map(\.index), [0, 2])
    }
}
