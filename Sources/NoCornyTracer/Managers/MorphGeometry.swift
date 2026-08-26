import CoreGraphics

// MARK: - Command bar surfaces

/// Which drawer the command bar has open under it.
enum CommandBarDrawerTab: Equatable {
    case gallery
    case settings
}

/// The shapes the floating command-bar panel can take. One panel morphs between
/// them (phase 2 of the redesign); the drawer content and the recording pill are
/// placeholder views until phases 3 and 4.
enum CommandBarSurface: Equatable {
    /// The compact 560×80 bar.
    case bar
    /// The bar with a 560×332 drawer hanging under it (gap `MorphGeometry.drawerGap`).
    case barWithDrawer(CommandBarDrawerTab)
    /// The 341×54 pill the bar collapses into while recording (phase 4; grown
    /// from 292 in round 3 for the mic/cam toggles and the hide button).
    case recordingPill
}

// MARK: - Morph geometry

/// Pure frame math for morphing the command-bar panel between surfaces.
///
/// Everything here works on the LOGICAL frame — the rectangle the glass surface
/// visually occupies. The actual NSPanel is `panelShadowInset` larger on every side
/// so the SwiftUI-drawn shadow (`.floatingPanelShadow()`, radius 27.5, y-offset 22)
/// has transparent room to render instead of being clipped at the window edge
/// (the panel itself has `hasShadow = false`).
///
/// Coordinates are AppKit screen coordinates: origin bottom-left, y grows UP.
/// "Top-left" of a rect is therefore `(minX, maxY)`.
enum MorphGeometry {

    /// Vertical gap between the bar and its drawer. Measured on the macro frame 59:3:
    /// bar at y=70 with height 80, drawer at y=166 → 166 − 150 = 16.
    static let drawerGap: CGFloat = 16

    /// Height of the amber storage banner under the bar (macro 87:1851: 560×38).
    static let storageBannerHeight: CGFloat = 38

    /// Gap between the bar's bottom edge and the storage banner. Measured on macro
    /// frame 87:1810: bar at y=70 with height 80, banner at y=162 → 162 − 150 = 12.
    static let bannerGap: CGFloat = 12

    /// The extra logical height the visible storage banner adds under the bar
    /// (gap + banner). This is the value callers pass as `bannerHeight`.
    static var storageBannerExtent: CGFloat { bannerGap + storageBannerHeight }

    /// Extra logical WIDTH of the bar row while the update chip is present
    /// (round 7, hybrid A→B): the compact 38pt chip plus the 13pt gap it adds
    /// between the settings button and the spacer. Bar 560 → 611.
    static let updateChipExtent: CGFloat = 51

    /// The hover remainder (round 7 correction): unrolling the chip 38→87
    /// costs 49pt; the bar's flexible spacer donates its ~29pt first, and only
    /// this remainder grows the panel (611 → 631) — with the same spring, so
    /// no button left of the chip moves. See CommandBarView.barRowWidth.
    static let updateChipHoverExtra: CGFloat = 20

    /// Transparent margin around the logical surface inside the panel, reserved for
    /// the SwiftUI shadow. 60pt comfortably covers radius 27.5 + y-offset 22.
    static let panelShadowInset: CGFloat = 60

    /// Logical (visible-glass) size of a surface.
    ///
    /// `bannerHeight` is the extra height of the storage banner (`storageBannerExtent`,
    /// or 0 when hidden). It applies ONLY to `.bar`: the recording pill stays minimal
    /// mid-take and the drawer's Dropbox row already shows the quota, so neither
    /// surface carries the banner — a deliberate phase-4 decision, not an omission.
    ///
    /// `pillExtraWidth` (round 3) is the pill's counterpart: extra width past the
    /// designer's 341-pt base for transient content the mockup doesn't draw — a
    /// 100+ minute timer outgrowing its 57-pt slot. It applies ONLY to
    /// `.recordingPill`; anchors and the perch flight stay computed from the base.
    ///
    /// `chipExtraWidth` (round 7) widens the BAR ROW for the update chip
    /// (`updateChipExtent` compact, plus `updateChipHoverExtra` while hovered;
    /// 0 with no update pending). It applies to `.bar` AND `.barWithDrawer` —
    /// the bar row shows the chip in both — and never to the pill, which
    /// carries no chip. Growth goes to the RIGHT of the held top-left anchor,
    /// same contract as the pill's extra width.
    static func size(
        of surface: CommandBarSurface,
        bannerHeight: CGFloat = 0,
        pillExtraWidth: CGFloat = 0,
        chipExtraWidth: CGFloat = 0
    ) -> CGSize {
        switch surface {
        case .bar:
            return CGSize(
                width: Theme.Metrics.commandBarSize.width + max(0, chipExtraWidth),
                height: Theme.Metrics.commandBarSize.height + bannerHeight
            )
        case .barWithDrawer:
            return CGSize(
                width: Theme.Metrics.commandBarSize.width + max(0, chipExtraWidth),
                height: Theme.Metrics.commandBarSize.height + drawerGap + Theme.Metrics.drawerSize.height
            )
        case .recordingPill:
            return CGSize(
                width: Theme.Metrics.recordingPillSize.width + max(0, pillExtraWidth),
                height: Theme.Metrics.recordingPillSize.height
            )
        }
    }

