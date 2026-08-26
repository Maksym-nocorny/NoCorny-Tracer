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

    @State private var spinAngle: Double = 0

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

    /// The disc behind the triangle. Light: the subtle ink wash from the macro
    /// (light glass is brighter than the disc). Dark: ROUND 6 (verdict from the
    /// 4.2.1 build: «надто блякла, зроби більш чорно насиченою, щоб виділялась»
    /// — overrides the round-3 white-7% lift, which read as washed-out): a deep
    /// saturated black-navy well, so the button reads as a distinct dark pill on
    /// the glass while the #3E90FF-family ring and triangle fire against it.
    /// Inherited at every diameter on purpose — the bar's 52pt, the gallery
    /// empty state's 44pt and the 18pt ThumbnailPlayBadge (which pins the dark
    /// scheme) all wear the same well, one brand mark everywhere.
    private static let wellFill = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.05),
        dark: Color(hex: 0x05080F, opacity: 0.62)
    )

    private var scale: CGFloat { diameter / 52 }
    private var lineWidth: CGFloat { 2.5 * scale }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth)
                .fill(Self.wellFill)
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
            if spinning {
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                    spinAngle += 360
                }
            } else {
                // The ants settle back to rest rather than freezing mid-crawl.
                withAnimation(.easeOut(duration: 0.35)) {
                    spinAngle = 0
                }
            }
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
