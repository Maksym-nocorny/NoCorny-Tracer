import XCTest
@testable import NoCornyTracer

/// A stand-in engine with a scripted answer, so the walk can be exercised without a network,
/// a video file, or a model on disk.
private final class ScriptedEngine: TranscriptionEngine, @unchecked Sendable {
    let kind: TranscriptionEngineKind
    let isReady: Bool
    private let answer: EngineResult
    private(set) var calls = 0

    init(_ kind: TranscriptionEngineKind, isReady: Bool = true, answer: EngineResult) {
        self.kind = kind
        self.isReady = isReady
        self.answer = answer
    }

    func transcribe(videoURL: URL, multiSpeaker: Bool) async -> EngineResult {
        calls += 1
        return answer
    }

    static func refusing(_ kind: TranscriptionEngineKind, code: String) -> ScriptedEngine {
        ScriptedEngine(kind, answer: EngineResult(
            srt: nil, name: nil, usage: .zero, model: kind.rawValue,
            latencyMs: 0, attempts: 1, success: false, errorCode: code, fatal: true
        ))
    }

    /// Answers with a title too, so the orchestrator's separate naming call never runs and
    /// the test stays offline.
    static func answering(_ kind: TranscriptionEngineKind) -> ScriptedEngine {
        ScriptedEngine(kind, answer: EngineResult(
            srt: "1\n00:00:00,000 --> 00:00:02,000\nhello\n", name: "A real title",
            usage: .zero, model: kind.rawValue, latencyMs: 0, attempts: 1, success: true
        ))
    }

    static func failing(_ kind: TranscriptionEngineKind, code: String) -> ScriptedEngine {
        ScriptedEngine(kind, answer: EngineResult(
            srt: nil, name: nil, usage: .zero, model: kind.rawValue,
            latencyMs: 0, attempts: 1, success: false, errorCode: code, fatal: false
        ))
    }
}

/// The walk itself: "this engine will not answer for this account" has to become "then ask
/// one that will". Both halves of the contract were covered - the engine emits the code, the
/// orchestrator's set contains it - while the step between them had none: removing the walk
/// entirely passed all 139 tests.
final class EngineFallbackWalkTests: XCTestCase {

    private let video = URL(fileURLWithPath: "/dev/null/never-read.mov")

    private func service(_ engines: [ScriptedEngine], preferring kind: TranscriptionEngineKind) -> AINamingService {
        let proxy = GeminiProxyClient(tokenProvider: { nil })
        return AINamingService(engines: engines, preferring: kind, namingService: NamingService(proxyClient: proxy))
    }

    /// The case the on-device engine exists for: the gate is on, the plan does not include
    /// cloud work, and the model is already downloaded.
    func testAPlanRefusalIsAnsweredByTheOnDeviceEngine() async {
        let cloud = ScriptedEngine.refusing(.cloudGemini, code: "premium_required")
        let local = ScriptedEngine.answering(.localWhisper)
        let result = await service([cloud, local], preferring: .cloudGemini)
            .generateSubtitlesAndName(for: video)
        XCTAssertNotNil(result.srt, "a refused cloud engine left the recording with no transcript")
        XCTAssertEqual(local.calls, 1, "the on-device engine was never asked")
    }

    /// A plan refusal repeats on every cloud engine, so the walk has to keep going rather
    /// than stop at the first alternative that says the same thing.
    func testTheWalkPassesThroughASecondRefusalToReachOneThatAnswers() async {
        let gemini = ScriptedEngine.refusing(.cloudGemini, code: "premium_required")
        let groq = ScriptedEngine.refusing(.cloudGroq, code: "premium_required")
        let local = ScriptedEngine.answering(.localWhisper)
        let result = await service([gemini, groq, local], preferring: .cloudGemini)
            .generateSubtitlesAndName(for: video)
        XCTAssertNotNil(result.srt)
        XCTAssertEqual(groq.calls, 1)
        XCTAssertEqual(local.calls, 1)
    }

    /// A server-side switch is the other half of the set, and it is not fatal: the engine is
    /// off, the others are not.
    func testASwitchedOffEngineIsWalkedPast() async {
        let groq = ScriptedEngine.refusing(.cloudGroq, code: "engine_disabled")
        let gemini = ScriptedEngine.answering(.cloudGemini)
        let result = await service([groq, gemini], preferring: .cloudGroq)
            .generateSubtitlesAndName(for: video)
        XCTAssertNotNil(result.srt)
        XCTAssertEqual(gemini.calls, 1)
    }

    /// A failure ABOUT THE RECORDING must not walk. Asking a second engine to transcribe
    /// something that genuinely could not be transcribed buys a second bill and the same
    /// answer - and on an hour-long recording that is a full re-encode.
    func testAnOrdinaryFailureDoesNotSpendASecondEngine() async {
        let gemini = ScriptedEngine.failing(.cloudGemini, code: "chunks_all_failed")
        let local = ScriptedEngine.answering(.localWhisper)
        let result = await service([gemini, local], preferring: .cloudGemini)
            .generateSubtitlesAndName(for: video)
        XCTAssertNil(result.srt)
        XCTAssertEqual(local.calls, 0, "walked on a failure that was about the recording, not the account")
    }

    /// A refusal that still produced cues is not a refusal worth walking on: the transcript
    /// is already in hand.
    func testAnEngineThatAnsweredIsNeverWalkedPast() async {
        let gemini = ScriptedEngine(.cloudGemini, answer: EngineResult(
            srt: "1\n00:00:00,000 --> 00:00:01,000\npartial\n", name: "Title",
            usage: .zero, model: "gemini", latencyMs: 0, attempts: 1,
            success: true, errorCode: "premium_required"
        ))
        let local = ScriptedEngine.answering(.localWhisper)
        _ = await service([gemini, local], preferring: .cloudGemini).generateSubtitlesAndName(for: video)
        XCTAssertEqual(local.calls, 0, "spent a second engine on a recording that already had a transcript")
    }
}
