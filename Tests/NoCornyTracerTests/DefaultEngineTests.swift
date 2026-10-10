import XCTest
@testable import NoCornyTracer

/// What a Mac that never picked an engine transcribes with, since 4.6.0.
final class DefaultEngineTests: XCTestCase {

    func testAppleSiliconDefaultsToOnDevice() {
        XCTAssertEqual(TranscriptionEngineKind.defaultKind(appleSilicon: true), .localWhisper)
    }

    /// The Core ML packages have no Intel artefacts, so there the default must be an engine
    /// that can actually run.
    func testIntelDefaultsToTheCloud() {
        XCTAssertEqual(TranscriptionEngineKind.defaultKind(appleSilicon: false), .cloudGemini)
    }

    /// The model switch itself, pinned in words: the folder name must be OpenAI's turbo
    /// (`v20240930`), never the `_turbo`-suffixed full large-v3 that shipped before. A
    /// future "tidy-up" that drops the date would quietly ship the 32-layer decoder again.
    func testTheOnDeviceModelIsTheRealTurbo() {
        XCTAssertTrue(LocalWhisperEngine.defaultVariant.contains("v20240930"),
                      "\(LocalWhisperEngine.defaultVariant) is not OpenAI's large-v3-turbo")
        XCTAssertFalse(LocalWhisperEngine.legacyVariants.contains(LocalWhisperEngine.defaultVariant))
        XCTAssertTrue(LocalWhisperEngine.legacyVariants.contains("openai_whisper-large-v3_turbo"),
                      "the full large-v3 folder every 4.5.x Mac has on disk must be known so it gets reclaimed")
    }
}
