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
        // Downward there is no room at all (200 − 428 < visible.minY) — the drawer
        // unfolds ABOVE the stationary bar: the surface's bottom edge stays the
        // bar's bottom edge.
        let anchor = CGPoint(x: 400, y: 200)
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.gallery), visible: visible
        )
        XCTAssertEqual(frame.minY, 200 - 80, "the bar did not move — its bottom edge holds")
        XCTAssertEqual(frame.maxY, 200 - 80 + 428, "the drawer grew upward past the bar")
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY, "and the result stays on screen")
    }

    // MARK: Direction policy (verdict 26.08): DOWN whenever it fits, UP only when it must

    /// A tall borderless display for direction scenarios.
    private let tall = CGRect(x: 0, y: 0, width: 1440, height: 1000)

    /// The 4.2.0 complaint verbatim: the bar in the LOWER half, yet the drawer
    /// fits below with margin to spare — it must open DOWNWARD now (the old
    /// half-screen rule sent it up from here).
    func testLowerHalfStillOpensDownwardWhenItFits() {
        let anchor = CGPoint(x: 400, y: 460)  // bar center 420 < midY 500 (old rule: up)
        // Down needs minY 460 − 428 = 32 ≥ margin 16 — fits.
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: tall))
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.settings), visible: tall
        )
        XCTAssertEqual(frame.maxY, 460, "anchor held — the drawer hangs under the bar")
        XCTAssertEqual(frame.minY, 460 - 428)
    }

    func testCenteredBarOpensDownward() {
        let anchor = CGPoint(x: 400, y: 540)  // bar center 500 == midY, plenty of room below
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: tall))
    }

    func testUpperHalfOpensDownward() {
        let anchor = CGPoint(x: 400, y: 560)
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: tall))
    }

    /// Down fits geometrically but WITHOUT the 16pt margin — that counts as "does
    /// not fit", and the drawer goes up (which fits comfortably from here).
    func testNearBottomWithoutMarginOpensUpward() {
        let anchor = CGPoint(x: 400, y: 440)  // down would land at minY 12 < margin 16
        XCTAssertTrue(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: tall))
        let frame = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.settings), visible: tall
        )
        XCTAssertEqual(frame.minY, 440 - 80, "the bar's bottom edge holds")
        XCTAssertEqual(frame.maxY, 440 - 80 + 428, "the drawer grew upward past the bar")
    }

    /// The margin boundary is inclusive: landing exactly 16pt off the edge fits.
    func testFitMarginBoundaryIsInclusive() {
        let exactly = CGPoint(x: 400, y: tall.minY + 428 + MorphGeometry.drawerFitMargin)
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: exactly, visible: tall))
        let onePointShort = CGPoint(x: 400, y: exactly.y - 1)
        XCTAssertTrue(MorphGeometry.drawerOpensUpward(anchorTopLeft: onePointShort, visible: tall))
    }

    /// Neither direction fits (tiny screen) → the answer is DOWN, and
    /// `targetFrame`'s slide-into-bounds clamp handles the placement
    /// (see `testDrawerSlidesIntoBoundsWhenNeitherDirectionFits`).
    func testTinyScreenFallsBackDownward() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 500)
        let anchor = CGPoint(x: 100, y: 250)
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: anchor, visible: short))
    }

    /// The banner never joins the direction math: the drawer surface REPLACES the
    /// banner (only `.bar` renders it), so a bar wearing the banner opens exactly
    /// like a bare one — and the drawer's target frame ignores the extent too.
    func testBannerDoesNotChangeTheDrawerDirectionOrFrame() {
        let anchor = CGPoint(x: 400, y: 460)  // the down-fits scenario above
        let bare = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.gallery), visible: tall
        )
        let withBanner = MorphGeometry.targetFrame(
            anchorTopLeft: anchor, surface: .barWithDrawer(.gallery),
            bannerHeight: MorphGeometry.storageBannerExtent, visible: tall
        )
        XCTAssertEqual(withBanner, bare)
    }

    /// The direction policy applies ONLY to drawers — the banner still grows down.
    func testBarSurfaceIgnoresTheDirectionPolicy() {
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

    // MARK: Panel-frame animation policy (round 5: «хай плашка буде спокійною»)

    /// Only the recording-pill morphs animate the panel frame — that animation IS
    /// the pill's flight to its perch. Drawer open/close (both directions) and
    /// tab switches snap: an animated frame under a re-laying-out SwiftUI root is
    /// what read as the bar «здригається» on the 4.0.0 demo.
    func testOnlyPillMorphsAnimateThePanelFrame() {
        typealias M = CommandBarWindowManager
        XCTAssertTrue(M.morphAnimates(from: .bar, to: .recordingPill), "the pill flies out")
        XCTAssertTrue(M.morphAnimates(from: .recordingPill, to: .bar), "and flies back")
        XCTAssertTrue(M.morphAnimates(from: .barWithDrawer(.gallery), to: .recordingPill),
                      "recording started over an open drawer still flies")
        XCTAssertFalse(M.morphAnimates(from: .bar, to: .barWithDrawer(.gallery)), "drawer open snaps")
        XCTAssertFalse(M.morphAnimates(from: .bar, to: .barWithDrawer(.settings)), "both drawers")
        XCTAssertFalse(M.morphAnimates(from: .barWithDrawer(.settings), to: .bar), "drawer close snaps")
        XCTAssertFalse(M.morphAnimates(from: .barWithDrawer(.gallery), to: .barWithDrawer(.settings)),
                       "tab switch snaps (the frame doesn't even change)")
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

    // MARK: Compositor flight (round 5c)

    func testContentOffsetOfFrameInItselfIsZero() {
        let frame = CGRect(x: 100, y: 200, width: 560, height: 80)
        XCTAssertEqual(MorphGeometry.contentOffset(of: frame, in: frame), .zero)
    }

    func testContentOffsetFlipsTheVerticalAxis() {
        // A low bar flying to the pill's high perch: the union spans both, and
        // SwiftUI y grows DOWN — the higher AppKit frame gets the smaller offset.
        let bar = CGRect(x: 440, y: 140, width: 560, height: 80)
        let pill = CGRect(
            x: visible.midX - 341 / 2,
            y: visible.maxY - MorphGeometry.recordingPillTopInset - 54,
            width: 341, height: 54
        )
        let union = bar.union(pill)
        let barOffset = MorphGeometry.contentOffset(of: bar, in: union)
        let pillOffset = MorphGeometry.contentOffset(of: pill, in: union)
        // The union's top edge is the pill's top edge, its left edge is the bar's.
        XCTAssertEqual(pillOffset.height, 0, "the pill sits at the union's top")
        XCTAssertEqual(barOffset.width, 0, "the bar sits at the union's left")
        XCTAssertEqual(barOffset.height, union.maxY - bar.maxY)
        XCTAssertEqual(pillOffset.width, pill.minX - union.minX)
        XCTAssertGreaterThan(barOffset.height, 0, "the lower frame is further down in SwiftUI coords")
    }

    func testContentOffsetRoundTripsThroughTheUnion() {
        // top-left(container) + offset (with the y-axis flipped back) must
        // reconstruct the frame's own top-left — the invariant the flight's
        // settle snap relies on.
        let frame = CGRect(x: 320, y: 500, width: 341, height: 54)
        let container = CGRect(x: 100, y: 140, width: 900, height: 700)
        let offset = MorphGeometry.contentOffset(of: frame, in: container)
        XCTAssertEqual(container.minX + offset.width, frame.minX)
        XCTAssertEqual(container.maxY - offset.height, frame.maxY)
    }

    func testUnionKeepsTopLeftWhenGrowingRightOrDown() {
        let current = CGRect(x: 100, y: 300, width: 600, height: 400)
        // Wider to the right and deeper down — the top-left corner holds.
        XCTAssertTrue(MorphGeometry.unionKeepsTopLeft(
            current: current,
            adding: CGRect(x: 500, y: 200, width: 400, height: 300)
        ))
        // Inside the current union — trivially holds.
        XCTAssertTrue(MorphGeometry.unionKeepsTopLeft(
            current: current,
            adding: CGRect(x: 200, y: 350, width: 100, height: 100)
        ))
    }

    func testUnionMovesTopLeftWhenGrowingLeftOrUp() {
        let current = CGRect(x: 100, y: 300, width: 600, height: 400)
        // Growing LEFT moves minX.
        XCTAssertFalse(MorphGeometry.unionKeepsTopLeft(
            current: current,
            adding: CGRect(x: 50, y: 400, width: 100, height: 100)
        ))
        // Growing UP moves maxY (AppKit y grows up).
        XCTAssertFalse(MorphGeometry.unionKeepsTopLeft(
            current: current,
            adding: CGRect(x: 300, y: 650, width: 100, height: 100)
        ))
    }

    func testFlightEndpointsAgreeWithTargetFrames() {
        // The real bar→pill flight: source and destination offsets inside the
        // union must land the content exactly on the two surface frames.
        let anchor = CGPoint(x: 300, y: 320)
        let bar = MorphGeometry.targetFrame(anchorTopLeft: anchor, surface: .bar, visible: visible)
        let pill = MorphGeometry.targetFrame(
            anchorTopLeft: MorphGeometry.recordingPillTopLeft(visible: visible),
            surface: .recordingPill, visible: visible
        )
        let union = bar.union(pill)
        let source = MorphGeometry.contentOffset(of: bar, in: union)
        let destination = MorphGeometry.contentOffset(of: pill, in: union)
        // Reconstruct both frames from the union's top-left + the offsets.
        XCTAssertEqual(union.minX + source.width, bar.minX)
        XCTAssertEqual(union.maxY - source.height, bar.maxY)
        XCTAssertEqual(union.minX + destination.width, pill.minX)
        XCTAssertEqual(union.maxY - destination.height, pill.maxY)
        // And the reverse leg is the mirror image within the same union.
        XCTAssertEqual(pill.union(bar), union)
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

    // MARK: Round 6 — the glass never leaves the screen

    func testClampedIntoVisibleLeavesAnInBoundsFrameAlone() {
        let frame = CGRect(x: 400, y: 300, width: 560, height: 80)
        XCTAssertEqual(MorphGeometry.clampedIntoVisible(frame, visible: visible), frame)
    }

    func testClampedIntoVisiblePinsEveryEdge() {
        let size = CGSize(width: 560, height: 80)
        // Off the left / right edges.
        XCTAssertEqual(
            MorphGeometry.clampedIntoVisible(
                CGRect(origin: CGPoint(x: visible.minX - 200, y: 300), size: size), visible: visible
            ).minX,
            visible.minX
        )
        XCTAssertEqual(
            MorphGeometry.clampedIntoVisible(
                CGRect(origin: CGPoint(x: visible.maxX - 100, y: 300), size: size), visible: visible
            ).maxX,
            visible.maxX
        )
        // Off the bottom (into the Dock strip) / off the top (under the menu bar).
        XCTAssertEqual(
            MorphGeometry.clampedIntoVisible(
                CGRect(origin: CGPoint(x: 400, y: visible.minY - 70), size: size), visible: visible
            ).minY,
            visible.minY
        )
        XCTAssertEqual(
            MorphGeometry.clampedIntoVisible(
                CGRect(origin: CGPoint(x: 400, y: visible.maxY - 10), size: size), visible: visible
            ).maxY,
            visible.maxY
        )
    }

    func testClampedIntoVisiblePrefersTheMinEdgesWhenOversized() {
        // A surface taller than the visible frame cannot fully fit — the clamp
        // pins the bottom-left deterministically instead of oscillating.
        let oversized = CGRect(x: -100, y: -100, width: 2000, height: 2000)
        let clamped = MorphGeometry.clampedIntoVisible(oversized, visible: visible)
        XCTAssertEqual(clamped.minX, visible.minX)
        XCTAssertEqual(clamped.minY, visible.minY)
    }

    /// A stale anchor saved on a taller display used to hang the bar past the TOP
    /// of the visible frame (the downward branch only clamped the bottom). Round 6:
    /// `targetFrame` ends in a full clamp, so every programmatic placement is
    /// in-bounds — which is also what keeps flight unions in-bounds.
    func testTargetFrameClampsAStaleAnchorBackUnderTheTop() {
        let anchor = CGPoint(x: 400, y: visible.maxY + 200)
        let frame = MorphGeometry.targetFrame(anchorTopLeft: anchor, surface: .bar, visible: visible)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY, "the glass may not hide under the menu bar")
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
    }

    /// The drag clamp works on the GLASS, not the panel: with the glass flush
    /// against an edge the transparent shadow apron legitimately hangs past it.
    func testClampedPanelFrameClampsTheGlassNotTheShadowApron() {
        let offscreenGlass = CGRect(x: 100, y: visible.minY - 50, width: 560, height: 80)
        let panel = MorphGeometry.panelFrame(forLogical: offscreenGlass)
        let clampedPanel = MorphGeometry.clampedPanelFrame(panel, visible: visible)
        let clampedGlass = MorphGeometry.logicalFrame(forPanel: clampedPanel)
        XCTAssertEqual(clampedGlass.minY, visible.minY, "the glass is pushed back on screen")
        XCTAssertEqual(clampedGlass.minX, offscreenGlass.minX, "an in-bounds axis is untouched")
        XCTAssertEqual(clampedPanel.minY, visible.minY - MorphGeometry.panelShadowInset,
                       "the shadow apron itself may hang past the edge — that is not 'off screen'")
    }

    func testClampedPanelFrameLeavesAnInBoundsPanelAlone() {
        let logical = CGRect(x: 400, y: 300, width: 560, height: 80)
        let panel = MorphGeometry.panelFrame(forLogical: logical)
        XCTAssertEqual(MorphGeometry.clampedPanelFrame(panel, visible: visible), panel)
    }

    /// The drag auto-flip's decision inputs (round 6): dragging the bar DOWN with
    /// an open drawer crosses the fit boundary and the direction verdict flips to
    /// upward; dragging back up flips it down again. The boundary on this display
    /// is minY + margin + drawer height = 60 + 16 + 428 = 504.
    func testDragReEvaluationFlipsTheDrawerDirectionWithPosition() {
        let high = CGPoint(x: 400, y: 700)
        let low = CGPoint(x: 400, y: 500)
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: high, visible: visible),
                       "plenty of room below — the drawer hangs down")
        XCTAssertTrue(MorphGeometry.drawerOpensUpward(anchorTopLeft: low, visible: visible),
                      "dragged under the boundary — the drawer must flip above the bar")
        XCTAssertFalse(MorphGeometry.drawerOpensUpward(anchorTopLeft: high, visible: visible),
                       "and back up it flips down again — the rule is position, not history")
    }
}
