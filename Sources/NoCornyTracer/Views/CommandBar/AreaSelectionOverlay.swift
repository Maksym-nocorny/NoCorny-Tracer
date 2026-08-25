import SwiftUI
import AppKit

// MARK: - Geometry (pure, covered by AreaSelectionGeometryTests)

/// The math of the area-selection overlay, kept free of AppKit and views so every rule
/// is testable without a screen — same split as CaptureGeometry, which consumes this
/// file's output at record time.
///
/// Every rect and point here lives in the overlay's own coordinate space: POINTS with
/// the origin at the TOP-LEFT of the screen, y growing downwards. The overlay panel
/// covers the display exactly (frame == screen.frame), which makes SwiftUI's local
/// space identical to the display's logical coordinate space — the space
/// SCStreamConfiguration.sourceRect is documented to use. A committed rect is therefore
/// saved into CaptureSelection.areaRect UNCHANGED, in points; only the size badge
/// multiplies by the backing scale, because people think of capture sizes in pixels.
enum AreaSelectionGeometry {

    /// Same floor as the capture engine (64pt): the overlay never produces a selection
    /// the encoder would refuse. Enforced live during the drag — the marquee simply
    /// clamps to 64×64 rather than turning red or refusing Enter.
    static let minimumSide: CGFloat = CaptureGeometry.minimumSide

    // MARK: Handles

    /// The eight resize handles, named by the corner/edge they sit on.
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var isCorner: Bool {
            switch self {
            case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
            case .top, .right, .bottom, .left: return false
            }
        }

