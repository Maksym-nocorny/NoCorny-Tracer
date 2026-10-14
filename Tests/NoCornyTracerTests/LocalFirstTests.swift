import XCTest
@testable import NoCornyTracer

/// A stand-in engine with scripted answers and a call counter. A private twin of the ones in
/// the other walk tests, because those are file-private and this file covers a third
/// contract: an on-device failure, not a refusal and not a hand-off.
private final class ScriptedEngine: TranscriptionEngine, @unchecked Sendable {
    let kind: TranscriptionEngineKind
    let isReady: Bool
    private let answers: [EngineResult]
    private(set) var calls = 0

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
        let answer = answers[min(calls, answers.count - 1)]
        calls += 1
        return answer
    }

    static func failing(_ kind: TranscriptionEngineKind, code: String, fatal: Bool = true, isReady: Bool = true) -> ScriptedEngine {
        ScriptedEngine(kind, isReady: isReady, answers: [EngineResult(
            srt: nil, name: nil, usage: .zero, model: kind.rawValue,
            latencyMs: 0, attempts: 1, success: false, errorCode: code, fatal: fatal
        )])
    }

    /// Answers with a title too, so the orchestrator's separate naming call never runs and
    /// the test stays offline.
    static func answering(_ kind: TranscriptionEngineKind, isReady: Bool = true) -> ScriptedEngine {
        ScriptedEngine(kind, isReady: isReady, answers: [EngineResult(
            srt: "1\n00:00:00,000 --> 00:00:02,000\nhello\n", name: "A real title",
            usage: .zero, model: kind.rawValue, latencyMs: 0, attempts: 1, success: true
        )])
    }
}

/// 4.6.1, decision of 14.10.2026: transcribe on this Mac first, the cloud is the fallback
/// path. Two halves: a stored cloud choice moves to on-device once, and a recording the
/// on-device engine fails on is finished by a ready cloud engine.
final class LocalFirstTests: XCTestCase {

    private let video = URL(fileURLWithPath: "/dev/null/never-read.mov")

    private func service(_ engines: [ScriptedEngine], preferring kind: TranscriptionEngineKind) -> AINamingService {
        let proxy = GeminiProxyClient(tokenProvider: { nil })
        return AINamingService(engines: engines, preferring: kind, namingService: NamingService(proxyClient: proxy))
    }

    // MARK: - The one-time move to on-device

    func testAStoredGeminiChoiceMovesToOnDeviceOnce() {
        XCTAssertEqual(
            TranscriptionEngineKind.localFirstMigration(stored: .cloudGemini, alreadyApplied: false, appleSilicon: true),
            .localWhisper
        )
        XCTAssertNil(
            TranscriptionEngineKind.localFirstMigration(stored: .cloudGemini, alreadyApplied: true, appleSilicon: true),
            "a cloud engine picked after the move is a real choice and must stay"
        )
    }

    func testAStoredGroqChoiceMovesToo() {
        XCTAssertEqual(
            TranscriptionEngineKind.localFirstMigration(stored: .cloudGroq, alreadyApplied: false, appleSilicon: true),
            .localWhisper
        )
    }

    func testNothingToMoveWhenOnDeviceOrUnset() {
        XCTAssertNil(TranscriptionEngineKind.localFirstMigration(stored: .localWhisper, alreadyApplied: false, appleSilicon: true))
        XCTAssertNil(TranscriptionEngineKind.localFirstMigration(stored: nil, alreadyApplied: false, appleSilicon: true),
                     "an unset choice already gets the on-device default")
    }

    /// The model has no Intel build, so an Intel Mac keeps the engine that can run.
    func testIntelKeepsTheCloud() {
        XCTAssertNil(TranscriptionEngineKind.localFirstMigration(stored: .cloudGemini, alreadyApplied: false, appleSilicon: false))
    }

