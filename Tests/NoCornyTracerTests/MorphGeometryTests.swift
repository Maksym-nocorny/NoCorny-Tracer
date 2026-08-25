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
        XCTAssertEqual(MorphGeometry.size(of: .recordingPill), CGSize(width: 341, height: 54))
    }

    // MARK: Anchored morphs

    func testDrawerOpensDownwardWhenItFits() {
        let anchor = CGPoint(x: 400, y: 700)  // bar top-left, upper half (center 660 > 467.5)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.gallery), visible: visible
        )
        XCTAssertEqual(frame.minX, 400)
        XCTAssertEqual(frame.maxY, 700, "the top-left anchor must hold")
        XCTAssertEqual(frame.minY, 700 - 428, "the surface grew downward (down = smaller y)")
    }

    func testDrawerOpensUpwardNearTheBottom() {
        // Bar center 160 is deep in the lower half — the drawer unfolds ABOVE the
        // stationary bar: the surface's bottom edge stays the bar's bottom edge.
        let anchor = CGPoint(x: 400, y: 200)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.gallery), visible: visible
        )
        XCTAssertEqual(frame.minY, 200 - 80, "the bar did not move — its bottom edge holds")
        XCTAssertEqual(frame.maxY, 200 - 80 + 428, "the drawer grew upward past the bar")
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY, "and the result stays on screen")
    }

    // MARK: Half-screen rule (verdict 25.08): direction follows the half, not just fit

    /// A tall display where BOTH directions fit — the lower half still wins upward.
    private let tall = CGRect(x: 0, y: 0, width: 1440, height: 1000)

    func testLowerHalfOpensUpwardEvenWhenDownwardFits() {
        let anchor = CGPoint(x: 400, y: 460)  // bar center 420 < midY 500
        XCTAssertTrue(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: tall))
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.settings), visible: tall
        )
        XCTAssertEqual(frame.minY, 460 - 80)
        XCTAssertEqual(frame.maxY, 460 - 80 + 428)
    }

    func testUpperHalfOpensDownwardEvenWhenUpwardFits() {
        let anchor = CGPoint(x: 400, y: 560)  // bar center 520 > midY 500
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: tall))
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.settings), visible: tall
        )
        XCTAssertEqual(frame.maxY, 560, "anchor held — the drawer hangs under the bar")
        XCTAssertEqual(frame.minY, 560 - 428)
    }

    func testDeadCenterOpensDownward() {
        let anchor = CGPoint(x: 400, y: 540)  // bar center 500 == midY 500
        XCTAssertFalse(
            MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: tall),
            "a tie goes downward"
        )
    }

    /// The half-screen rule applies ONLY to drawers — the banner still grows down.
    func testBarSurfaceIgnoresTheHalfScreenRule() {
        let anchor = CGPoint(x: 400, y: 300)  // lower half
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .bar,
            bannerHeight: MorphGeometry.storageBannerExtent, visible: visible
        )
        XCTAssertEqual(frame.maxY, 300, "the bar's anchor holds; the banner hangs below")
    }

    func testDrawerSlidesIntoBoundsWhenNeitherDirectionFits() {
        // 500pt of visible height holds a 428pt surface, but from this anchor
        // neither direction fits: up needs maxY 250 − 80 + 428 = 598 > 500,
        // down needs minY 250 − 428 = −178 < 0.
        let short = CGRect(x: 0, y: 0, width: 1440, height: 500)
        let anchor = CGPoint(x: 100, y: 250)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.settings), visible: short
        )
        XCTAssertEqual(frame.minX, 100)
        XCTAssertGreaterThanOrEqual(frame.minY, short.minY)
        XCTAssertLessThanOrEqual(frame.maxY, short.maxY)
        XCTAssertEqual(frame.minY, 0, "slid to the bottom edge of the visible frame")
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
        XCTAssertEqual(frame.size, CGSize(width: 341, height: 54))
    }

    /// The round trip the bar actually performs: open a drawer mid-screen, close it —
    /// the bar must come back to exactly where it was.
    func testDrawerRoundTripReturnsTheBarFrame() {
        let anchor = CGPoint(x: 400, y: 700)
        let barFrame = MorphGeometry.targetFrame(anchorTopLeft: anchor, surface: .bar, visible: visible)
        let drawerFrame = MorphGeometry.targetFrame(
            anchorTopLeft: MorphGeometry.barAnchor(
                forSurfaceFrame: barFrame, surface: .bar, opensUp: false
            ),
            surface: .barWithDrawer(.gallery),
            visible: visible
        )
        let backFrame = MorphGeometry.targetFrame(
            anchorTopLeft: MorphGeometry.barAnchor(
                forSurfaceFrame: drawerFrame, surface: .barWithDrawer(.gallery), opensUp: false
            ),
            surface: .bar,
            visible: visible
        )
        XCTAssertEqual(backFrame, barFrame)
    }

    /// Same round trip for an UPWARD drawer: the bar anchor is recovered from the
    /// surface's BOTTOM (the bar sits at the bottom of an upward surface).
    func testUpwardDrawerRoundTripReturnsTheBarFrame() {
        let anchor = CGPoint(x: 400, y: 300)  // lower half of `visible`
        let barFrame = MorphGeometry.targetFrame(anchorTopLeft: anchor, surface: .bar, visible: visible)
        let drawerSurface = CommandBarSurface.barWithDrawer(.settings)
        XCTAssertTrue(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: visible))
        let drawerFrame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: drawerSurface, visible: visible
        )
        let recovered = MorphGeometry.barAnchor(
            forSurfaceFrame: drawerFrame, surface: drawerSurface, opensUp: true
        )
        XCTAssertEqual(recovered, anchor, "the bar anchor survives the upward morph")
        let backFrame = MorphGeometry.targetFrame(
            anchorTopLeft: recovered, surface: .bar, visible: visible
        )
        XCTAssertEqual(backFrame, barFrame)
    }

    // MARK: Dynamic pill width (round 3: base 341 is the canon, extras grow right)

    /// Transient pill content the mockup doesn't draw (a 100+ minute timer
    /// outgrowing its 57-pt slot) widens ONLY the pill, to the RIGHT of the held
    /// top-left anchor — the stop button at the leading edge must not move.
    func testPillExtraWidthGrowsRightFromTheHeldAnchor() {
        let anchor = CGPoint(x: 400, y: 700)
        let base = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .recordingPill, visible: visible
        )
        let wide = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .recordingPill, pillExtraWidth: 38, visible: visible
        )
        XCTAssertEqual(wide.minX, base.minX, "the leading edge (stop button) holds")
        XCTAssertEqual(wide.maxY, base.maxY, "the top edge holds")
        XCTAssertEqual(wide.width, base.width + 38, "all growth goes right")
        XCTAssertEqual(wide.height, base.height)
    }

    func testPillExtraWidthTouchesNoOtherSurfaceAndNeverShrinks() {
        XCTAssertEqual(
            MorphGeometry.size(of: .bar, pillExtraWidth: 38),
            MorphGeometry.size(of: .bar),
            "the bar ignores the pill's extra width"
        )
        XCTAssertEqual(
            MorphGeometry.size(of: .barWithDrawer(.gallery), pillExtraWidth: 38),
            MorphGeometry.size(of: .barWithDrawer(.gallery)),
            "drawers ignore it too"
        )
        XCTAssertEqual(
            MorphGeometry.size(of: .recordingPill, pillExtraWidth: -20),
            MorphGeometry.size(of: .recordingPill),
            "a negative report clamps to the 341-pt base, never below it"
        )
    }

    /// The existing right-edge clamp covers the widened pill: growth that would
    /// leave the screen slides the whole surface left instead.
    func testWidePillStillClampsToTheRightEdge() {
        let anchor = CGPoint(x: 1080, y: 700)   // base 1080+341=1421 fits in 1440
        let base = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .recordingPill, visible: visible
        )
        XCTAssertEqual(base.minX, 1080, "the base pill fits unmoved")
        let wide = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .recordingPill, pillExtraWidth: 38, visible: visible
        )
        XCTAssertEqual(wide.maxX, visible.maxX, "the widened pill slid to the edge")
        XCTAssertEqual(wide.width, 341 + 38)
    }

    // MARK: Recording pill perch (verdict 25.08: default = top-center)

    func testRecordingPillDefaultPerchIsTopCenter() {
        let topLeft = MorphGeometry.recordingPillTopLeft(visible: visible)
        XCTAssertEqual(topLeft.x, visible.midX - 341 / 2, "centered horizontally")
        XCTAssertEqual(topLeft.y, visible.maxY - 64, "64pt below the top of the visible frame")

        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: topLeft, surface: .recordingPill, visible: visible
        )
        XCTAssertEqual(frame.maxY, visible.maxY - 64)
        XCTAssertEqual(frame.size, CGSize(width: 341, height: 54))
        XCTAssertEqual(frame.midX, visible.midX)
    }

    // MARK: Storage banner

    func testBannerExtentIsGapPlusBanner() {
        XCTAssertEqual(MorphGeometry.storageBannerExtent, 12 + 38,
                       "macro 87:1810: 12pt gap under the bar + 38pt banner")
    }

    func testBannerExtendsOnlyTheBar() {
        let extent = MorphGeometry.storageBannerExtent
        XCTAssertEqual(
            MorphGeometry.size(of: .bar, bannerHeight: extent),
            CGSize(width: 560, height: 80 + 50)
        )
        XCTAssertEqual(
            MorphGeometry.size(of: .barWithDrawer(.gallery), bannerHeight: extent),
            MorphGeometry.size(of: .barWithDrawer(.gallery)),
            "the drawer surface ignores the banner (its Dropbox row shows the quota)"
        )
        XCTAssertEqual(
            MorphGeometry.size(of: .recordingPill, bannerHeight: extent),
            MorphGeometry.size(of: .recordingPill),
            "the recording pill ignores the banner"
        )
    }

    func testBannerGrowsDownwardHoldingTheAnchor() {
        let anchor = CGPoint(x: 400, y: 700)
        let bare = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .bar, visible: visible
        )
        let withBanner = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .bar,
            bannerHeight: MorphGeometry.storageBannerExtent, visible: visible
        )
        XCTAssertEqual(withBanner.maxY, bare.maxY, "the top-left anchor must hold")
        XCTAssertEqual(withBanner.minX, bare.minX)
        XCTAssertEqual(withBanner.height, bare.height + MorphGeometry.storageBannerExtent,
                       "the banner grows the surface downward")
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
