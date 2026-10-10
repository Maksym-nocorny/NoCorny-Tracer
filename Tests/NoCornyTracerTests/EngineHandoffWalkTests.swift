import XCTest
@testable import NoCornyTracer

/// A stand-in engine with a scripted answer and a call counter. A private twin of the one in
/// EngineFallbackWalkTests, because that one is file-private and these tests are about a
/// different contract: a hand-off, not a refusal.
private final class ScriptedEngine: TranscriptionEngine, @unchecked Sendable {
    let kind: TranscriptionEngineKind
    let isReady: Bool
    /// One answer per call, the last one repeating; so an engine can give up first and
    /// answer when asked again.
    private let answers: [EngineResult]
    private(set) var calls = 0
    private(set) var sawRescueDisabled: [Bool] = []

    convenience init(_ kind: TranscriptionEngineKind, isReady: Bool = true, answer: EngineResult) {
        self.init(kind, isReady: isReady, answers: [answer])
    }

    init(_ kind: TranscriptionEngineKind, isReady: Bool = true, answers: [EngineResult]) {
        self.kind = kind
        self.isReady = isReady
        self.answers = answers
    }

    func transcribe(
        videoURL: URL,
        multiSpeaker: Bool,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async -> EngineResult {
        sawRescueDisabled.append(LocalWhisperEngine.rescueDisabled)
        let answer = answers[min(calls, answers.count - 1)]
        calls += 1
        return answer
    }

    static func tooSlowThenAnswering(_ kind: TranscriptionEngineKind = .localWhisper) -> ScriptedEngine {
        ScriptedEngine(kind, answers: [tooSlow(kind).answers[0], answering(kind).answers[0]])
    }

    static func tooSlow(_ kind: TranscriptionEngineKind = .localWhisper) -> ScriptedEngine {
        ScriptedEngine(kind, answer: EngineResult(
            srt: nil, name: nil, usage: .zero, model: kind.rawValue,
            latencyMs: 0, attempts: 1, success: false, errorCode: LocalWhisperEngine.tooSlowCode, fatal: true
        ))
    }

    static func refusing(_ kind: TranscriptionEngineKind, code: String) -> ScriptedEngine {
        ScriptedEngine(kind, answer: EngineResult(
            srt: nil, name: nil, usage: .zero, model: kind.rawValue,
            latencyMs: 0, attempts: 1, success: false, errorCode: code, fatal: true
        ))
    }

    static func failing(_ kind: TranscriptionEngineKind, code: String) -> ScriptedEngine {
        ScriptedEngine(kind, answer: EngineResult(
            srt: nil, name: nil, usage: .zero, model: kind.rawValue,
            latencyMs: 0, attempts: 1, success: false, errorCode: code, fatal: false
        ))
    }

    static func answering(_ kind: TranscriptionEngineKind) -> ScriptedEngine {
        ScriptedEngine(kind, answer: EngineResult(
            srt: "1\n00:00:00,000 --> 00:00:02,000\nhello\n", name: "A real title",
            usage: .zero, model: kind.rawValue, latencyMs: 0, attempts: 1, success: true
        ))
    }
}

/// The on-device engine gives a recording up when this Mac decodes it slower than real time
/// and a cloud engine is ready (`SlowDecodeProbe`). The orchestrator has to turn that into a
/// cloud transcript, the same way it turns a plan refusal into an on-device one.
final class EngineHandoffWalkTests: XCTestCase {

    private let video = URL(fileURLWithPath: "/dev/null/never-read.mov")

    private func service(_ engines: [ScriptedEngine], preferring kind: TranscriptionEngineKind) -> AINamingService {
        let proxy = GeminiProxyClient(tokenProvider: { nil })
        return AINamingService(engines: engines, preferring: kind, namingService: NamingService(proxyClient: proxy))
    }

    func testATooSlowOnDeviceRunIsFinishedByTheCloud() async {
        let local = ScriptedEngine.tooSlow()
        let gemini = ScriptedEngine.answering(.cloudGemini)
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNotNil(result.srt, "a handed-off recording ended with no transcript")
        XCTAssertEqual(result.model, "cloud", "the transcript must be billed to the engine that produced it")
        XCTAssertEqual(local.calls, 1)
        XCTAssertEqual(gemini.calls, 1)
    }

    /// The hand-off walks like a refusal: if the first cloud engine declines on plan grounds,
    /// the next one is asked rather than the recording being dropped.
    func testAHandoffWalksPastACloudRefusalToTheNextCloudEngine() async {
        let local = ScriptedEngine.tooSlow()
        let gemini = ScriptedEngine.refusing(.cloudGemini, code: "premium_required")
        let groq = ScriptedEngine.answering(.cloudGroq)
        let result = await service([local, gemini, groq], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNotNil(result.srt)
        XCTAssertEqual(groq.calls, 1)
    }

    /// The walk itself never comes back to the engine that gave up: the only second call it
    /// gets is the deliberate re-run with the probe off, after every cloud engine declined.
    func testTheWalkDoesNotReturnToTheEngineThatGaveUp() async {
        let local = ScriptedEngine.tooSlow()
        let gemini = ScriptedEngine.refusing(.cloudGemini, code: "premium_required")
        let groq = ScriptedEngine.refusing(.cloudGroq, code: "premium_required")
        let result = await service([local, gemini, groq], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNil(result.srt)
        XCTAssertEqual(gemini.calls, 1)
        XCTAssertEqual(groq.calls, 1)
        XCTAssertEqual(local.calls, 2, "exactly the hand-off and the probe-off re-run, nothing in between")
        XCTAssertEqual(local.sawRescueDisabled, [false, true])
    }

    /// Signed in but offline, or the plan refuses: the cloud takes the hand-off and produces
    /// nothing. 4.5.5 would have given a slow transcript on this Mac; so must 4.6.0. The
    /// re-run is told to keep its probe quiet, or it would hand off again three minutes in.
    func testAHandoffTheCloudCannotFinishComesBackOnDeviceWithTheProbeOff() async {
        let local = ScriptedEngine.tooSlowThenAnswering()
        let gemini = ScriptedEngine.failing(.cloudGemini, code: "chunks_all_failed")
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNotNil(result.srt, "a recording the cloud dropped ended with no transcript")
        XCTAssertEqual(result.model, "local")
        XCTAssertEqual(local.calls, 2)
        XCTAssertEqual(gemini.calls, 1)
        XCTAssertEqual(local.sawRescueDisabled, [false, true], "the re-run must decode to the end without handing off again")
    }

    /// The code is part of the contract between the engine and the walk, like the refusal
    /// codes: an engine emitting it and a set containing it have to agree on the spelling.
    func testTheHandoffCodeIsTheOneTheEngineEmits() {
        XCTAssertTrue(AINamingService.handoffCodes.contains(LocalWhisperEngine.tooSlowCode))
        XCTAssertFalse(AINamingService.refusalCodes.contains(LocalWhisperEngine.tooSlowCode),
                       "a hand-off is not a refusal: it says nothing about the account")
    }
}
