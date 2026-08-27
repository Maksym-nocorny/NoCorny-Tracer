import SwiftUI

/// The amber quota warning under the command bar (Figma 87:1851 low / 87:1897 full):
/// 560×38, radius 14, amber wash over glass, "Manage ↗" jumping to Tracer settings.
///
/// Shown ONLY on the plain `.bar` surface (decision, phase 4): the recording pill
/// stays minimal mid-take, and the open drawer already carries the Dropbox quota row —
/// a second amber line under it would say the same thing twice.
struct StorageBannerView: View {
    @Bindable var appState: AppState
    let level: StorageAlertLevel

    /// The full state is drawn hotter than the low state (macro: fill 0.16 vs 0.10,
    /// border 0.45 vs 0.30) — the difference between "soon" and "already happening".
    private var isFull: Bool { level == .full }

    private var message: String {
        switch level {
        case .low(let minutesLeft):
            return "Dropbox almost full — ~\(minutesLeft) min left"
        case .full:
            return "Dropbox full — recording will be saved locally"
        case .ok:
            return ""  // never rendered; the root only mounts the banner when level != .ok
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Colors.pausedAmber)
                .frame(width: 14, height: 14)

            Text(message)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.Colors.pausedAmber)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button("Manage ↗") {
                appState.openTracerSettings()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.Colors.pausedAmber)
            .pointerOnHover()
            .help("Manage Dropbox storage")
        }
        .padding(.horizontal, 16)
        .frame(
            width: Theme.Metrics.commandBarSize.width,
            height: MorphGeometry.storageBannerHeight
        )
        .modifier(BannerGlass(isFull: isFull))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.Colors.pausedAmber.opacity(isFull ? 0.45 : 0.30), lineWidth: 1)
        )
    }
}

/// The banner's glass, same policy as `glassSurface`, but amber-washed. Since
/// round 5 BOTH schemes ride `.regular` (the luminance floor — dark `.clear`
/// washed out over white backdrops exactly like the bar did); dark layers the
/// amber wash over the deep navy tint, light tints the frost amber directly.
/// The fallback stacks blur + deep tint + wash as before. The amber stroke
/// stays on all paths (it is the banner's identity, not a glass border — and
/// it is also what keeps the banner's edge readable, so no extra ink hairline).
private struct BannerGlass: ViewModifier {
    let isFull: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var wash: Color {
        Theme.Colors.pausedAmber.opacity(isFull ? 0.16 : 0.10)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *) {
            if colorScheme == .dark {
                // ROUND 11 (варіант C): the bar above now carries a colour PLATE,
                // so the banner needs one too — otherwise the two surfaces that
                // touch each other read as different materials. The banner's
                // plate is AMBER-FAMILY on purpose (`glassPlateBannerDark`,
                // #17110A at the same 0.80 density as the bar's navy): a navy
                // plate here would out-vote the 10-16% amber wash and the
                // warning banner would come out blue with a yellow rim.
                content
                    .background(
                        ZStack {
                            shape.fill(Theme.Colors.glassPlateBannerDark)
                            shape.fill(wash)
                        }
                    )
                    .clipShape(shape)
                    .glassEffect(.regular.tint(Theme.Colors.liquidGlassTint), in: shape)
            } else {
                content
                    .clipShape(shape)
                    .glassEffect(.regular.tint(wash), in: shape)
            }
        } else {
            content
                .background(
                    ZStack {
                        // The macro's backdrop-blur over the wallpaper, then the amber wash.
                        // ROUND 11: the warm base (`glassBackdropTintBanner`), not the
                        // bar's navy — same reason as the 26+ plate above.
                        Theme.Glass.GlassBackground()
                        Theme.Colors.glassBackdropTintBanner
                        wash
                    }
                )
                .clipShape(shape)
        }
    }
}