    /// Breathing room the drawer keeps from the visible-frame edge when judging
    /// whether a direction "fits" (verdict 26.08): a drawer that would land flush
    /// against the Dock or the menu bar is treated as not fitting.
    static let drawerFitMargin: CGFloat = 16

    /// Which way a drawer opens from a bar whose TOP-LEFT sits at `anchorTopLeft`.
    ///
    /// Policy (verdict 26.08 from the 4.2.0 build — «іноді відкриває вгору, хоча
    /// знизу місця досить» — replaces the old half-screen rule): DOWNWARD whenever
    /// the full drawer surface fits under the bar with `drawerFitMargin` to spare;
    /// only when it doesn't, UPWARD if that direction fits the same way; and when
    /// neither fits, downward again — `targetFrame`'s slide-into-bounds clamp
    /// takes over from there. The banner never joins this math: the drawer
    /// surface REPLACES the banner (only `.bar` renders it), so the drawer frame
    /// is the whole story. The bar itself never moves in either direction — only
    /// the surface grows past it (the slide-into-bounds fallback is the sole
    /// exception).
    static func drawerOpensUpward(anchorTopLeft: CGPoint, visible: CGRect) -> Bool {
        let drawerSize = size(of: .barWithDrawer(.gallery))
        let downFits = anchorTopLeft.y - drawerSize.height >= visible.minY + drawerFitMargin
        if downFits { return false }
        let barHeight = Theme.Metrics.commandBarSize.height
        let upFits = anchorTopLeft.y - barHeight + drawerSize.height <= visible.maxY - drawerFitMargin
        return upFits
    }

    /// Where a surface should sit. `anchorTopLeft` is ALWAYS the top-left of the
    /// BAR — the stable point every morph is computed from.
    ///
    /// - `.bar` / `.recordingPill`: the surface hangs from the anchor (the banner
    ///   grows downward under the bar).
    /// - `.recordingPill` with `pillExtraWidth` (round 3): the surface grows to the
    ///   RIGHT of the held top-left anchor — chosen over symmetric growth because
    ///   the stop button sits at the leading edge, and the leading edge holding
    ///   still is what keeps that button under an approaching cursor. Symmetric
    ///   growth would shift it left by half the extra whenever the timer widens.
    /// - `.barWithDrawer`: direction per `drawerOpensUpward` — downward keeps the
    ///   anchor as the surface's top-left; upward keeps the BAR in place (surface
    ///   bottom = the bar's bottom edge) and the drawer unfolds above it.
    /// - Fits in neither direction: slides vertically into the visible bounds.
    /// - Doesn't fit to the right: slides left (and never past the left edge).
    static func targetFrame(
        anchorTopLeft: CGPoint,
        surface: CommandBarSurface,
        bannerHeight: CGFloat = 0,
        pillExtraWidth: CGFloat = 0,
        chipExtraWidth: CGFloat = 0,
        visible: CGRect
    ) -> CGRect {
        let size = size(
            of: surface, bannerHeight: bannerHeight,
            pillExtraWidth: pillExtraWidth, chipExtraWidth: chipExtraWidth
        )

        var x = anchorTopLeft.x
        if x + size.width > visible.maxX { x = visible.maxX - size.width }
        if x < visible.minX { x = visible.minX }

        // AppKit y grows upward: growing DOWN from the anchor lowers the origin.
        let downwardOriginY = anchorTopLeft.y - size.height
        // Growing UP holds the bar's bottom edge as the surface's bottom edge.
        let upwardOriginY = anchorTopLeft.y - Theme.Metrics.commandBarSize.height

        let opensUp: Bool
        if case .barWithDrawer = surface {
            opensUp = drawerOpensUpward(anchorTopLeft: anchorTopLeft, visible: visible)
        } else {
            opensUp = false
        }

        let y: CGFloat
        if opensUp, upwardOriginY + size.height <= visible.maxY, upwardOriginY >= visible.minY {
            y = upwardOriginY
        } else if !opensUp, downwardOriginY >= visible.minY {
            y = downwardOriginY
        } else {
            // The chosen direction has no room — slide into bounds.
            y = min(max(downwardOriginY, visible.minY), visible.maxY - size.height)
        }

        // Final full clamp (round 6, «плашка не повинна покидати рамки екрану»):
        // the branches above clamp the bottom edge but let a stale anchor — saved
        // on a taller display, say — hang the surface past the TOP of the visible
        // frame. Every programmatic frame going through this one clamp is also
        // what keeps the flight unions in-bounds, so the panel-side drag clamp
        // (`clampedIntoVisible` via CommandBarPanel) never fights a morph.
        return clampedIntoVisible(
            CGRect(x: x, y: y, width: size.width, height: size.height),
            visible: visible
        )
    }

