import SwiftUI

// MARK: - Record mark (native, verdict 24.08; shared home since round 3)

/// The record mark drawn natively: a round dashed blue ring around a blue-gradient
/// play triangle over a faint disc — the sec1-bar.png reference at 52pt. Replaces
/// the commandbar_mark* PNGs (which stay in Resources untouched); native drawing is
/// what makes the hover spin/scale and any future morphs animatable.
///
/// Lives in its own file (round 3) because the mark is no longer the bar's private
/// asset: the Gallery empty state renders it at 44pt and the thumbnail play badge
/// at 18pt (`ThumbnailPlayBadge` below).
///
/// Every metric scales with `diameter`, and the dash period divides the ring's
/// circumference exactly (10 periods at any size), so the dashes always meet
/// cleanly instead of leaving a seam.
struct RecordRingMark: View {
    var diameter: CGFloat = 52
    /// Marching-ants spin of the dashed ring. TASTE DECISION: the spin is
    /// hover-only, NOT always-on — the bar floats over the user's work all day,
    /// and a perpetually crawling selection frame in peripheral vision is
    /// distraction (plus a permanent animation in a floating panel costs battery
    /// on a machine that is busy recording). The ring wakes up when aimed at.
    var isSpinning: Bool = false

    /// The ring's accumulated angle. ROUND 9 (boss's verdict on 4.4.1: the spin
    /// «дуже дивна»): the offending part was the RETURN — the old code animated
    /// the angle back to 0 on hover-out, so the ring visibly unwound. Now the
    /// angle is never reset: hover-out freezes it exactly where it is, and the
    /// next hover picks up from that same angle. Nothing in the mark's geometry
    /// depends on the absolute angle (the dash period divides the circumference
    /// exactly), so an arbitrary resting angle is indistinguishable from zero.
    @State private var spinAngle: Double = 0

    /// One full turn, halved in round 9 (8s → 16s): the marching ants now
    /// crawl at half speed, which reads as "alive", not "busy".
    private static let spinPeriod: Double = 16

    static let ringBlue = Color(hex: 0x3E90FF)

