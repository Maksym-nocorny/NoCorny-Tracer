import SwiftUI

/// The transcription status axis of a recording row (Figma 533:1606). Extracted as a
/// shared cluster when the Gallery drawer and the old Recordings list coexisted;
/// phase 6b deleted that list, and the Gallery drawer row is now the sole client.
///
/// The glyph of the axis is a spark: dim while the run waits, statusGreen while it
/// works, a green tick once cues exist — the tick stays, because this is the second
/// axis and a row with no transcription mark reads as "never transcribed". The axis
/// is independent of the upload axis and always stands to its LEFT: a recording can
/// be transcribing while its upload is still moving, or hold a failed transcript
/// over a green cloud tick — and during the AI's minutes-long first run, a green
/// upload tick alone would read as "done and broken".
struct TranscriptionStatusCluster: View {
    @Bindable var appState: AppState
    let recording: Recording

    // MARK: State → glyph (pure, covered by TranscriptionGlyphMappingTests)

    /// What the cluster draws, derived from the status and the reported fraction and
    /// nothing else — pure so the mapping is testable without building a view.
    enum Glyph: Equatable {
        case none
        case queued
        /// `percent` is nil until the engine reports a measurable fraction; the label
        /// then stays a bare "Transcribing…" (engines that cannot measure themselves
        /// never report one, and that still says "working").
        case transcribing(percent: Int?)
        case done
        case failed
    }

    static func glyph(for status: TranscriptionStatus, fraction: Double?) -> Glyph {
        switch status {
        case .idle:
            return .none
        case .queued:
            return .queued
        case .transcribing:
            guard let fraction, fraction > 0 else { return .transcribing(percent: nil) }
            return .transcribing(percent: Int(min(1.0, fraction) * 100))
        case .done:
            return .done
        case .failed:
            return .failed
        }
    }

    /// Failed-axis alert. Dark is the macro's #FF6B63; on light glass that value sits
    /// at 2.5:1, so the light scheme darkens it to #CC2921 (from the handoff).
    static let failedAlert = Color.adaptive(
        light: Color(hex: 0xCC2921),
        dark: Color(hex: 0xFF6B63)
    )

    // MARK: Rendering (cluster: gap 6, icon 12, text medium 11.5)

    var body: some View {
        switch Self.glyph(
            for: recording.effectiveTranscriptionStatus,
            fraction: appState.transcriptionActivity[recording.id]?.fraction
        ) {
        case .none:
            EmptyView()

        case .queued:
            HStack(spacing: 6) {
                icon("sparkles", tint: DrawerStyle.ink(0.45))
                Text("Queued")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.45))
            }
            .help("Waiting for transcription to start")

        case .transcribing(let percent):
            // Label + mini progress bar (round 7). The bar slot exists for the
            // WHOLE transcribing state — indeterminate included — so the label
            // does not shift down when the engine's first measured fraction
            // lands. The cluster still fits well under the row's 42pt thumbnail,
            // so the row height never changes either.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    icon("sparkles", tint: Theme.Colors.statusGreen)
                    transcribingLabel(percent: percent)
                }
                progressBar(fraction: appState.transcriptionActivity[recording.id]?.fraction)
                    .padding(.leading, 18) // align with the label (icon 12 + gap 6)
            }
            .help("Transcribing…")

        case .done:
            icon("checkmark.circle.fill", tint: Theme.Colors.statusGreen)
                .help("Transcribed")

        case .failed:
            HStack(spacing: 6) {
                icon("exclamationmark.triangle.fill", tint: Self.failedAlert)
                // A claimed retry hasn't landed its `.queued` write yet (async hop), so
                // the row still reads `.failed` for a beat — show the work instead of a
                // button whose second click would be a no-op anyway.
                if appState.retryingTranscriptions.contains(recording.id) {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 24, height: 24)
                        .help("Retrying transcription…")
                } else {
                    retryButton
                }
            }
            .help(recording.transcriptionError ?? "Transcription failed — click to retry")
        }
    }

    private func icon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 12))
            .foregroundStyle(tint)
            .frame(width: 12, height: 12)
    }

    // MARK: Mini progress bar (round 7 — the library's percent, visible at a glance)

    static let miniBarWidth: CGFloat = 64

    /// Fill width for a reported fraction, clamped — engines can overshoot 1.0
    /// on the last chunk (same clamp the percent label applies). nil for an
    /// unmeasurable fraction: the bar goes indeterminate instead of lying at 0.
    static func barFillWidth(fraction: Double?, barWidth: CGFloat = miniBarWidth) -> CGFloat? {
        guard let fraction, fraction > 0 else { return nil }
        return barWidth * CGFloat(min(1.0, fraction))
    }

    @State private var indeterminatePulse = false

    /// 64×3, r1.5 — track ink 10%, fill statusGreen. A measured fraction fills it
    /// with a 0.3s linear glide, so chunked engines flow instead of stepping.
    /// Indeterminate (the local engine before its first segment) was a choice
    /// between "no bar" and "pulsing track" — pulsing track won: the slot is
    /// reserved anyway (no label jump), and an empty static track would read as
    /// "stuck at 0%" where the pulse honestly says "working, not measured yet".
    private func progressBar(fraction: Double?) -> some View {
        let fillWidth = Self.barFillWidth(fraction: fraction)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(DrawerStyle.ink(0.10))
                .opacity(fillWidth == nil ? (indeterminatePulse ? 1.0 : 0.35) : 1.0)
            if let fillWidth {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Theme.Colors.statusGreen)
                    .frame(width: fillWidth)
            }
        }
        .frame(width: Self.miniBarWidth, height: 3)
        .animation(.linear(duration: 0.3), value: fraction)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                indeterminatePulse = true
            }
        }
    }

    /// The percentage is the live part, so it alone carries statusGreen.
    private func transcribingLabel(percent: Int?) -> some View {
        Group {
            if let percent {
                Text("Transcribing… ").foregroundStyle(DrawerStyle.ink(0.45))
                    + Text("\(percent)%").foregroundStyle(Theme.Colors.statusGreen)
            } else {
                Text("Transcribing…").foregroundStyle(DrawerStyle.ink(0.45))
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .monospacedDigit()
    }

    /// Round 24pt retry (macro: r12, fill 8%, stroke 14%, arrow.clockwise 11pt).
    private var retryButton: some View {
        Button {
            appState.retryTranscription(recording)
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.75))
                .frame(width: 24, height: 24)
                .background(Circle().fill(DrawerStyle.ink(0.08)))
                .overlay(Circle().strokeBorder(DrawerStyle.ink(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }
}
