import XCTest
import CoreGraphics
@testable import NoCornyTracer

/// CaptureGeometry is the one place capture sizing math lives (phase 6a). These tests pin
/// three things: the entire-screen formula is byte-identical to the one that lived inline
/// in ScreenRecorder since phase 0 (fixtures below are precomputed from that formula, not
/// re-derived); window/area outputs are native-size × scale, even, and never degenerate;
/// and — the trap the whole file exists for — sourceRect stays in POINTS while only the
/// output surface is scaled to pixels (SCStream.h: "The rectangle is specified in points
/// in the display's logical coordinate system").
final class CaptureGeometryTests: XCTestCase {

    /// 14" MacBook Pro logical resolution, in points.
    private let mbp14 = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func output(
        mode: CaptureMode,
        display: CGRect? = nil,
        area: CGRect? = nil,
        window: CGRect? = nil,
        scale: CGFloat = 2,
        requestedHeight: Int = 1080
    ) -> CaptureGeometry.Output {
        CaptureGeometry.outputConfig(
            mode: mode,
            displayBounds: display ?? mbp14,
            areaRect: area,
            windowFrame: window,
            scaleFactor: scale,
            requestedHeight: requestedHeight
        )
    }

    // MARK: - Entire screen: the old inline formula, pinned by fixtures

    func testEntireScreenMatchesTheOldFormulaOnANotchedDisplay() {
        // Old formula: round(1080 * 1512/982) = 1663, odd → 1664.
        let out = output(mode: .entireScreen, scale: 1)
        XCTAssertNil(out.sourceRect)
        XCTAssertEqual(out.width, 1664)
        XCTAssertEqual(out.height, 1080)
    }

    func testEntireScreenOnA16by9DisplayIsExact() {
        let out = output(mode: .entireScreen, display: CGRect(x: 0, y: 0, width: 2560, height: 1440), scale: 1)
        XCTAssertEqual(out.width, 1920)
        XCTAssertEqual(out.height, 1080)
    }

    func testEntireScreenMatchesTheOldFormulaOnA16InchDisplay() {
        // Old formula: round(1080 * 1728/1117) = 1671, odd → 1672.
        let out = output(mode: .entireScreen, display: CGRect(x: 0, y: 0, width: 1728, height: 1117), scale: 1)
        XCTAssertEqual(out.width, 1672)
        XCTAssertEqual(out.height, 1080)
    }

    func testEntireScreenAt480pMatchesTheOldFormula() {
        // Old formula: round(480 * 1512/982) = 739, odd → 740.
        let out = output(mode: .entireScreen, scale: 1, requestedHeight: 480)
        XCTAssertEqual(out.width, 740)
        XCTAssertEqual(out.height, 480)
    }

    func testEntireScreenIgnoresTheScaleFactor() {
        // The old path never scaled by pixel density — output is sized by the resolution
        // setting. Passing 2 must not double anything.
        XCTAssertEqual(output(mode: .entireScreen, scale: 2), output(mode: .entireScreen, scale: 1))
    }

    // MARK: - Selected area

    func testAreaSourceRectStaysInPointsWhileOutputIsScaledToPixels() {
        // THE units test: on Retina (scale 2) the crop rect goes to the config unscaled —
        // scaling it would crop a quarter of the display — and only the surface doubles.
        let area = CGRect(x: 100, y: 100, width: 640, height: 360)
        let out = output(mode: .selectedArea, area: area, scale: 2)
        XCTAssertEqual(out.sourceRect, area, "sourceRect must remain in display points, untouched by the scale factor")
        XCTAssertEqual(out.width, 1280)
        XCTAssertEqual(out.height, 720)
    }

