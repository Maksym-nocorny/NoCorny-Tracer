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
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
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

/// The banner's glass, same split (and the same 25.08 grey-frost fix) as
/// `glassSurface`, but amber-washed. macOS 26+ dark rides the `.clear` variant
/// with the deep navy tint — `.regular`'s frost turned the faint amber tint into
/// the same grey plate the bar had — with the amber wash layered over it; light
/// keeps the airy `.regular` frost tinted amber. The fallback stacks blur + deep
/// tint + wash as before. The amber stroke stays on all paths (it is the
/// banner's identity, not a glass border).
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
                content
                    .background(shape.fill(wash))
                    .clipShape(shape)
                    .glassEffect(.clear.tint(Theme.Colors.liquidGlassTint), in: shape)
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
                        Theme.Glass.GlassBackground()
                        Theme.Colors.glassBackdropTint
                        wash
                    }
                )
                .clipShape(shape)
        }
    }
}
