import SwiftUI

/// The bar's "update ready" chip (round 7 — the boss's final pick: HYBRID A→B).
///
/// At REST it is variant A: a 38×38 round button between the settings button and
/// the close cross, wearing the designer's handoff — diagonal blue gradient
/// (accentUpdate → accentUpdateDeep, stop 0.82), 1px white-22% inner stroke, a
/// #3E90FF glow + a black contact shadow, a refresh glyph. On HOVER it unrolls
/// rightward into variant B — the 87×38 "vX.Y.Z" capsule: the width springs
/// 38→87 (`Theme.Anim.updateChip`), and the version label fades in with a small
/// leftward-entry shift once the width is ~60% there (0.10s delay on a 0.34s
/// spring). Collapse waits 0.25s after the cursor leaves, so grazing past the
/// chip doesn't make it flap.
///
/// WHERE THE 49pt OF EXPANSION COMES FROM (round 7 correction, stand-verified):
/// the bar's flexible spacer donates its ~29pt first, and only the ~20pt
/// remainder grows the panel (611→631) with the same spring —
/// `MorphGeometry.updateChipHoverExtra`, wired through `barRowWidth` in
/// CommandBarView. The "keep the panel constant and compress into the spacer"
/// alternative was rejected: the row's other children are fixed-size, so the
/// missing 20pt could only come out of the inter-button gaps — every control
/// left of the chip would slide, exactly what the spec forbids. With panel
/// growth the only control that moves is the close cross (rightward, on the
/// same spring); everything under and left of the cursor is pixel-still.
///
/// Idle life (the designer's motion spec): every 2.5s a ~34pt diagonal white
/// streak sweeps across in 0.9s (easeInOut; the capsule clip ramps it 0→22%→0)
/// while the glow shadow breathes 0→8% on the same cycle. Hover: glow 16%
/// steady, the streak cycles every 1.2s, and — per the correction — NO scale:
/// a 1.02 zoom would fight the width unroll. Click: a white ring-wave expands
/// to ~120% of the chip's width over 0.28s (stroke, 45%→0) while the chip dips
/// to 0.94 for 0.08s, then the existing `installPendingUpdate()` runs. The
/// click works from BOTH states — expansion is never a precondition.
///
/// Reduce Motion: expansion is instant, no appearance spring, no streak, no
/// breathing, no ripple — a static 8% glow stands in for the pulse.
struct UpdateChipView: View {
    /// Appcast version ("4.3.0"; display normalizes a stray "v").
    let version: String
    /// Owned by CommandBarView: the row widens by `updateChipHoverExtra`
    /// while expanded, and the manager grows the panel to match.
    @Binding var isExpanded: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isHovering = false
    @State private var collapseTask: Task<Void, Never>?

    // Shimmer / glow / click state
    @State private var shimmerX: CGFloat = UpdateChipView.shimmerStart
    @State private var glowBreath: Double = 0
    @State private var pressed = false
    @State private var rippleID = 0
    @State private var rippleVisible = false

    // Handoff metrics
    static let compactWidth: CGFloat = 38
    static let expandedWidth: CGFloat = 87
    static let chipHeight: CGFloat = 38
    private static let shimmerStart: CGFloat = -85
    private static let shimmerEnd: CGFloat = 110

    private var displayVersion: String { UpdateChipState.displayVersion(version) }
    private var width: CGFloat { isExpanded ? Self.expandedWidth : Self.compactWidth }

    var body: some View {
        Button(action: fire) {
            chipBody
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.94 : 1)
        // The ripple is an overlay OUTSIDE the capsule clip — the wave washes
        // past the chip's edge, as drawn in the handoff.
        .overlay {
            if rippleVisible {
                ChipRippleRing(diameter: width)
                    .id(rippleID)
            }
        }
        .onHover(perform: hoverChanged)
        .help("Relaunch to update \(displayVersion)")
        .pointerOnHover()
        .task(id: shimmerLoopID) { await shimmerLoop() }
        .onDisappear { collapseTask?.cancel() }
        #if DEBUG
        // Stand door: pins the expanded/hover state for headless screenshots.
        .onAppear {
            if ProcessInfo.processInfo.environment["TRACER_PREVIEW_UPDATE_CHIP_EXPANDED"] != nil {
                isExpanded = true
                isHovering = true
            }
        }
        #endif
    }

    // MARK: Chip body (capsule = circle at 38, capsule at 87 — one shape)

