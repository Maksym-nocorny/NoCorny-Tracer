import XCTest
import AppKit
@testable import NoCornyTracer

/// The capture-visibility policy (round 6, package 4): "Show Tracer in screen
/// captures" flips every registered panel between hidden-from-capture (.none)
/// and capturable (.readOnly), applies the current state to panels created
/// later, and persists through AppState under `PanelCaptureRegistry.defaultsKey`.
final class PanelCaptureRegistryTests: XCTestCase {

    func testSharingTypeMapping() {
        XCTAssertEqual(PanelCaptureRegistry.sharingType(capturable: true), .readOnly,
                       "capturable = visible to captures, still not remote-controllable")
        XCTAssertEqual(PanelCaptureRegistry.sharingType(capturable: false), .none)
    }

    @MainActor
    func testRegistrationAppliesTheCurrentStateAndFlipsFollow() {
        defer { PanelCaptureRegistry.setCapturable(false) }
        PanelCaptureRegistry.setCapturable(false)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        PanelCaptureRegistry.register(window)
        XCTAssertEqual(window.sharingType, .none, "registration applies the default OFF")

        PanelCaptureRegistry.setCapturable(true)
        XCTAssertEqual(window.sharingType, .readOnly, "the flip reaches already-registered panels")

        // A panel created while the switch is ON comes up capturable too.
        let late = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        late.isReleasedWhenClosed = false
        PanelCaptureRegistry.register(late)
        XCTAssertEqual(late.sharingType, .readOnly)

        PanelCaptureRegistry.setCapturable(false)
        XCTAssertEqual(window.sharingType, .none)
        XCTAssertEqual(late.sharingType, .none)
    }

    @MainActor
    func testAppStateOwnsThePersistenceAndDrivesTheRegistry() {
        defer { PanelCaptureRegistry.setCapturable(false) }

        let defaults = SandboxDefaults.make()
        let state = AppState(defaults: defaults, connectsToTracer: false)
        XCTAssertFalse(state.panelsCapturable, "ships OFF — panels stay out of captures")

        state.panelsCapturable = true
        XCTAssertTrue(defaults.bool(forKey: PanelCaptureRegistry.defaultsKey),
                      "the toggle persists under the registry's key")
        XCTAssertTrue(PanelCaptureRegistry.isCapturable, "and reaches the registry")

        // A second launch against the same defaults restores the choice.
        let relaunched = AppState(defaults: defaults, connectsToTracer: false)
        XCTAssertTrue(relaunched.panelsCapturable)
        XCTAssertTrue(PanelCaptureRegistry.isCapturable,
                      "launch applies the persisted value to the registry (didSet is silent in init)")
    }
}
