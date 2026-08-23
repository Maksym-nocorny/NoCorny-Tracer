import XCTest
@testable import NoCornyTracer

/// The join between "the server refused this account" and "ask a different engine".
///
/// Both halves existed and neither met: the proxy answered 403 `premium_required`, the
/// orchestrator matched `errorCode` against an exact set - and the engine in between put a
/// stringified `serverError(status: 403, body: ...)` into that field, which matches nothing.
/// So the fallback to the on-device model, the one thing that makes a free plan usable,
/// was dead for the DEFAULT engine and would only have shown it on the day the gate was
/// switched on, months after release.
final class EngineRefusalCodeTests: XCTestCase {

    private func serverError(_ status: Int, _ body: String) -> ProxyError {
        .serverError(status: status, body: body)
    }

    /// Exactly what `/api/gemini/proxy` sends when the plan does not include cloud work.
    func testTheProxysPremiumRefusalIsNamedByItsCode() {
        let error = serverError(403, #"{"error":"Cloud transcription is a premium feature","code":"premium_required"}"#)
        XCTAssertEqual(accountRefusalCode(error), "premium_required")
    }

    /// And what `/api/groq/transcribe` sends when an admin switches the engine off.
    func testAServerSideSwitchIsNamedByItsCode() {
        let error = serverError(503, #"{"error":"The Groq engine is currently disabled","code":"engine_disabled"}"#)
        XCTAssertEqual(accountRefusalCode(error), "engine_disabled")
    }

    /// The assertion that actually protects the feature: whatever the engine emits has to be
    /// a member of the set the orchestrator walks engines on. Testing the parser alone would
    /// pass happily while the two halves drifted apart.
    func testEveryRefusalCodeIsOneTheOrchestratorActsOn() {
        let refusals = [
            serverError(403, #"{"code":"premium_required"}"#),
            serverError(503, #"{"code":"engine_disabled"}"#),
        ]
        for error in refusals {
            let code = accountRefusalCode(error)
            XCTAssertNotNil(code, "a refusal produced no code at all")
            XCTAssertTrue(
                AINamingService.refusalCodes.contains(code ?? ""),
                "engine emits \(code ?? "nil"), which the orchestrator does not fall back on"
            )
        }
    }

    /// A failure about the REQUEST must not read as a plan refusal: falling back to another
    /// engine would just buy the same rejection a second time.
    func testAnOrdinaryFailureIsNotMistakenForARefusal() {
        XCTAssertNil(accountRefusalCode(serverError(400, #"{"code":"bad_request"}"#)))
        XCTAssertNil(accountRefusalCode(serverError(500, #"{"code":"premium_required"}"#)),
                     "a 500 is not an account decision, whatever body it carries")
        XCTAssertNil(accountRefusalCode(serverError(403, "Forbidden")))
        XCTAssertNil(accountRefusalCode(ProxyError.payloadTooLarge(bytes: 9_000_000)))
        XCTAssertNil(accountRefusalCode(ProxyError.blocked(reason: "SAFETY")))
        XCTAssertNil(accountRefusalCode(URLError(.timedOut)))
    }

    /// The code is read from the documented field, not found anywhere in the body - an error
    /// MESSAGE that quotes the phrase is not the machine's answer.
    func testThePhraseInAMessageIsNotACode() {
        let error = serverError(403, #"{"error":"premium_required is not why: your token expired","code":"token_expired"}"#)
        XCTAssertNil(accountRefusalCode(error))
    }

    // MARK: - The engine's own mapping, not just the parser's

    /// Link two of three: the parser can be perfect and the fallback still dead if the engine
    /// does not put the code it produces into the field the orchestrator reads. That is
    /// precisely what shipped.
    func testTheEngineCarriesARefusalThroughAsItsErrorCode() {
        let refused = ProxyError.serverError(status: 403, body: #"{"code":"premium_required"}"#)
        XCTAssertEqual(CloudGeminiEngine.failureCode(for: refused), "premium_required")
        XCTAssertTrue(AINamingService.refusalCodes.contains(CloudGeminiEngine.failureCode(for: refused)))
    }

    func testTheEngineStillDescribesAnOrdinaryFailureForHumans() {
        let code = CloudGeminiEngine.failureCode(for: ProxyError.blocked(reason: "SAFETY"))
        XCTAssertTrue(code.contains("SAFETY"), "lost the diagnosis: \(code)")
        XCTAssertFalse(AINamingService.refusalCodes.contains(code), "a model refusal must not trigger engine fallback")
    }

    /// A chunked run must not bury the refusal in a generic verdict: an aggregate the
    /// orchestrator cannot act on is the same as no aggregate at all.
    func testARefusedChunkDecidesTheWholeRun() {
        var refused = ChunkResult(index: 0, status: .failed)
        refused.errorCode = "premium_required"
        var timedOut = ChunkResult(index: 1, status: .failed)
        timedOut.errorCode = "The operation couldn’t be completed. (NSURLErrorDomain error -1001.)"
        XCTAssertEqual(CloudGeminiEngine.refusalAmong([timedOut, refused]), "premium_required")
        XCTAssertEqual(CloudGeminiEngine.refusalAmong([refused, timedOut]), "premium_required",
                       "order of chunks must not change the verdict")
    }

    /// A plan refusal repeats on every cloud engine; a switched-off engine says nothing about
    /// the others. When both appear, the one that explains more wins.
    func testAPlanRefusalOutranksASwitchedOffEngine() {
        var premium = ChunkResult(index: 0, status: .failed); premium.errorCode = "premium_required"
        var disabled = ChunkResult(index: 1, status: .failed); disabled.errorCode = "engine_disabled"
        XCTAssertEqual(CloudGeminiEngine.refusalAmong([disabled, premium]), "premium_required")
    }

    func testChunksThatMerelyFailedAreNotARefusal() {
        var a = ChunkResult(index: 0, status: .failed); a.errorCode = "chunk_timestamps_not_clip_local"
        var b = ChunkResult(index: 1, status: .failed); b.errorCode = "serverError(status: 500, body: \"upstream\")"
        XCTAssertNil(CloudGeminiEngine.refusalAmong([a, b]))
        XCTAssertNil(CloudGeminiEngine.refusalAmong([]))
    }
}