        var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// Where a handle sits: centred ON the selection boundary (design handoff).
    static func handleCenter(_ handle: Handle, in rect: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: rect.minX, y: rect.minY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: return CGPoint(x: rect.maxX, y: rect.minY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: return CGPoint(x: rect.minX, y: rect.maxY)
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// Corners first: on a minimum-size selection a corner and a midpoint are 32pt
    /// apart, but the corner is the more precise intent when both are within reach.
    private static let handleHitOrder: [Handle] = [
        .topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left
    ]

    /// The handle under a press, if any. The hit zone (±11pt) is a little larger than
    /// the drawn handle (12pt corner / 10pt midpoint) so grabbing one does not require
    /// pixel aim.
    static func handle(at point: CGPoint, in rect: CGRect, tolerance: CGFloat = 11) -> Handle? {
        handleHitOrder.first { handle in
            let center = handleCenter(handle, in: rect)
            return abs(point.x - center.x) <= tolerance && abs(point.y - center.y) <= tolerance
        }
    }

    // MARK: Drags

    /// A fresh marquee between the press point and the current cursor, any drag
    /// direction. Both points are clamped into the screen first; the result is pushed
    /// through the capture engine's own clamp (min 64, inside the display) so what the
    /// overlay draws IS what a recording would use.
    static func marqueeRect(from start: CGPoint, to current: CGPoint, in bounds: CGRect) -> CGRect {
        let a = clampPoint(start, in: bounds)
        let b = clampPoint(current, in: bounds)
        let raw = CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
        return CaptureGeometry.clampedAreaRect(raw, in: bounds)
    }

    /// Drag inside the selection: the rect moves by the gesture's translation and
    /// stops at the screen edges (never shrinks, never leaves the display).
    static func movedRect(_ rect: CGRect, by translation: CGSize, in bounds: CGRect) -> CGRect {
        var r = rect.standardized
        r.origin.x = min(max(r.minX + translation.width, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY + translation.height, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// Drag on a handle: the edge(s) the handle owns follow the cursor, the opposite
    /// edges stay pinned, and the moving edge stops `minimumSide` short of its
    /// opposite — dragging "past" the far edge clamps rather than flipping the rect.
    static func resizedRect(_ rect: CGRect, handle: Handle, to location: CGPoint, in bounds: CGRect) -> CGRect {
        let p = clampPoint(location, in: bounds)
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if handle.movesLeftEdge { minX = min(p.x, maxX - minimumSide) }
        if handle.movesRightEdge { maxX = max(p.x, minX + minimumSide) }
        if handle.movesTopEdge { minY = min(p.y, maxY - minimumSide) }
        if handle.movesBottomEdge { maxY = max(p.y, minY + minimumSide) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Size badge

    /// The badge shows PIXELS (design handoff): points × the display's backing scale,
    /// rounded to whole pixels. The saved rect stays in points — this conversion is
    /// display-only.
    static func pixelSize(of rect: CGRect, scale: CGFloat) -> (width: Int, height: Int) {
        (Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded()))
    }

    static func badgeText(for rect: CGRect, scale: CGFloat) -> String {
        let px = pixelSize(of: rect, scale: scale)
        return "\(px.width) × \(px.height)"
    }

    // MARK: Internals

    private static func clampPoint(_ point: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

// MARK: - Model

/// The overlay's live state, owned by AreaSelectionWindowManager so the panel's
/// Enter/Esc handling and the SwiftUI content look at the same rect.
@Observable @MainActor
final class AreaSelectionModel {
    /// The screen in overlay coordinates: origin .zero, size = screen size in points.
    let bounds: CGRect
    /// Points → pixels for the size badge (NSScreen.backingScaleFactor; the same value
    /// SCContentFilter.pointPixelScale reports at record time).
    let scale: CGFloat
    /// The current selection, nil until the first drag (or prefilled from a remembered
    /// area). Always ≥ 64×64 and fully inside `bounds` — every mutation goes through
    /// AreaSelectionGeometry.
    var rect: CGRect?

    init(bounds: CGRect, scale: CGFloat, rect: CGRect? = nil) {
        self.bounds = bounds
        self.scale = scale
        self.rect = rect
    }
}

// MARK: - Overlay view

/// Full-screen area picker (design handoff, Figma macro 544:1652).
///
/// Anatomy: a 62% black dim covering everything EXCEPT the selection (clean
/// pass-through inside), the brand frame — four dashed edges with open corners —
/// eight resize handles, a pixel-size badge under the frame, and a hint pill. Before
/// the first drag the dim is solid and only the hint shows.
///
/// All input comes through ONE full-screen drag gesture; what a drag does is decided
/// by where it starts: on a handle → resize, inside the selection → move, anywhere
/// else → a fresh marquee. A single gesture layer means the plates, frame and handles
/// never fight over hits.
struct AreaSelectionOverlayView: View {
    @Bindable var model: AreaSelectionModel

    @State private var dragMode: DragMode? = nil

    private enum DragMode {
        case marquee(anchor: CGPoint)
        case move(original: CGRect)
        case resize(AreaSelectionGeometry.Handle)
    }

    /// Brand selection blue (#5AA2FF, design handoff). Fixed, not adaptive: the
    /// overlay always draws over its own black dim, never over app chrome.
    private static let accent = Color(hex: 0x5AA2FF)

    var body: some View {
        ZStack {
            dimming

            if let rect = model.rect {
                selectionFrame(rect)
                handles(rect)
                sizeBadge(rect)
            }

            hintPill
        }
        .frame(width: model.bounds.width, height: model.bounds.height)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        // Round 3: the cursor narrates what a drag would do — per-handle resize
        // arrows (macOS 15+; the frameResize cursors don't exist below), an open
        // hand inside the selection (drag = move), crosshair everywhere else
        // (drag = fresh marquee). `set()` layers over the crosshair the manager
        // pushed for the overlay's lifetime, so its push/pop balance is untouched.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                Self.cursor(at: location, selection: model.rect).set()
            case .ended:
                NSCursor.crosshair.set()
            }
        }
        .ignoresSafeArea()
    }

    /// Which cursor belongs at a point — mirrors `mode(forDragStartingAt:)`, so
    /// what the cursor promises is exactly what the drag will do.
    static func cursor(at point: CGPoint, selection: CGRect?) -> NSCursor {
        guard let selection else { return .crosshair }
        if let handle = AreaSelectionGeometry.handle(at: point, in: selection) {
            if #available(macOS 15.0, *) {
                return .frameResize(position: Self.resizePosition(for: handle), directions: .all)
            }
            return .crosshair
        }
        if selection.contains(point) { return .openHand }
        return .crosshair
    }

    @available(macOS 15.0, *)
    private static func resizePosition(
        for handle: AreaSelectionGeometry.Handle
    ) -> NSCursor.FrameResizePosition {
        switch handle {
        case .topLeft: return .topLeft
        case .top: return .top
        case .topRight: return .topRight
        case .right: return .right
        case .bottomRight: return .bottomRight
        case .bottom: return .bottom
        case .bottomLeft: return .bottomLeft
        case .left: return .left
        }
    }

    // MARK: Dimming (black 62%, four plates around the selection)

    /// One even-odd path instead of four positioned plates: the full screen minus the
    /// selection rect fills identically to four plates around it, with no seams and
    /// no per-plate layout, and the inside stays a genuinely clear pass-through.
    private var dimming: some View {
        Path { path in
            path.addRect(model.bounds)
            if let rect = model.rect {
                path.addRect(rect)
            }
        }
        .fill(Color.black.opacity(0.62), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    // MARK: Frame (four dashed edges, open corners — the brand mark of the app)

    /// Each edge starts and ends 20pt short of its corners, 3pt thick along the INNER
    /// side of the boundary (stroke centred 1.5pt inside), dashed 15/12 (handoff).
    private func selectionFrame(_ rect: CGRect) -> some View {
        let inset: CGFloat = 1.5   // half the 3pt stroke → outer stroke edge on the boundary
        let gap: CGFloat = 20
        return Path { path in
            // Top
            path.move(to: CGPoint(x: rect.minX + gap, y: rect.minY + inset))
            path.addLine(to: CGPoint(x: rect.maxX - gap, y: rect.minY + inset))
            // Bottom
            path.move(to: CGPoint(x: rect.minX + gap, y: rect.maxY - inset))
            path.addLine(to: CGPoint(x: rect.maxX - gap, y: rect.maxY - inset))
            // Left
            path.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + gap))
            path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - gap))
            // Right
            path.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + gap))
            path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - gap))
        }
        .stroke(Self.accent, style: StrokeStyle(lineWidth: 3, dash: [15, 12]))
        .allowsHitTesting(false)
    }

    // MARK: Handles (corners 12×12, midpoints 10×10, centred on the boundary)

    private func handles(_ rect: CGRect) -> some View {
        ForEach(AreaSelectionGeometry.Handle.allCases, id: \.self) { handle in
            let side: CGFloat = handle.isCorner ? 12 : 10
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Self.accent, lineWidth: 1.5)
                )
                .frame(width: side, height: side)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)
                .position(AreaSelectionGeometry.handleCenter(handle, in: rect))
                .allowsHitTesting(false)   // hits resolve in the unified gesture
        }
    }

    // MARK: Size badge (h28 r8, black 72%, JetBrains Mono 13, pixels)

    private func sizeBadge(_ rect: CGRect) -> some View {
        Text(AreaSelectionGeometry.badgeText(for: rect, scale: model.scale))
            .font(Theme.Typography.timer(13))
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .fixedSize()
            .position(badgePosition(for: rect))
            .allowsHitTesting(false)
    }

    /// Centred under the frame with a 10pt gap; flips to just inside the bottom edge
    /// of the selection when the frame sits too low for the badge to fit on screen.
    private func badgePosition(for rect: CGRect) -> CGPoint {
        let half: CGFloat = 14   // badge height 28
        let below = rect.maxY + 10 + half
        let y = below + half <= model.bounds.maxY ? below : rect.maxY - 10 - half
        let x = min(max(rect.midX, 70), model.bounds.maxX - 70)
        return CGPoint(x: x, y: y)
    }

    // MARK: Hint pill (h36 r18, bottom-centre)

    /// Same black-72% surface as the badge rather than glassSurface (the handoff left
    /// the choice open): the panel's behind-window blur would sample the UNdimmed
    /// wallpaper behind the panel, so on light wallpapers glass could wash out under
    /// white text — the solid dark pill keeps deterministic contrast on any desktop,
    /// and the overlay reads as one family (badge + hint on the same surface).
    ///
    /// One fixed spot — bottom-centre of the screen — in both states (before the first
    /// drag and with a selection up), so the instructions never jump around while the
    /// user drags.
    private var hintPill: some View {
        Text("Drag to select area · Enter to start · Esc to cancel")
            .font(.system(size: 13))
            .foregroundStyle(Color.white.opacity(0.88))
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .fixedSize()
            .position(x: model.bounds.midX, y: model.bounds.maxY - 64)
            .allowsHitTesting(false)
    }

    // MARK: Input

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { value in
                if dragMode == nil {
                    dragMode = Self.mode(forDragStartingAt: value.startLocation, selection: model.rect)
                }
                switch dragMode {
                case .marquee(let anchor):
                    model.rect = AreaSelectionGeometry.marqueeRect(
                        from: anchor, to: value.location, in: model.bounds
                    )
                case .move(let original):
                    model.rect = AreaSelectionGeometry.movedRect(
                        original, by: value.translation, in: model.bounds
                    )
                case .resize(let handle):
                    if let rect = model.rect {
                        model.rect = AreaSelectionGeometry.resizedRect(
                            rect, handle: handle, to: value.location, in: model.bounds
                        )
                    }
                case nil:
                    break
                }
            }
            .onEnded { _ in
                dragMode = nil
            }
    }

    /// What a fresh drag means, decided ONCE from its starting point and held for the
    /// whole gesture: a handle wins over the interior (they overlap on the boundary),
    /// the interior moves, anywhere else starts a new marquee.
    private static func mode(forDragStartingAt start: CGPoint, selection: CGRect?) -> DragMode {
        guard let selection else { return .marquee(anchor: start) }
        if let handle = AreaSelectionGeometry.handle(at: start, in: selection) {
            return .resize(handle)
        }
        if selection.contains(start) {
            return .move(original: selection)
        }
        return .marquee(anchor: start)
    }
}
