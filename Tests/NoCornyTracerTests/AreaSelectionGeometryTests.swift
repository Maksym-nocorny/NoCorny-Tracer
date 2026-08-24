import XCTest
import CoreGraphics
@testable import NoCornyTracer

/// The math behind the area-selection overlay (phase 6b). Everything here runs in the
/// overlay's coordinate space — POINTS, top-left origin — which is also the space the
/// committed rect is saved in (CaptureSelection.areaRect) and the space
/// SCStreamConfiguration.sourceRect expects; only the size badge converts to pixels.
final class AreaSelectionGeometryTests: XCTestCase {

    /// A 1440×900 "screen" in points, origin at .zero like the overlay's bounds.
    private let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - Marquee (fresh drag)

    func testMarqueeNormalizesEveryDragDirection() {
        let expected = CGRect(x: 100, y: 100, width: 400, height: 300)
        let a = CGPoint(x: 100, y: 100)
        let b = CGPoint(x: 500, y: 400)
        // Down-right, up-left, down-left, up-right — one rect, whichever way the
        // mouse travelled.
        XCTAssertEqual(AreaSelectionGeometry.marqueeRect(from: a, to: b, in: bounds), expected)
        XCTAssertEqual(AreaSelectionGeometry.marqueeRect(from: b, to: a, in: bounds), expected)
        XCTAssertEqual(AreaSelectionGeometry.marqueeRect(
            from: CGPoint(x: 500, y: 100), to: CGPoint(x: 100, y: 400), in: bounds
        ), expected)
        XCTAssertEqual(AreaSelectionGeometry.marqueeRect(
            from: CGPoint(x: 100, y: 400), to: CGPoint(x: 500, y: 100), in: bounds
        ), expected)
    }

    func testMarqueeClampsTheCursorToTheScreen() {
        // The cursor mathematically can't leave a full-screen panel, but the guard is
        // cheap and the failure (a rect hanging off the display) would reach the encoder.
        let rect = AreaSelectionGeometry.marqueeRect(
            from: CGPoint(x: 1200, y: 700),
            to: CGPoint(x: 2000, y: 1500),
            in: bounds
        )
        XCTAssertEqual(rect, CGRect(x: 1200, y: 700, width: 240, height: 200))
    }

    func testMarqueeEnforcesTheMinimumLive() {
        // A 10×10 flick becomes the 64×64 minimum immediately — clamped during the
        // drag (design decision: clamp, not a red badge).
        let rect = AreaSelectionGeometry.marqueeRect(
            from: CGPoint(x: 200, y: 200),
            to: CGPoint(x: 210, y: 210),
            in: bounds
        )
        XCTAssertEqual(rect.size, CGSize(width: 64, height: 64))
        XCTAssertEqual(rect.origin, CGPoint(x: 200, y: 200), "grows around its own origin")
    }

    func testMinimumMarqueeInACornerStaysOnScreen() {
        let rect = AreaSelectionGeometry.marqueeRect(
            from: CGPoint(x: 1435, y: 895),
            to: CGPoint(x: 1440, y: 900),
            in: bounds
        )
        XCTAssertEqual(rect.size, CGSize(width: 64, height: 64))
        XCTAssertTrue(bounds.contains(rect), "the grown minimum must shift back inside the screen")
    }

    // MARK: - Move (drag inside the selection)

