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
    /// The 292×54 pill the bar collapses into while recording (phase 4).
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

    /// Transparent margin around the logical surface inside the panel, reserved for
    /// the SwiftUI shadow. 60pt comfortably covers radius 27.5 + y-offset 22.
    static let panelShadowInset: CGFloat = 60

    /// Logical (visible-glass) size of a surface.
    ///
    /// `bannerHeight` is the extra height of the storage banner (`storageBannerExtent`,
    /// or 0 when hidden). It applies ONLY to `.bar`: the recording pill stays minimal
    /// mid-take and the drawer's Dropbox row already shows the quota, so neither
    /// surface carries the banner — a deliberate phase-4 decision, not an omission.
    static func size(of surface: CommandBarSurface, bannerHeight: CGFloat = 0) -> CGSize {
        switch surface {
        case .bar:
            return CGSize(
                width: Theme.Metrics.commandBarSize.width,
                height: Theme.Metrics.commandBarSize.height + bannerHeight
            )
        case .barWithDrawer:
            return CGSize(
                width: Theme.Metrics.commandBarSize.width,
                height: Theme.Metrics.commandBarSize.height + drawerGap + Theme.Metrics.drawerSize.height
            )
        case .recordingPill:
            return Theme.Metrics.recordingPillSize
        }
    }

    /// Which way a drawer opens from a bar whose TOP-LEFT sits at `anchorTopLeft`
    /// (verdict 25.08: direction follows the HALF of the screen, not just fit).
    /// Bar center in the LOWER half of the visible frame → the drawer unfolds
    /// UPWARD (above the stationary bar); upper half or dead center → downward.
    /// Fit still overrides preference: a direction with no room yields to the
    /// other. The bar itself never moves in either direction — only the surface
    /// grows past it (the slide-into-bounds fallback is the sole exception).
    static func drawerOpensUpward(anchorTopLeft: CGPoint, visible: CGRect) -> Bool {
        let barHeight = Theme.Metrics.commandBarSize.height
        let barCenterY = anchorTopLeft.y - barHeight / 2
        let prefersUp = barCenterY < visible.midY

        let drawerSize = size(of: .barWithDrawer(.gallery))
        let upFits = anchorTopLeft.y - barHeight + drawerSize.height <= visible.maxY
        let downFits = anchorTopLeft.y - drawerSize.height >= visible.minY

        if prefersUp { return upFits || !downFits }
        return !downFits && upFits
    }

    /// Where a surface should sit. `anchorTopLeft` is ALWAYS the top-left of the
    /// BAR — the stable point every morph is computed from.
    ///
    /// - `.bar` / `.recordingPill`: the surface hangs from the anchor (the banner
    ///   grows downward under the bar).
    /// - `.barWithDrawer`: direction per `drawerOpensUpward` — downward keeps the
    ///   anchor as the surface's top-left; upward keeps the BAR in place (surface
    ///   bottom = the bar's bottom edge) and the drawer unfolds above it.
    /// - Fits in neither direction: slides vertically into the visible bounds.
    /// - Doesn't fit to the right: slides left (and never past the left edge).
    static func targetFrame(
        anchorTopLeft: CGPoint,
        surface: CommandBarSurface,
        bannerHeight: CGFloat = 0,
        visible: CGRect
    ) -> CGRect {
        let size = size(of: surface, bannerHeight: bannerHeight)

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

        return CGRect(x: x, y: y, width: size.width, height: size.height)
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

    /// The NSPanel frame for a logical surface frame (adds the shadow margin).
    static func panelFrame(forLogical logical: CGRect) -> CGRect {
        logical.insetBy(dx: -panelShadowInset, dy: -panelShadowInset)
    }

    /// The logical surface frame inside a panel frame (strips the shadow margin).
    static func logicalFrame(forPanel panel: CGRect) -> CGRect {
        panel.insetBy(dx: panelShadowInset, dy: panelShadowInset)
    }
}
