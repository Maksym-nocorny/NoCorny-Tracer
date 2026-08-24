import XCTest
@testable import NoCornyTracer

/// Frame math of the floating command-bar panel. All coordinates are AppKit screen
/// coordinates: origin bottom-left, y grows UP, so "top-left" of a rect is (minX, maxY).
final class MorphGeometryTests: XCTestCase {

    /// A 1440×900 display with a 25pt menu bar and a 60pt Dock strip.
    private let visible = CGRect(x: 0, y: 60, width: 1440, height: 815)

    // MARK: Sizes

    func testSurfaceSizes() {
        XCTAssertEqual(MorphGeometry.size(of: .bar), CGSize(width: 560, height: 80))
        XCTAssertEqual(
            MorphGeometry.size(of: .barWithDrawer(.gallery)),
            CGSize(width: 560, height: 80 + 16 + 332),
            "bar + 16pt gap + drawer"
        )
        XCTAssertEqual(
            MorphGeometry.size(of: .barWithDrawer(.settings)),
            MorphGeometry.size(of: .barWithDrawer(.gallery)),
            "both drawers share one drawer size"
        )
        XCTAssertEqual(MorphGeometry.size(of: .recordingPill), CGSize(width: 292, height: 54))
    }

    // MARK: Anchored morphs

    func testDrawerOpensDownwardWhenItFits() {
        let anchor = CGPoint(x: 400, y: 700)  // bar top-left, mid-screen
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.gallery), visible: visible
        )
        XCTAssertEqual(frame.minX, 400)
        XCTAssertEqual(frame.maxY, 700, "the top-left anchor must hold")
        XCTAssertEqual(frame.minY, 700 - 428, "the surface grew downward (down = smaller y)")
    }

    func testDrawerOpensUpwardNearTheBottom() {
        // Down would need origin.y = 200 − 428 = −228, below visible.minY = 60.
        let anchor = CGPoint(x: 400, y: 200)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.gallery), visible: visible
        )
        XCTAssertEqual(frame.minY, 200, "the anchor becomes the bottom-left corner")
        XCTAssertEqual(frame.maxY, 200 + 428)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY, "and the result stays on screen")
    }

    func testDrawerSlidesIntoBoundsWhenNeitherDirectionFits() {
        // 500pt of visible height holds a 428pt surface, but from this anchor neither
        // straight down (250 − 428 < 0) nor straight up (250 + 428 > 500) fits.
        let short = CGRect(x: 0, y: 0, width: 1440, height: 500)
        let anchor = CGPoint(x: 100, y: 250)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.settings), visible: short
        )
        XCTAssertEqual(frame.minX, 100)
        XCTAssertGreaterThanOrEqual(frame.minY, short.minY)
        XCTAssertLessThanOrEqual(frame.maxY, short.maxY)
        XCTAssertEqual(frame.minY, 0, "slid down to the bottom edge of the visible frame")
    }

    func testRightEdgePushesTheSurfaceLeft() {
        let anchor = CGPoint(x: 1300, y: 700)  // 1300 + 560 = 1860 > 1440
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .bar, visible: visible
        )
        XCTAssertEqual(frame.minX, 1440 - 560)
        XCTAssertEqual(frame.maxY, 700, "only x moved — the vertical anchor held")
    }

    func testLeftEdgeClampsToo() {
        let anchor = CGPoint(x: -50, y: 700)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .bar, visible: visible
        )
        XCTAssertEqual(frame.minX, visible.minX)
    }

    func testPillKeepsTheTopLeftAnchor() {
        let anchor = CGPoint(x: 400, y: 700)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .recordingPill, visible: visible
        )
        XCTAssertEqual(frame.minX, 400)
        XCTAssertEqual(frame.maxY, 700)
        XCTAssertEqual(frame.size, CGSize(width: 292, height: 54))
    }

    /// The round trip the bar actually performs: open a drawer mid-screen, close it —
    /// the bar must come back to exactly where it was.
    func testDrawerRoundTripReturnsTheBarFrame() {
        let anchor = CGPoint(x: 400, y: 700)
        let barFrame = MorphGeometry.targetFrame(anchorTopLeft: anchor, surface: .bar, visible: visible)
        let drawerFrame = MorphGeometry.targetFrame(
            anchorTopLeft: CGPoint(x: barFrame.minX, y: barFrame.maxY),
            surface: .barWithDrawer(.gallery),
            visible: visible
        )
        let backFrame = MorphGeometry.targetFrame(
            anchorTopLeft: CGPoint(x: drawerFrame.minX, y: drawerFrame.maxY),
            surface: .bar,
            visible: visible
        )
        XCTAssertEqual(backFrame, barFrame)
    }

    // MARK: Defaults and insets

    func testInitialOriginCentersAndHangsFromTheTop() {
        let size = MorphGeometry.size(of: .bar)
        let origin = MorphGeometry.initialOrigin(for: size, visible: visible)
        XCTAssertEqual(origin.x, visible.midX - size.width / 2)
        XCTAssertEqual(origin.y, visible.maxY - 120 - size.height,
                       "the TOP edge sits 120pt below the visible top")
    }

    func testPanelFrameRoundTripsTheShadowInset() {
        let logical = CGRect(x: 100, y: 200, width: 560, height: 80)
        let panel = MorphGeometry.panelFrame(forLogical: logical)
        XCTAssertEqual(panel.width, logical.width + 2 * MorphGeometry.panelShadowInset)
        XCTAssertEqual(panel.height, logical.height + 2 * MorphGeometry.panelShadowInset)
        XCTAssertEqual(MorphGeometry.logicalFrame(forPanel: panel), logical)
    }
}