    func testMoveTranslatesByTheDragDistance() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let moved = AreaSelectionGeometry.movedRect(rect, by: CGSize(width: 50, height: -30), in: bounds)
        XCTAssertEqual(moved, CGRect(x: 150, y: 70, width: 400, height: 300))
    }

    func testMoveStopsAtTheScreenEdges() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let moved = AreaSelectionGeometry.movedRect(rect, by: CGSize(width: 5000, height: 5000), in: bounds)
        XCTAssertEqual(moved, CGRect(x: 1040, y: 600, width: 400, height: 300),
                       "moving never shrinks the rect and never pushes it off the display")
    }

    // MARK: - Resize (drag on a handle)

    func testCornerHandleMovesBothItsEdges() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let resized = AreaSelectionGeometry.resizedRect(
            rect, handle: .topLeft, to: CGPoint(x: 50, y: 60), in: bounds
        )
        XCTAssertEqual(resized, CGRect(x: 50, y: 60, width: 450, height: 340))
    }

    func testMidpointHandleMovesOnlyItsOwnAxis() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let resized = AreaSelectionGeometry.resizedRect(
            rect, handle: .right, to: CGPoint(x: 700, y: 900), in: bounds
        )
        XCTAssertEqual(resized, CGRect(x: 100, y: 100, width: 600, height: 300),
                       "a side handle must ignore the cursor's other axis")
    }

    func testResizePinsTheOppositeEdgeAndRespectsTheMinimum() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        // Dragging the left edge far PAST the right edge: clamp at 64pt short of it,
        // never flip the rect inside out.
        let resized = AreaSelectionGeometry.resizedRect(
            rect, handle: .left, to: CGPoint(x: 1200, y: 250), in: bounds
        )
        XCTAssertEqual(resized, CGRect(x: 436, y: 100, width: 64, height: 300))
        XCTAssertEqual(resized.maxX, rect.maxX, "the opposite edge never moves")
    }

    func testResizeClampsTheCursorToTheScreen() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let resized = AreaSelectionGeometry.resizedRect(
            rect, handle: .bottomRight, to: CGPoint(x: 5000, y: 5000), in: bounds
        )
        XCTAssertEqual(resized, CGRect(x: 100, y: 100, width: 1340, height: 800))
    }

    // MARK: - Handle hit testing

    func testHandleHitFindsTheNearestHandle() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(AreaSelectionGeometry.handle(at: CGPoint(x: 105, y: 97), in: rect), .topLeft)
        XCTAssertEqual(AreaSelectionGeometry.handle(at: CGPoint(x: 300, y: 402), in: rect), .bottom)
        XCTAssertEqual(AreaSelectionGeometry.handle(at: CGPoint(x: 495, y: 255), in: rect), .right)
    }

    func testPressAwayFromEveryHandleHitsNothing() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertNil(AreaSelectionGeometry.handle(at: CGPoint(x: 300, y: 250), in: rect),
                     "the interior belongs to move, not resize")
        XCTAssertNil(AreaSelectionGeometry.handle(at: CGPoint(x: 700, y: 700), in: rect))
    }

    func testCornerWinsWhereCornerAndMidpointBothReach() {
        // On a minimum-size rect the corner and midpoint zones are 32pt apart; a press
        // between them but within reach of both must resolve to the corner.
        let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        XCTAssertEqual(
            AreaSelectionGeometry.handle(at: CGPoint(x: 22, y: 2), in: rect, tolerance: 24),
            .topLeft
        )
    }

    // MARK: - Size badge (the ONLY place pixels appear)

    func testBadgeShowsPixelsScaledFromPoints() {
        let rect = CGRect(x: 10, y: 10, width: 640, height: 360)
        XCTAssertEqual(AreaSelectionGeometry.badgeText(for: rect, scale: 2), "1280 × 720")
        XCTAssertEqual(AreaSelectionGeometry.badgeText(for: rect, scale: 1), "640 × 360")
    }

    func testBadgeRoundsFractionalPixels() {
        let rect = CGRect(x: 0, y: 0, width: 100.4, height: 100.6)
        let px = AreaSelectionGeometry.pixelSize(of: rect, scale: 1)
        XCTAssertEqual(px.width, 100)
        XCTAssertEqual(px.height, 101)
    }

    func testGeometryStaysInPointsRegardlessOfScale() {
        // The committed rect is what marquee/move/resize produce — none of them take a
        // scale. This pins the contract: what lands in CaptureSelection.areaRect is
        // points, identical on a Retina and a 1× display; scale touches the badge only.
        let rect = AreaSelectionGeometry.marqueeRect(
            from: CGPoint(x: 100, y: 100), to: CGPoint(x: 740, y: 460), in: bounds
        )
        XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 640, height: 360))
        XCTAssertEqual(AreaSelectionGeometry.pixelSize(of: rect, scale: 1).width, Int(rect.width))
    }

    // MARK: - Shared floor with the capture engine

    func testOverlayMinimumMatchesTheEncoderMinimum() {
        XCTAssertEqual(AreaSelectionGeometry.minimumSide, CaptureGeometry.minimumSide,
                       "the overlay must never hand the engine a rect it would refuse")
    }
}