    /// Slides a LOGICAL surface frame fully into `visible` (the CameraOverlayWindow
    /// clamp recipe): each axis pins to the near edge, and when the frame is larger
    /// than the visible frame the min edge wins — the surface overflows on one side
    /// only, deterministically. Shared by `targetFrame` (programmatic placement) and
    /// the panel's drag clamp (round 6).
    static func clampedIntoVisible(_ frame: CGRect, visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = max(visible.minX, min(f.origin.x, visible.maxX - f.width))
        f.origin.y = max(visible.minY, min(f.origin.y, visible.maxY - f.height))
        return f
    }

    /// The drag clamp in PANEL coordinates (round 6): strips the shadow margin,
    /// clamps the GLASS into the visible frame, puts the margin back. Clamping the
    /// raw panel frame would be wrong by `panelShadowInset` on every side — the
    /// transparent shadow apron is supposed to hang past the screen edge when the
    /// glass sits flush against it.
    static func clampedPanelFrame(_ panel: CGRect, visible: CGRect) -> CGRect {
        panelFrame(forLogical: clampedIntoVisible(logicalFrame(forPanel: panel), visible: visible))
    }

    /// The bar's top-left anchor recovered from a surface frame — the inverse of
    /// `targetFrame` for the non-slide cases. Needed because an upward-opened
    /// drawer's frame has the bar at its BOTTOM, not its top.
    static func barAnchor(
        forSurfaceFrame frame: CGRect,
        surface: CommandBarSurface,
        opensUp: Bool
    ) -> CGPoint {
        if case .barWithDrawer = surface, opensUp {
            return CGPoint(x: frame.minX, y: frame.minY + Theme.Metrics.commandBarSize.height)
        }
        return CGPoint(x: frame.minX, y: frame.maxY)
    }

    /// Default position for a fresh install (no persisted origin): centered
    /// horizontally, hanging 120pt below the top of the visible frame — the bar
    /// hangs near the top of the screen in the macro.
    static func initialOrigin(for size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - 120 - size.height
        )
    }

    /// Top inset of the recording pill's default perch (verdict 25.08: the pill
    /// flies to a tidy spot on record-start instead of collapsing in place).
    /// 64pt below the top of the VISIBLE frame — i.e. under the menu bar.
    static let recordingPillTopInset: CGFloat = 64

    /// The pill's default TOP-LEFT: centered horizontally, 64pt down from the top
    /// of the visible frame. A pill the user dragged mid-take overrides this via
    /// its own persisted anchor (mirroring the camera bubble's behaviour).
    static func recordingPillTopLeft(visible: CGRect) -> CGPoint {
        CGPoint(
            x: visible.midX - Theme.Metrics.recordingPillSize.width / 2,
            y: visible.maxY - recordingPillTopInset
        )
    }

    // MARK: Compositor flight (round 5c)

    /// Where a surface frame sits INSIDE a container frame, expressed as the
    /// SwiftUI offset of content pinned to the container's TOP-LEADING corner.
    /// AppKit y grows up, SwiftUI y grows down — hence the maxY flip.
    ///
    /// Round 5c (verdict 26.08, «рідні анімації мають більше fps»): the pill
    /// flight no longer animates the window frame tick-by-tick. The panel takes
    /// the UNION of the two endpoint frames in one jump and the CONTENT flies
    /// across it on an animated offset — this function is the coordinate bridge
    /// between the two worlds.
    static func contentOffset(of frame: CGRect, in container: CGRect) -> CGSize {
        CGSize(
            width: frame.minX - container.minX,
            height: container.maxY - frame.maxY
        )
    }

    /// Whether extending `current` to also cover `target` keeps the union's
    /// TOP-LEFT corner — the coordinate base of a live flight offset — exactly
    /// where it is. Growing to the right or downward is free; growing left or
    /// upward moves the base and would invalidate an in-flight offset.
    static func unionKeepsTopLeft(current: CGRect, adding target: CGRect) -> Bool {
        let union = current.union(target)
        return union.minX == current.minX && union.maxY == current.maxY
    }

    /// The NSPanel frame for a logical surface frame (adds the shadow margin).
    static func panelFrame(forLogical logical: CGRect) -> CGRect {
        logical.insetBy(dx: -panelShadowInset, dy: -panelShadowInset)
    }

    /// The logical surface frame inside a panel frame (strips the shadow margin).
    static func logicalFrame(forPanel panel: CGRect) -> CGRect {
        panel.insetBy(dx: panelShadowInset, dy: panelShadowInset)
    }
}