    /// Somebody who pressed Remove on the model said no to it; moving them would show
    /// "On-device" with no model and downloads off.
    func testAMacWhoseModelWasRemovedKeepsTheCloud() {
        XCTAssertNil(TranscriptionEngineKind.localFirstMigration(
            stored: .cloudGemini, alreadyApplied: false, appleSilicon: true, modelRemovedByUser: true
        ))
    }

    func testAppStateLeavesARemovedModelUserOnTheCloud() throws {
        try XCTSkipUnless(LocalWhisperEngine.isAvailable, "the move only happens on Apple Silicon")
        let sandbox = SandboxDefaults.make()
        sandbox.set("cloud", forKey: "transcriptionEngine")
        sandbox.set(true, forKey: LocalModelWarmup.autoDownloadOptOutKey)
        XCTAssertEqual(AppState(defaults: sandbox, connectsToTracer: false).transcriptionEngine, .cloudGemini)
        XCTAssertEqual(sandbox.string(forKey: "transcriptionEngine"), "cloud")
    }

    /// The whole path through `AppState.init`: the value it reads, the value it writes back
    /// (didSet does not fire in init), and the flag that stops the move from repeating.
    func testAppStateMovesAStoredGeminiChoiceOnceAndThenRespectsANewOne() throws {
        try XCTSkipUnless(LocalWhisperEngine.isAvailable, "the move only happens on Apple Silicon")
        let sandbox = SandboxDefaults.make()
        sandbox.set("cloud", forKey: "transcriptionEngine")

        let first = AppState(defaults: sandbox, connectsToTracer: false)
        XCTAssertEqual(first.transcriptionEngine, .localWhisper)
        XCTAssertEqual(sandbox.string(forKey: "transcriptionEngine"), "local", "the move must be written back")
        XCTAssertTrue(sandbox.bool(forKey: TranscriptionEngineKind.localFirstMigrationKey))

        // The user picks Gemini again after the move: that choice survives a relaunch.
        sandbox.set("cloud", forKey: "transcriptionEngine")
        let second = AppState(defaults: sandbox, connectsToTracer: false)
        XCTAssertEqual(second.transcriptionEngine, .cloudGemini)
    }

    func testAFreshMacIsMarkedSoALaterGeminiPickStays() throws {
        try XCTSkipUnless(LocalWhisperEngine.isAvailable, "the default is on-device only on Apple Silicon")
        let sandbox = SandboxDefaults.make()
        let fresh = AppState(defaults: sandbox, connectsToTracer: false)
        XCTAssertEqual(fresh.transcriptionEngine, .localWhisper)
        XCTAssertTrue(sandbox.bool(forKey: TranscriptionEngineKind.localFirstMigrationKey))

        sandbox.set("cloud", forKey: "transcriptionEngine")
        XCTAssertEqual(AppState(defaults: sandbox, connectsToTracer: false).transcriptionEngine, .cloudGemini)
    }

    // MARK: - The cloud as the on-device engine's backup

    /// Every code in the set walks to the cloud, and the cloud's transcript is billed to it.
    func testEveryOnDeviceFailureIsFinishedByTheCloud() async {
        for code in AINamingService.onDeviceFailureCodes.sorted() {
            let local = ScriptedEngine.failing(.localWhisper, code: code)
            let gemini = ScriptedEngine.answering(.cloudGemini)
            let result = await service([local, gemini], preferring: .localWhisper)
                .generateSubtitlesAndName(for: video)
            XCTAssertNotNil(result.srt, "\(code): the cloud did not stand in")
            XCTAssertEqual(result.model, "cloud", "\(code): the transcript must be billed to the engine that produced it")
            XCTAssertEqual(local.calls, 1, "\(code): the on-device engine must not be asked twice")
            XCTAssertEqual(gemini.calls, 1, "\(code)")
        }
    }

