import XCTest
@testable import NoCornyTracer

/// `/api/tokens/me` has always said which cloud engines the app may offer, and the app has
/// never read it. The picker showed "Cloud (Groq) - faster than Gemini" to everyone while
/// the server had that engine switched off: choosing it uploaded a chunk, collected a 503,
/// and transcribed on Gemini anyway. Recoverable, and still a choice that does not exist.
final class CloudEngineAvailabilityTests: XCTestCase {

    private func entitlements(_ engines: [String]?) -> TracerAPIClient.Entitlements {
        var e = TracerAPIClient.Entitlements()
        e.cloudEngines = engines
        return e
    }

    /// Today's production answer: Gemini on, Groq behind a flag that is off.
    func testAnEngineTheServerDoesNotListIsNotOffered() {
        let e = entitlements(["gemini"])
        XCTAssertTrue(e.offersCloudEngine(.cloudGemini))
        XCTAssertFalse(e.offersCloudEngine(.cloudGroq))
    }

    func testFlippingTheFlagOnOffersIt() {
        let e = entitlements(["gemini", "groq"])
        XCTAssertTrue(e.offersCloudEngine(.cloudGroq))
    }

    /// The on-device engine never asks anyone for permission, so no server list can withdraw
    /// it. It is the fallback the whole premium design leans on.
    func testTheOnDeviceEngineIsNeverWithdrawnByTheServer() {
        XCTAssertTrue(entitlements([]).offersCloudEngine(.localWhisper))
        XCTAssertTrue(entitlements(["gemini"]).offersCloudEngine(.localWhisper))
    }

    /// Silence stays permissive, matching every other entitlement here: the server enforces
    /// anyway, so guessing "allowed" costs a clear refusal while guessing "denied" locks
    /// someone out of what they are paying for. A rollback must not disable the app.
    func testASilentServerWithdrawsNothing() {
        let e = entitlements(nil)
        XCTAssertTrue(e.offersCloudEngine(.cloudGemini))
        XCTAssertTrue(e.offersCloudEngine(.cloudGroq))
    }

    /// The list is keyed on the server's names, not on the enum's raw values - `cloudGemini`
    /// persists as "cloud" for historical reasons, and matching on that would withdraw
    /// Gemini from everyone.
    func testTheNamesMatchWhatTheServerActuallySends() {
        XCTAssertEqual(TranscriptionEngineKind.cloudGemini.serverName, "gemini")
        XCTAssertEqual(TranscriptionEngineKind.cloudGroq.serverName, "groq")
        XCTAssertNil(TranscriptionEngineKind.localWhisper.serverName)
        XCTAssertNotEqual(TranscriptionEngineKind.cloudGemini.serverName,
                          TranscriptionEngineKind.cloudGemini.rawValue,
                          "if these ever coincide, delete serverName rather than letting it rot")
    }

    /// A kill switch has to actually kill. An empty list is the server saying "no cloud
    /// engines", and reading it as "the server said nothing" would turn the switch into a
    /// no-op exactly when someone reaches for it.
    func testAnEmptyListWithdrawsEveryCloudEngine() {
        let e = entitlements([])
        XCTAssertFalse(e.offersCloudEngine(.cloudGemini))
        XCTAssertFalse(e.offersCloudEngine(.cloudGroq))
        XCTAssertTrue(e.offersCloudEngine(.localWhisper), "the on-device engine is not the server's to withdraw")
    }
}
