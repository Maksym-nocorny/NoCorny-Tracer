import XCTest
@testable import NoCornyTracer

/// Diarization can only label speech that was transcribed in the first place. If the prompt
/// tells the model to keep only the narrator, the second voice is gone before separation ever
/// sees it - and no amount of re-labelling brings it back, because there is nothing to
/// re-label. That is what made a missing argument in one loop a data-loss bug rather than a
/// formatting one.
final class MultiSpeakerPromptTests: XCTestCase {

    func testAskingForEveryoneDoesNotAskForOnlyTheNarrator() {
        let everyone = CloudGeminiEngine.speakerScopeRules(multiSpeaker: true)
        XCTAssertTrue(everyone.contains("EVERY clearly audible person"))
        XCTAssertFalse(everyone.contains("ONLY the primary"),
                       "the multi-speaker prompt still tells the model to drop the other side")
        XCTAssertTrue(everyone.contains("Mac's own audio"),
                      "the call audio is the whole point of the system-audio track")
    }

    func testTheNarratorOnlyPromptIsStillTheDefaultShape() {
        let narrator = CloudGeminiEngine.speakerScopeRules(multiSpeaker: false)
        XCTAssertTrue(narrator.contains("ONLY the primary"))
        XCTAssertFalse(narrator.contains("EVERY clearly audible person"))
    }

    /// Both prompt builders have to carry the flag through. Each of them defaulted it to
    /// false once, which is how it went missing in the first place.
    func testEveryPromptBuilderCarriesTheFlag() {
        let engine = CloudGeminiEngine(
            proxyClient: GeminiProxyClient(tokenProvider: { nil }),
            namingService: NamingService(proxyClient: GeminiProxyClient(tokenProvider: { nil }))
        )
        let combinedAll = engine.combinedPrompt(multiSpeaker: true)
        let combinedOne = engine.combinedPrompt(multiSpeaker: false)
        XCTAssertNotEqual(combinedAll, combinedOne, "combinedPrompt ignores multiSpeaker")
        XCTAssertTrue(combinedAll.contains("EVERY clearly audible person"))

        let chunkAll = engine.chunkTranscriptionPrompt(
            part: 1, of: 4, clipSeconds: 300, glossary: [], multiSpeaker: true
        )
        let chunkOne = engine.chunkTranscriptionPrompt(
            part: 1, of: 4, clipSeconds: 300, glossary: [], multiSpeaker: false
        )
        XCTAssertNotEqual(chunkAll, chunkOne, "chunkTranscriptionPrompt ignores multiSpeaker")
        XCTAssertTrue(chunkAll.contains("EVERY clearly audible person"))
        XCTAssertTrue(chunkOne.contains("ONLY the primary"))
    }

    /// The flag has to reach a LATE chunk as well as an early one. The bug lived in the gap
    /// between the loop that starts the first few and the loop that starts the rest.
    func testTheFlagReachesChunkOneAndChunkTwenty() {
        let engine = CloudGeminiEngine(
            proxyClient: GeminiProxyClient(tokenProvider: { nil }),
            namingService: NamingService(proxyClient: GeminiProxyClient(tokenProvider: { nil }))
        )
        for part in [1, 2, 3, 4, 20] {
            let prompt = engine.chunkTranscriptionPrompt(
                part: part, of: 20, clipSeconds: 300, glossary: [], multiSpeaker: true
            )
            XCTAssertTrue(prompt.contains("EVERY clearly audible person"),
                          "chunk \(part) of 20 was told to keep only the narrator")
        }
    }
}