    /// A cancel is somebody stopping the run; a failed extraction is about the recording,
    /// and the cloud reads the same extracted audio. Neither is a reason to upload it.
    func testACancelOrABrokenRecordingDoesNotGoToTheCloud() async {
        for code in ["cancelled", "audio_extraction_failed"] {
            let local = ScriptedEngine.failing(.localWhisper, code: code)
            let gemini = ScriptedEngine.answering(.cloudGemini)
            let result = await service([local, gemini], preferring: .localWhisper)
                .generateSubtitlesAndName(for: video)
            XCTAssertNil(result.srt, code)
            XCTAssertEqual(gemini.calls, 0, "\(code) must not walk to the cloud")
        }
    }

    /// Signed out: no cloud engine is ready, so the on-device failure stands as it was.
    func testWithNoCloudReadyTheOnDeviceFailureStands() async {
        let local = ScriptedEngine.failing(.localWhisper, code: "local_model_load_failed")
        let gemini = ScriptedEngine.answering(.cloudGemini, isReady: false)
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNil(result.srt)
        XCTAssertEqual(result.errorCode, "local_model_load_failed")
        XCTAssertEqual(gemini.calls, 0)
    }

    /// A cold compile that timed out is retryable on this Mac. If the cloud then refuses on
    /// plan grounds (fatal), the recording must still get its second pass, as in 4.6.0.
    func testACloudRefusalDoesNotCancelTheOnDeviceSecondPass() async {
        let local = ScriptedEngine.failing(.localWhisper, code: "local_model_compiling", fatal: false)
        let gemini = ScriptedEngine.failing(.cloudGemini, code: "premium_required", fatal: true)
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNil(result.srt)
        XCTAssertFalse(result.fatal, "the on-device run could still succeed on the second pass")
        XCTAssertEqual(gemini.calls, 1)
    }

    /// A fatal on-device failure and a fatal cloud answer leave nothing worth a second pass.
    func testBothFatalStaysFatal() async {
        let local = ScriptedEngine.failing(.localWhisper, code: "local_model_missing", fatal: true)
        let gemini = ScriptedEngine.failing(.cloudGemini, code: "premium_required", fatal: true)
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertTrue(result.fatal)
        XCTAssertFalse(result.retryForTranscript)
    }

    /// The production line-up: after Gemini refuses, the walk asks the parked Groq engine,
    /// which answers "disabled" WITHOUT marking it fatal. A refusal repeats in ten seconds as
    /// surely as a fatal error does, so it must not buy a second full on-device decode.
    func testAParkedEngineRefusingDoesNotBuyASecondDecode() async {
        let local = ScriptedEngine.failing(.localWhisper, code: "local_empty_transcript", fatal: true)
        let gemini = ScriptedEngine.failing(.cloudGemini, code: "premium_required", fatal: true)
        let groq = ScriptedEngine.failing(.cloudGroq, code: "engine_disabled", fatal: false)
        let result = await service([local, gemini, groq], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNil(result.srt)
        XCTAssertEqual(groq.calls, 1)
        XCTAssertTrue(result.fatal, "both sides failed for good: no second pass")
    }

    /// A cloud failure that may clear (a network error) is worth the second pass even after a
    /// fatal on-device failure: the pass walks to the cloud again.
    func testARetryableCloudFailureKeepsTheSecondPass() async {
        let local = ScriptedEngine.failing(.localWhisper, code: "local_model_missing", fatal: true)
        let gemini = ScriptedEngine.failing(.cloudGemini, code: "network_error", fatal: false)
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertFalse(result.fatal)
    }

    /// The cloud titled the recording from its frames while every transcript chunk failed.
    /// The caller's second pass skips any run that has a title, so this one has to say that
    /// the transcript is still worth asking for.
    func testATitleWithoutATranscriptStillAsksForTheSecondPass() async {
        let local = ScriptedEngine.failing(.localWhisper, code: "local_model_compiling", fatal: false)
        let gemini = ScriptedEngine(.cloudGemini, answers: [EngineResult(
            srt: nil, name: "Titled from frames", usage: .zero, model: "cloud",
            latencyMs: 0, attempts: 1, success: true, errorCode: "chunks_all_failed", fatal: true
        )])
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertNil(result.srt)
        XCTAssertEqual(result.name, "Titled from frames")
        XCTAssertFalse(result.fatal)
        XCTAssertTrue(result.retryForTranscript)
        XCTAssertFalse(result.success, "a fallback title must not close the row as done without subtitles")
    }

    /// The cloud heard nobody (success, no error, no cues): that is an answer, not a failure,
    /// and a second pass would decode the same audio again and pay for the same call.
    func testAnHonestNoSpeechFromTheCloudEndsTheRun() async {
        let local = ScriptedEngine.failing(.localWhisper, code: "local_empty_transcript", fatal: true)
        let gemini = ScriptedEngine(.cloudGemini, answers: [EngineResult(
            srt: nil, name: "Music only", usage: .zero, model: "cloud",
            latencyMs: 0, attempts: 1, success: true, errorCode: nil, fatal: false
        )])
        let result = await service([local, gemini], preferring: .localWhisper)
            .generateSubtitlesAndName(for: video)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.fatal, "no second pass after an honest answer")
        XCTAssertFalse(result.retryForTranscript)
    }

