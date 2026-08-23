import XCTest
@testable import NoCornyTracer

/// The wiring itself: that init actually subscribes the manager hooks. Every decision those
/// hooks make is a tested pure function, but the assignment lines in init were pinned by
/// nothing - remove one and the suite stayed green while the take went in the bin.
final class HookWiringTests: XCTestCase {

    func testInitSubscribesEveryManagerHook() {
        let sandbox = UserDefaults(suiteName: "hook-wiring-\(UUID().uuidString)")!
        defer { sandbox.removePersistentDomain(forName: sandbox.description) }
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        let state = AppState(defaults: sandbox, connectsToTracer: false)

        XCTAssertNotNil(state.recordingManager.onInterrupted,
            "nothing hears the screen stream die - the finalised take goes in the bin")
        XCTAssertNotNil(state.recordingManager.onWriterFailed,
            "a dead writer keeps 'recording' while dropping every frame")
        XCTAssertNotNil(state.recordingManager.audioCaptureManager.onInputDeviceLost,
            "the user never learns the recording lost its voice track")
        XCTAssertNotNil(state.recordingManager.audioCaptureManager.onEnvironmentNoisy)
    }

    /// The seam has to cover the account as well as the settings. Gating only AppState's own
    /// sync left the API client's initialiser firing its launch refresh, so a signed-in
    /// developer running this suite made a live request per constructed AppState and wrote
    /// the reply into their real defaults.
    func testABuiltStateDoesNotPhoneHome() {
        let sandbox = UserDefaults(suiteName: "no-network-\(UUID().uuidString)")!
        defer { sandbox.removePersistentDomain(forName: sandbox.description) }
        let previousShared = AppState.shared
        defer { AppState.shared = previousShared }

        let state = AppState(defaults: sandbox, connectsToTracer: false)
        XCTAssertFalse(state.tracerAPIClient.didScheduleLaunchRefresh,
                       "the client still phoned home, and wrote the reply into the real defaults")
    }
}