    private var chipBody: some View {
        // Constant leading padding keeps the glyph pixel-still through the
        // unroll: 11pt ≈ centered in the compact 38 and exactly the handoff's
        // expanded inset — the capsule grows around a stationary icon.
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
            Text(displayVersion)
                .font(Theme.Typography.timer(11.5))
                .foregroundStyle(.white)
                .lineLimit(1)
                .fixedSize()
                .opacity(isExpanded ? 1 : 0)
                .offset(x: isExpanded ? 0 : -6)
                .animation(labelAnimation, value: isExpanded)
        }
        .padding(.leading, 11)
        .frame(width: width, height: Self.chipHeight, alignment: .leading)
        .background(
            LinearGradient(
                stops: [
                    .init(color: Theme.Colors.accentUpdate, location: 0.0),
                    .init(color: Theme.Colors.accentUpdateDeep, location: 0.82)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(shimmerBand)
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .contentShape(Capsule(style: .continuous))
        // Handoff shadows: the #3E90FF glow + a black contact shadow…
        .shadow(color: Theme.Colors.accentUpdate.opacity(0.38), radius: 12, x: 0, y: 3)
        .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 2)
        // …plus the LIVE glow layer: breathing 0→8% at rest, 16% steady on
        // hover, static 8% under Reduce Motion.
        .shadow(color: Theme.Colors.accentUpdate.opacity(liveGlow), radius: 12, x: 0, y: 3)
        .animation(reduceMotion ? nil : Theme.Anim.updateChip, value: isExpanded)
    }

    /// The label rides the unroll: in on a short delay (the width is ~60% of
    /// the way through the 0.34s spring at 0.10s), out immediately and faster.
    private var labelAnimation: Animation? {
        guard !reduceMotion else { return nil }
        return isExpanded
            ? .easeOut(duration: 0.16).delay(0.10)
            : .easeOut(duration: 0.10)
    }

    private var liveGlow: Double {
        if reduceMotion { return 0.08 }
        return isHovering ? 0.16 : glowBreath
    }

    // MARK: Shimmer (the diagonal streak)

    /// A clear→white→clear band ~34pt wide, rotated 45°, driven across the chip
    /// by `shimmerX`; the capsule clip ramps its visibility 0→22%→0 at the rims.
    private var shimmerBand: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, .white, .clear],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: 34, height: Self.chipHeight * 2.6)
            .rotationEffect(.degrees(45))
            .offset(x: shimmerX)
            .opacity(0.22)
            .allowsHitTesting(false)
    }

    /// Restarting id: the loop begins anew (with an immediate pass) when hover
    /// flips — which is how hover gets its faster 1.2s cycle without waiting
    /// out an idle 2.5s sleep.
    private var shimmerLoopID: String { "\(isHovering)-\(reduceMotion)" }

    private func shimmerLoop() async {
        guard !reduceMotion else { return }
        while !Task.isCancelled {
            // Reset the band off-left with no animation, then sweep.
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { shimmerX = Self.shimmerStart }
            withAnimation(.easeInOut(duration: 0.9)) { shimmerX = Self.shimmerEnd }
            // The glow breathes with the pass (idle only — hover holds 16%).
            if !isHovering {
                withAnimation(.easeInOut(duration: 0.45)) { glowBreath = 0.08 }
            }
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            if !isHovering {
                withAnimation(.easeInOut(duration: 0.45)) { glowBreath = 0 }
            }
            // Sleep out the rest of the cycle: 2.5s idle, 1.2s on hover.
            let cycleNs: UInt64 = isHovering ? 1_200_000_000 : 2_500_000_000
            try? await Task.sleep(nanoseconds: cycleNs - 450_000_000)
        }
    }

    // MARK: Hover (expand on enter, collapse 0.25s after leave)

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        collapseTask?.cancel()
        if hovering {
            isExpanded = true
            return
        }
        collapseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            isExpanded = false
        }
    }

    // MARK: Click (ripple + dip, then the coordinator's existing door)

    private func fire() {
        // Through the coordinator (round 8): a real pending update installs;
        // a preview chip lets the wave finish, then switches the preview off.
        guard !reduceMotion else {
            UpdateCoordinator.shared?.handleBarChipClick()
            return
        }
        rippleID += 1
        rippleVisible = true
        withAnimation(.easeOut(duration: 0.08)) { pressed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeOut(duration: 0.12)) { pressed = false }
            UpdateCoordinator.shared?.handleBarChipClick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            rippleVisible = false
        }
    }
}

/// The click's ring-wave: a stroked circle expanding from the chip's center to
/// ~120% of its width over 0.28s while its 45% white fades out. One-shot — the
/// parent re-`id`s it per click and removes it right after the pass.
private struct ChipRippleRing: View {
    let diameter: CGFloat

    @State private var expanded = false

    var body: some View {
        Circle()
            .strokeBorder(.white.opacity(expanded ? 0 : 0.45), lineWidth: 1.5)
            .frame(width: diameter, height: diameter)
            .scaleEffect(expanded ? 1.2 : 0.35)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 0.28)) { expanded = true }
            }
    }
}
