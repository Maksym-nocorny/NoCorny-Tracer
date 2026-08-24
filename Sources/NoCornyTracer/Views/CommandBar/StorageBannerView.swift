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
        .background(
            ZStack {
                // The macro's backdrop-blur 8 over the wallpaper, then the amber wash.
                Theme.Glass.GlassBackground(material: .hudWindow)
                Theme.Colors.pausedAmber.opacity(isFull ? 0.16 : 0.10)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.Colors.pausedAmber.opacity(isFull ? 0.45 : 0.30), lineWidth: 1)
        )
    }
}
