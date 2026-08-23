import XCTest
@testable import NoCornyTracer

/// Small decisions that were one inline expression each, and that a mutant could replace
/// with a constant while the whole suite stayed green.
final class ServerAnswerTests: XCTestCase {

    /// The one caller that reads this warns the user their edit did not reach the site, and
    /// the next sync overwrites local transcripts from the server - so "accepted" being
    /// generous means an erased edit with no warning.
    func testOnlyA2xxCountsAsAccepted() {
        XCTAssertTrue(TracerAPIClient.serverAccepted(200))
        XCTAssertTrue(TracerAPIClient.serverAccepted(204))
        XCTAssertFalse(TracerAPIClient.serverAccepted(401))
        XCTAssertFalse(TracerAPIClient.serverAccepted(404))
        XCTAssertFalse(TracerAPIClient.serverAccepted(500))
        XCTAssertFalse(TracerAPIClient.serverAccepted(503))
        XCTAssertFalse(TracerAPIClient.serverAccepted(302), "a redirect is not an acceptance")
    }

    /// An engine switched on with no key on the server answers 503. Without its own code it
    /// reads as an outage: three retries a chunk, a second wave, a second full pass, and no
    /// fallback - a premium user billed several uploads for nothing.
    func testAMissingServerKeyIsARefusalRatherThanAnOutage() {
        let code = ProxyTranscriptionError.engineNotConfigured.code
        XCTAssertEqual(code, "engine_not_configured", "the app and the route have to agree on the spelling")
        XCTAssertFalse(ProxyTranscriptionError.engineNotConfigured.isRetryable,
                       "retrying cannot conjure an environment variable")
        XCTAssertTrue(AINamingService.refusalCodes.contains(code),
                      "the orchestrator would not fall back to an engine that can answer")
    }

    /// Every code the transcription client can raise as an account-level answer has to be one
    /// the orchestrator acts on. This is the join that shipped broken once already, and it is
    /// the join that silently breaks whenever someone adds a case to the enum.
    func testEveryAccountLevelCodeIsOneTheOrchestratorActsOn() {
        let accountLevel: [ProxyTranscriptionError] = [.premiumRequired, .engineDisabled, .engineNotConfigured]
        for error in accountLevel {
            XCTAssertTrue(
                AINamingService.refusalCodes.contains(error.code),
                "\(error.code) is refused by an engine but not walked past by the orchestrator"
            )
            XCTAssertFalse(error.isRetryable, "\(error.code) would be retried against the same engine")
        }
    }

    /// And the reverse: a set entry nobody emits is a dead branch pretending to be coverage.
    func testTheOrchestratorsSetHasNothingSpare() {
        let emitted = Set([
            ProxyTranscriptionError.premiumRequired.code,
            ProxyTranscriptionError.engineDisabled.code,
            ProxyTranscriptionError.engineNotConfigured.code,
        ])
        XCTAssertEqual(AINamingService.refusalCodes, emitted)
    }
}