    /// Triangle gradient, scheme-split since round 3 («на темній темі кнопка плей
    /// дивнувата»): the old #0B5BE0→#0846B5 is a deep navy that read as a dark
    /// smudge on the dark glass. The dark values are PIPETTED from sec1-bar.png
    /// (#3D8FFE at the triangle's top, #2575E9 near its base — the reference
    /// triangle is a vivid blue, close kin of the #3E90FF ring). Light keeps the
    /// deep navy pair, which reads correctly on the airy light glass.
    private static let triangleGradient = LinearGradient(
        colors: [
            Color.adaptive(light: Color(hex: 0x0B5BE0), dark: Color(hex: 0x3E90FF)),
            Color.adaptive(light: Color(hex: 0x0846B5), dark: Color(hex: 0x2575E9))
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The disc behind the triangle — the «припіднятий камінець» (raised stone),
    /// made RELATIVE in round 8. RULE: the well is a RELATIVE lift over the
    /// glass — absolute colors are FORBIDDEN here, because the glass itself is
    /// adaptive: Liquid Glass lets the desktop through, so over a bright
    /// backdrop the bar lightens while an absolute dark well stays dark and
    /// punches a «чорна діра» through it (the boss's 4.4.0 verdict — exactly
    /// the round-6/7 absolutes failing outside the mock's dark canvas).
    ///
    /// Dark: a translucent WHITE lift, same family as the neighbouring
    /// buttons' `glassControlFill` (white 10%) — diagonal 10% → 6% (top-left
    /// lit, avg ~8%) so the stone still catches light, riding WHATEVER the
    /// glass currently shows instead of fighting it. Light: the macro's ink
    /// wash (#0B1220 5%) — already relative, unchanged. A `glassStrokeSubtle`
    /// hairline keeps the rim readable in the dash gaps of the ring.
    ///
    /// Inherited at every diameter on purpose — the bar's 52pt, the gallery
    /// empty state's 44pt and the 18pt ThumbnailPlayBadge (which pins the dark
    /// scheme) all wear the same stone, one brand mark everywhere. The badge's
    /// separate BLACK backing disc is deliberately untouched: that disc is
    /// contrast armor against light thumbnail frames — a different context
    /// than glass — and is not the well.
    private static let wellGradient = LinearGradient(
        colors: [
            Color.adaptive(light: Color(hex: 0x0B1220, opacity: 0.05),
                           dark: Color(hex: 0xFFFFFF, opacity: 0.10)),
            Color.adaptive(light: Color(hex: 0x0B1220, opacity: 0.05),
                           dark: Color(hex: 0xFFFFFF, opacity: 0.06))
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private var scale: CGFloat { diameter / 52 }
    private var lineWidth: CGFloat { 2.5 * scale }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth)
                .fill(Self.wellGradient)
            // The relative well's rim (round 8): without it the stone's edge
            // dissolves into the glass in the ring's dash gaps.
            Circle()
                .inset(by: lineWidth)
                .strokeBorder(Theme.Colors.glassStrokeSubtle, lineWidth: 1)
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Self.ringBlue, style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    // 10 exact periods around the centerline circumference.
                    dash: [9.7 * scale, 5.85 * scale]
                ))
                .rotationEffect(.degrees(spinAngle))
            RoundedTrianglePlay(cornerRadius: 2.5 * scale)
                .fill(Self.triangleGradient)
                .frame(width: diameter * 0.34, height: diameter * 0.38)
                .offset(x: diameter * 0.035)  // optical centering of the triangle
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: isSpinning) { _, spinning in
            spinning ? startSpinning() : stopSpinning()
        }
        .onDisappear { spinTask?.cancel() }
    }

    // MARK: Spin (round 9: never rewinds)

    @State private var spinTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One animation chunk. The spin is driven in short LINEAR steps rather
    /// than one `repeatForever` because a repeating animation keeps its
    /// progress inside SwiftUI where the view cannot read it — the only way to
    /// stop such a spin was to write the angle back, i.e. to rewind. With
    /// chunks the @State angle IS the truth: stop scheduling and the ring
    /// stands exactly where the last chunk left it. Linear→linear chunks abut
    /// seamlessly, so the motion is indistinguishable from one long turn.
    private static let spinChunk: Double = 0.5
    private var degreesPerChunk: Double { 360 * Self.spinChunk / Self.spinPeriod }

    private func startSpinning() {
        guard !reduceMotion else { return }
        spinTask?.cancel()
        spinTask = Task { @MainActor in
            while !Task.isCancelled {
                // The chunk animation deliberately OUTLASTS the sleep (×1.2):
                // `Task.sleep` wakes no earlier than its deadline, so equal
                // durations let the ring finish its chunk and stand still for
                // the scheduling jitter — a micro-stall twice a second, the
                // very "дивно" this rewrite exists to remove. Overlapping
                // means the next chunk always retargets from a MOVING value,
                // and linear→linear retargeting keeps the speed constant.
                withAnimation(.linear(duration: Self.spinChunk * 1.2)) {
                    spinAngle += degreesPerChunk
                }
                try? await Task.sleep(nanoseconds: UInt64(Self.spinChunk * 1_000_000_000))
            }
        }
    }

    /// Hover-out: a short glide to a halt from WHEREVER the ring currently is
    /// (SwiftUI retargets from the live presentation value), and the angle
    /// keeps its accumulated value forever after — the next hover continues
    /// from there. No rewind, ever.
    private func stopSpinning() {
        spinTask?.cancel()
        spinTask = nil
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            spinAngle += degreesPerChunk / 2
        }
    }
}

/// A right-pointing play triangle with softly rounded corners (the reference's
/// triangle is not razor-sharp).
struct RoundedTrianglePlay: Shape {
    var cornerRadius: CGFloat = 2.5

    func path(in rect: CGRect) -> Path {
        let top = CGPoint(x: rect.minX, y: rect.minY)
        let tip = CGPoint(x: rect.maxX, y: rect.midY)
        let bottom = CGPoint(x: rect.minX, y: rect.maxY)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addArc(tangent1End: top, tangent2End: tip, radius: cornerRadius)
        path.addArc(tangent1End: tip, tangent2End: bottom, radius: cornerRadius)
        path.addArc(tangent1End: bottom, tangent2End: top, radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}

// MARK: - Thumbnail play badge (round 3, package 5)

/// The brand play mark for gallery thumbnails: a small RecordRingMark on a dark
/// translucent backing disc, so the badge survives light video frames. Fixed
/// colors, not adaptive — it always sits ON a thumbnail image, never on glass.
struct ThumbnailPlayBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.48))
            RecordRingMark(diameter: 18)
        }
        .frame(width: 22, height: 22)
        // The backing disc is always dark, so the mark must always resolve its
        // adaptive colors dark-side (the light-scheme navy triangle would sink
        // into the disc). Pinning the scheme here does exactly that.
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)   // the ROW is the click target, not the badge
    }
}
