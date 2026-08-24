import Foundation
import CoreGraphics

/// Pure sizing math for the capture stream, one mode in — one output spec out.
/// ScreenRecorder copies the result into SCStreamConfiguration; nothing here imports
/// ScreenCaptureKit, so every formula is testable without a screen.
///
/// Units, because they are the whole trap here:
/// - `sourceRect` is in POINTS in the display's logical coordinate space. That is what
///   SCStreamConfiguration.sourceRect takes — SCStream.h says verbatim: "The rectangle is
///   specified in points in the display's logical coordinate system." Multiplying it by
///   the scale factor would crop a quarter of a Retina display.
/// - `width`/`height` are in PIXELS (the output surface), so THEY are the ones that get
///   multiplied by `scaleFactor` (SCContentFilter.pointPixelScale — 2 on Retina).
enum CaptureGeometry {

    /// What SCStreamConfiguration needs to know about the output.
    struct Output: Equatable {
        /// Subrect of the display to sample, in points (see above). nil = sample
        /// everything the content filter provides.
        var sourceRect: CGRect?
        /// Output surface size in pixels. Always even on both sides — the H.264 encoder
        /// refuses odd dimensions.
        var width: Int
        var height: Int
    }

    /// Smallest capture side, in points for the area rect and in pixels for the output.
    /// Keeps a stray 3×3 drag from asking the encoder for a degenerate surface.
    static let minimumSide: CGFloat = 64

    /// - Parameters:
    ///   - displayBounds: the target display's size in points, origin at .zero
    ///     (`CGRect(x: 0, y: 0, width: display.width, height: display.height)`).
    ///   - areaRect: `.selectedArea` only — the chosen rect in the display's local points.
    ///   - windowFrame: `.window` only — the window's frame in points (only its size is used;
    ///     a desktopIndependentWindow filter delivers the whole window, no sourceRect needed).
    ///   - scaleFactor: points→pixels scale (SCContentFilter.pointPixelScale). Ignored for
    ///     `.entireScreen`, whose output is sized by the requested resolution instead.
    ///   - requestedHeight: the resolution setting (1080 for "1080p"). Only `.entireScreen`
    ///     uses it — window and area outputs are native-size × scale.
    ///
    /// A mode whose inputs are missing (window without a frame, area without a rect) falls
    /// back to the entire-screen formula rather than crashing or guessing: the recorder
    /// treats those as programmer errors upstream, but a full-screen recording is the
    /// harmless answer if one slips through.
    static func outputConfig(
        mode: CaptureMode,
        displayBounds: CGRect,
        areaRect: CGRect?,
        windowFrame: CGRect?,
        scaleFactor: CGFloat,
        requestedHeight: Int
    ) -> Output {
        switch mode {
        case .entireScreen:
            return fullDisplayOutput(displayBounds: displayBounds, requestedHeight: requestedHeight)

        case .window:
            guard let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else {
                return fullDisplayOutput(displayBounds: displayBounds, requestedHeight: requestedHeight)
            }
            return Output(
                sourceRect: nil,
                width: evenPixels(windowFrame.width * scaleFactor),
                height: evenPixels(windowFrame.height * scaleFactor)
            )

        case .selectedArea:
            guard let areaRect, displayBounds.width > 0, displayBounds.height > 0 else {
                return fullDisplayOutput(displayBounds: displayBounds, requestedHeight: requestedHeight)
            }
            let rect = clampedAreaRect(areaRect, in: displayBounds)
            return Output(
                sourceRect: rect,
                width: evenPixels(rect.width * scaleFactor),
                height: evenPixels(rect.height * scaleFactor)
            )
        }
    }

    /// The area rect, made recordable: at least `minimumSide` on each side, no larger than
    /// the display, and moved (not shrunk) back inside the display's bounds. Grows around
    /// its own origin; the origin only shifts when the grown rect would hang over an edge.
    static func clampedAreaRect(_ rect: CGRect, in displayBounds: CGRect) -> CGRect {
        let bounds = displayBounds.standardized
        var r = rect.standardized
        r.size.width = min(max(r.width, min(minimumSide, bounds.width)), bounds.width)
        r.size.height = min(max(r.height, min(minimumSide, bounds.height)), bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    // MARK: - Internals

    /// The exact formula that lived inline in ScreenRecorder.startCapture since phase 0:
    /// target the requested height, scale the width by the display's aspect ratio, round to
    /// even. Moved here verbatim so all three modes share one home and the old behaviour is
    /// pinned by fixtures in CaptureGeometryTests.
    private static func fullDisplayOutput(displayBounds: CGRect, requestedHeight: Int) -> Output {
        guard displayBounds.width > 0, displayBounds.height > 0 else {
            // No display geometry at all — 16:9 at the requested height beats dividing by zero.
            var width = Int((Double(requestedHeight) * 16.0 / 9.0).rounded())
            if width % 2 != 0 { width += 1 }
            return Output(sourceRect: nil, width: width, height: requestedHeight)
        }
        let displayAspect = Double(displayBounds.width) / Double(displayBounds.height)
        let outHeight = requestedHeight
        var outWidth = Int((Double(outHeight) * displayAspect).rounded())
        if outWidth % 2 != 0 { outWidth += 1 }
        return Output(sourceRect: nil, width: outWidth, height: outHeight)
    }

    /// Points × scale → whole pixels, rounded to the nearest and then bumped UP to even
    /// (same direction the old inline formula bumped), floored at `minimumSide`.
    private static func evenPixels(_ value: CGFloat) -> Int {
        var pixels = Int(value.rounded())
        if pixels % 2 != 0 { pixels += 1 }
        return max(pixels, Int(minimumSide))
    }
}
