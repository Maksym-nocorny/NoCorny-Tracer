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

    /// Transparent margin around the logical surface inside the panel, reserved for
    /// the SwiftUI shadow. 60pt comfortably covers radius 27.5 + y-offset 22.
    static let panelShadowInset: CGFloat = 60

    /// Logical (visible-glass) size of a surface.
    static func size(of surface: CommandBarSurface) -> CGSize {
        switch surface {
        case .bar:
            return Theme.Metrics.commandBarSize
        case .barWithDrawer:
            return CGSize(
                width: Theme.Metrics.commandBarSize.width,
                height: Theme.Metrics.commandBarSize.height + drawerGap + Theme.Metrics.drawerSize.height
            )
        case .recordingPill:
            return Theme.Metrics.recordingPillSize
        }
    }

    /// Where a surface should sit, holding the current TOP-LEFT anchor when possible.
    ///
    /// - Doesn't fit downward (a drawer opening near the Dock): opens UPWARD — the
    ///   anchor becomes the bottom-left corner.
    /// - Fits in neither direction: slides vertically into the visible bounds.
    /// - Doesn't fit to the right: slides left (and never past the left edge).
    static func targetFrame(anchorTopLeft: CGPoint, surface: CommandBarSurface, visible: CGRect) -> CGRect {
        let size = size(of: surface)

        var x = anchorTopLeft.x
        if x + size.width > visible.maxX { x = visible.maxX - size.width }
        if x < visible.minX { x = visible.minX }

        // AppKit y grows upward: growing DOWN from the anchor lowers the origin.
        let downwardOriginY = anchorTopLeft.y - size.height
        let y: CGFloat
        if downwardOriginY >= visible.minY {
            y = downwardOriginY
        } else if anchorTopLeft.y + size.height <= visible.maxY {
            // Open upward: the anchor point becomes the bottom-left corner.
            y = anchorTopLeft.y
        } else {
            // Neither direction fits cleanly — slide into bounds.
            y = min(max(downwardOriginY, visible.minY), visible.maxY - size.height)
        }

        return CGRect(x: x, y: y, width: size.width, height: size.height)
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

    /// The NSPanel frame for a logical surface frame (adds the shadow margin).
    static func panelFrame(forLogical logical: CGRect) -> CGRect {
        logical.insetBy(dx: -panelShadowInset, dy: -panelShadowInset)
    }

    /// The logical surface frame inside a panel frame (strips the shadow margin).
    static func logicalFrame(forPanel panel: CGRect) -> CGRect {
        panel.insetBy(dx: panelShadowInset, dy: panelShadowInset)
    }
}
