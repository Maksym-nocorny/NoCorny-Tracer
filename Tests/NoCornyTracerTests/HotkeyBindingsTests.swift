import XCTest
import Carbon.HIToolbox
@testable import NoCornyTracer

/// The Carbon migration must keep the exact combos of the NSEvent implementation it
/// replaced: ⌥⇧R (key code 15) start/stop, ⌥⇧P (35) pause, ⌥⇧X (7) abort.
final class HotkeyBindingsTests: XCTestCase {

    func testSameKeyCodesAsTheMonitorImplementation() {
        func keyCode(for action: HotkeyManager.HotkeyAction) -> UInt32? {
            HotkeyManager.bindings.first { $0.action == action }?.keyCode
        }
        XCTAssertEqual(keyCode(for: .toggleRecording), 15, "⌥⇧R")
        XCTAssertEqual(keyCode(for: .togglePause), 35, "⌥⇧P")
        XCTAssertEqual(keyCode(for: .abortRecording), 7, "⌥⇧X")
    }

    func testEveryActionHasExactlyOneBinding() {
        for action in HotkeyManager.HotkeyAction.allCases {
            XCTAssertEqual(HotkeyManager.bindings.filter { $0.action == action }.count, 1)
        }
        XCTAssertEqual(Set(HotkeyManager.bindings.map(\.id)).count, HotkeyManager.bindings.count,
                       "Carbon hot key ids must be unique")
    }

    func testHotKeyIDsMapBackToTheirActions() {
        for binding in HotkeyManager.bindings {
            XCTAssertEqual(HotkeyManager.action(forHotKeyID: binding.id), binding.action)
        }
    }

    func testUnknownIDMapsToNothing() {
        XCTAssertNil(HotkeyManager.action(forHotKeyID: 99))
    }
}
