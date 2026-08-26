import XCTest
import CoreGraphics
@testable import NoCornyTracer

/// CaptureSelection is the "one-click next recording" memory (phase 6a): the picked
/// window / area persists as JSON and is checked for liveness at start. These tests pin
/// the persistence roundtrip and the liveness rules — in particular that a selection
/// whose window died is NOT satisfiable, which is what sends the user back to the picker
/// instead of silently recording the whole screen.
final class CaptureSelectionTests: XCTestCase {

    private func fullSelection() -> CaptureSelection {
        var selection = CaptureSelection()
        selection.mode = .window
        selection.windowID = 4242
        selection.windowTitle = "Safari - Apple"
        selection.areaRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        selection.areaDisplayID = 69733382
        return selection
    }

    // MARK: - Persistence

    func testRoundtripsThroughUserDefaults() {
        let defaults = SandboxDefaults.make()
        let selection = fullSelection()
        selection.save(to: defaults)
        XCTAssertEqual(CaptureSelection.load(from: defaults), selection)
    }

    func testLoadReturnsNilWhenNothingWasEverSaved() {
        XCTAssertNil(CaptureSelection.load(from: SandboxDefaults.make()))
    }

    func testCorruptPayloadLoadsAsNilNotACrash() {
        let defaults = SandboxDefaults.make()
        defaults.set(Data("not json at all".utf8), forKey: CaptureSelection.defaultsKey)
        XCTAssertNil(CaptureSelection.load(from: defaults))
    }

    func testSavingTwiceKeepsTheLatestChoice() {
        let defaults = SandboxDefaults.make()
        fullSelection().save(to: defaults)
        var second = fullSelection()
        second.windowID = 7
        second.windowTitle = "Figma"
        second.save(to: defaults)
        XCTAssertEqual(CaptureSelection.load(from: defaults)?.windowID, 7)
        XCTAssertEqual(CaptureSelection.load(from: defaults)?.windowTitle, "Figma")
    }

    // MARK: - Liveness

    func testEntireScreenIsAlwaysSatisfiable() {
        let selection = CaptureSelection()
        XCTAssertTrue(selection.isSatisfiable(liveWindowIDs: [], liveDisplayIDs: []))
    }

    func testWindowSelectionLivesWhileItsWindowIsOnScreen() {
        let selection = fullSelection()
        XCTAssertTrue(selection.isSatisfiable(liveWindowIDs: [4242, 1], liveDisplayIDs: []))
    }

    func testWindowSelectionDiesWithItsWindow() {
        let selection = fullSelection()
        XCTAssertFalse(selection.isSatisfiable(liveWindowIDs: [1, 2, 3], liveDisplayIDs: []),
                       "a closed window must send the user back to the picker, not silently record something else")
    }

    func testWindowModeWithoutAWindowIDIsNotSatisfiable() {
        var selection = CaptureSelection()
        selection.mode = .window
        XCTAssertFalse(selection.isSatisfiable(liveWindowIDs: [1, 2], liveDisplayIDs: []))
    }

    func testAreaSelectionDiesWithItsDisplay() {
        var selection = fullSelection()
        selection.mode = .selectedArea
        XCTAssertTrue(selection.isSatisfiable(liveWindowIDs: [], liveDisplayIDs: [69733382]))
        XCTAssertFalse(selection.isSatisfiable(liveWindowIDs: [], liveDisplayIDs: [1]),
                       "the rect is meaningless on another display")
    }

    func testAreaModeWithoutARectIsNotSatisfiable() {
        var selection = CaptureSelection()
        selection.mode = .selectedArea
        XCTAssertFalse(selection.isSatisfiable(liveWindowIDs: [], liveDisplayIDs: [1]))
    }

    func testAreaWithoutARememberedDisplayRidesTheCurrentOne() {
        var selection = CaptureSelection()
        selection.mode = .selectedArea
        selection.areaRect = CGRect(x: 0, y: 0, width: 100, height: 100)
        selection.areaDisplayID = nil
        XCTAssertTrue(selection.isSatisfiable(liveWindowIDs: [], liveDisplayIDs: []),
                      "a rect with no display ID falls back to the recorder's selected display")
    }

    // MARK: - Retired modes (round 6)

    func testSelectedAreaIsRetiredAndHiddenFromTheMenu() {
        // Round 6 removed Selected Area from the UI («дуже багована фіча»). The case
        // must keep decoding old persisted payloads but never resurface as a menu row.
        XCTAssertFalse(CaptureMode.selectedArea.isAvailable)
        XCTAssertEqual(CaptureMode.menuCases, [.entireScreen, .window])
    }

    func testPersistedAreaSelectionMigratesToEntireScreen() {
        var old = CaptureSelection()
        old.mode = .selectedArea
        old.areaRect = CGRect(x: 10, y: 20, width: 300, height: 200)
        old.areaDisplayID = 69733382

        let migrated = old.migratingRetiredModes()
        XCTAssertEqual(migrated.mode, .entireScreen)
        XCTAssertNil(migrated.areaRect, "the dead rect must not linger in defaults")
        XCTAssertNil(migrated.areaDisplayID)
    }

    func testMigrationKeepsARememberedWindowIntact() {
        // Only the retired mode migrates; a window selection is untouched — the
        // one-click "record that window again" memory must survive the update.
        let selection = fullSelection()
        XCTAssertEqual(selection.migratingRetiredModes(), selection)
    }

    func testOldSelectedAreaPayloadStillDecodesThenMigrates() {
        // The exact JSON an older build wrote: decode must not fail (the enum keeps
        // the case for this), and the load→migrate pipeline lands on entireScreen.
        let defaults = SandboxDefaults.make()
        var old = CaptureSelection()
        old.mode = .selectedArea
        old.areaRect = CGRect(x: 1, y: 2, width: 640, height: 360)
        old.areaDisplayID = 1
        old.save(to: defaults)

        let loaded = CaptureSelection.load(from: defaults)
        XCTAssertEqual(loaded?.mode, .selectedArea, "decoding must survive the retired case")
        XCTAssertEqual(loaded?.migratingRetiredModes().mode, .entireScreen)
    }
}
