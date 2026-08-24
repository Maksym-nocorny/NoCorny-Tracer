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
            HStack(spacing: 6) {
                icon("sparkles", tint: Theme.Colors.statusGreen)
                transcribingLabel(percent: percent)
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