    func testAreaIsClampedIntoTheDisplayFromTheTopLeft() {
        let out = output(mode: .selectedArea, area: CGRect(x: -50, y: -40, width: 300, height: 300), scale: 1)
        XCTAssertEqual(out.sourceRect, CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertEqual(out.width, 300)
        XCTAssertEqual(out.height, 300)
    }

    func testAreaHangingOverTheBottomRightIsMovedBackInside() {
        let out = output(mode: .selectedArea, area: CGRect(x: 1400, y: 900, width: 400, height: 400), scale: 1)
        XCTAssertEqual(out.sourceRect, CGRect(x: 1112, y: 582, width: 400, height: 400))
    }

    func testAreaLargerThanTheDisplayBecomesTheWholeDisplay() {
        let out = output(mode: .selectedArea, area: CGRect(x: 0, y: 0, width: 3000, height: 3000), scale: 1)
        XCTAssertEqual(out.sourceRect, CGRect(x: 0, y: 0, width: 1512, height: 982))
        XCTAssertEqual(out.width, 1512)
        XCTAssertEqual(out.height, 982)
    }

    func testAreaSmallerThanTheMinimumGrowsTo64() {
        let out = output(mode: .selectedArea, area: CGRect(x: 10, y: 10, width: 20, height: 12), scale: 1)
        XCTAssertEqual(out.sourceRect, CGRect(x: 10, y: 10, width: 64, height: 64))
        XCTAssertEqual(out.width, 64)
        XCTAssertEqual(out.height, 64)
    }

    func testTinyAreaInTheCornerGrowsAndSlidesBackInside() {
        let out = output(mode: .selectedArea, area: CGRect(x: 1500, y: 970, width: 10, height: 10), scale: 1)
        XCTAssertEqual(out.sourceRect, CGRect(x: 1448, y: 918, width: 64, height: 64))
    }

    func testAreaOutputPixelsAreAlwaysEven() {
        // 101.5pt × 2 = 203px → bumped to 204; the 63pt side first grows to the 64pt
        // minimum, then scales to 128.
        let out = output(mode: .selectedArea, area: CGRect(x: 0, y: 0, width: 101.5, height: 63), scale: 2)
        XCTAssertEqual(out.sourceRect, CGRect(x: 0, y: 0, width: 101.5, height: 64))
        XCTAssertEqual(out.width, 204)
        XCTAssertEqual(out.height, 128)
    }

    func testAreaModeWithoutARectFallsBackToTheFullDisplayFormula() {
        let out = output(mode: .selectedArea, area: nil, scale: 1)
        XCTAssertNil(out.sourceRect)
        XCTAssertEqual(out.width, 1664)
        XCTAssertEqual(out.height, 1080)
    }

    // MARK: - Window

    func testWindowOutputIsNativeSizeTimesScale() {
        let out = output(mode: .window, window: CGRect(x: 200, y: 150, width: 800, height: 600), scale: 2)
        XCTAssertNil(out.sourceRect, "a desktopIndependentWindow filter delivers the whole window — no crop")
        XCTAssertEqual(out.width, 1600)
        XCTAssertEqual(out.height, 1200)
    }

    func testWindowWithOddPointSizesRoundsUpToEven() {
        let out = output(mode: .window, window: CGRect(x: 0, y: 0, width: 801, height: 601), scale: 1)
        XCTAssertEqual(out.width, 802)
        XCTAssertEqual(out.height, 602)
    }

    func testWindowWithFractionalPointsRoundsThenEvens() {
        // 800.5pt × 2 = 1601px → 1602.
        let out = output(mode: .window, window: CGRect(x: 0, y: 0, width: 800.5, height: 600), scale: 2)
        XCTAssertEqual(out.width, 1602)
        XCTAssertEqual(out.height, 1200)
    }

    func testTinyWindowIsFlooredAtTheMinimumOutput() {
        let out = output(mode: .window, window: CGRect(x: 0, y: 0, width: 40, height: 30), scale: 1)
        XCTAssertEqual(out.width, 64)
        XCTAssertEqual(out.height, 64)
    }

    func testWindowIgnoresTheRequestedResolution() {
        // The resolution setting sizes entire-screen output only; a window records at
        // its native size × scale regardless of the 480p setting.
        let out = output(mode: .window, window: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 1, requestedHeight: 480)
        XCTAssertEqual(out.width, 800)
        XCTAssertEqual(out.height, 600)
    }

    func testWindowModeWithoutAFrameFallsBackToTheFullDisplayFormula() {
        let out = output(mode: .window, window: nil, scale: 1)
        XCTAssertNil(out.sourceRect)
        XCTAssertEqual(out.width, 1664)
        XCTAssertEqual(out.height, 1080)
    }
}