    /// The flag belongs to the on-device walk only: a cloud-first run that got a title and no
    /// transcript behaves exactly as before 4.6.1.
    func testACloudFirstRunNeverAsksForTheTranscriptRetry() async {
        let gemini = ScriptedEngine(.cloudGemini, answers: [EngineResult(
            srt: nil, name: "Titled from frames", usage: .zero, model: "cloud",
            latencyMs: 0, attempts: 1, success: true, errorCode: "chunks_all_failed", fatal: true
        )])
        let local = ScriptedEngine.answering(.localWhisper)
        let result = await service([gemini, local], preferring: .cloudGemini)
            .generateSubtitlesAndName(for: video)
        XCTAssertFalse(result.retryForTranscript)
        XCTAssertTrue(result.fatal)
        XCTAssertEqual(local.calls, 0)
    }

    /// The on-device engine reached at the end of a cloud refusal walk is the last resort:
    /// when it fails too, the walk ends there rather than going back to a cloud engine that
    /// already declined.
    func testAnOnDeviceFailureAtTheEndOfARefusalWalkDoesNotLoopBack() async {
        let gemini = ScriptedEngine.failing(.cloudGemini, code: "premium_required")
        let local = ScriptedEngine.failing(.localWhisper, code: "local_transcribe_failed")
        let result = await service([gemini, local], preferring: .cloudGemini)
            .generateSubtitlesAndName(for: video)
        XCTAssertNil(result.srt)
        XCTAssertEqual(gemini.calls, 1)
        XCTAssertEqual(local.calls, 1)
    }

    // MARK: - The contract between the engine and the walk

    /// The set and the engine are one contract, like the refusal codes: every code in the set
    /// has to be one `LocalWhisperEngine` can actually emit, or the walk waits for a failure
    /// that never arrives under that name.
    func testEveryOnDeviceFailureCodeIsOneTheEngineEmits() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/NoCornyTracerTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/NoCornyTracer/Services/Transcription/LocalWhisperEngine.swift"),
            encoding: .utf8)
        for code in AINamingService.onDeviceFailureCodes {
            XCTAssertTrue(source.contains("\"\(code)\""), "\(code) is not emitted by LocalWhisperEngine")
        }
    }

    func testTheThreeWalkSetsDoNotOverlap() {
        XCTAssertTrue(AINamingService.onDeviceFailureCodes.isDisjoint(with: AINamingService.refusalCodes))
        XCTAssertTrue(AINamingService.onDeviceFailureCodes.isDisjoint(with: AINamingService.handoffCodes),
                      "too slow is a hand-off with its own re-run rule, not a failure")
        XCTAssertFalse(AINamingService.onDeviceFailureCodes.contains("cancelled"))
        XCTAssertFalse(AINamingService.onDeviceFailureCodes.contains("audio_extraction_failed"))
    }
}
