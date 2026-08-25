import SwiftUI
import AppKit

// MARK: - Recording pill

/// The 292×54 pill the command bar collapses into while recording (Figma 77:1305,
/// paused variant 88:744): stop mark in a dashed ring, the timer, then pause and
/// discard. Content is leading-aligned per the macro — the trailing air is where the
/// inline "Discard?" confirmation expands.
struct RecordingPillView: View {
    @Bindable var appState: AppState
    let manager: CommandBarWindowManager

    /// First trash click (or Esc) arms this; the trash button becomes a red
    /// "Discard?" capsule for 3 seconds, and only a second click actually aborts.
    /// An NSAlert can't sit on a borderless nonactivating panel without stealing
    /// the recording's focus, hence the inline treatment.
    @State private var confirmingDiscard = false
    @State private var confirmExpiry: Task<Void, Never>?

    private var recordingManager: RecordingManager { appState.recordingManager }

    #if DEBUG
    /// Non-nil while the tray's UI Preview drives this pill with fake data.
    /// A real recording always wins: with a live take the pill reads the real
    /// manager even if a preview was left switched on.
    private var preview: UIPreviewState? {
        let state = UIPreviewState.shared
        guard state.pill != nil, !recordingManager.isRecording else { return nil }
        return state
    }
    #endif

    private var isPaused: Bool {
        #if DEBUG
        if let preview { return preview.pill == .paused }
        #endif
        return recordingManager.isPaused
    }

    private var displayedDuration: String {
        #if DEBUG
        if let preview { return preview.formattedElapsed }
        #endif
        return recordingManager.formattedDuration
    }

    /// Ring + accents: recordRed while recording, pausedAmber while paused (macro 88:744).
    private var accent: Color {
        isPaused ? Theme.Colors.pausedAmber : Theme.Colors.recordRed
    }

    var body: some View {
        HStack(spacing: 10) {
            stopButton
            timerText
            pauseButton
            discardControl
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(
            width: Theme.Metrics.recordingPillSize.width,
            height: Theme.Metrics.recordingPillSize.height
        )
        .glassSurface(cornerRadius: Theme.Metrics.recordingPillSize.height / 2)
        .floatingPanelShadow()
        // Esc on the (key) panel routes here via the manager — same confirm as a click.
        .onChange(of: manager.pillEscSignal) {
            armDiscardConfirm()
        }
    }

    // MARK: Stop

    /// 38pt stop control: a 14pt rounded stop square inside a dashed ring (macro
    /// btn/stop). Always the recording accent — this IS the "recording" mark.
    /// Ring thickness and dash rhythm match the bar's round record button
    /// (RecordRingMark: 2.5pt, ~15.9pt period, round caps — 7 exact periods at
    /// this diameter), and the ring pulses while actually recording — the
    /// "time is running" cue; paused holds it steady.
    private var stopButton: some View {
        Button {
            #if DEBUG
            if let preview { preview.endPill(); return }
            #endif
            Task { await appState.stopRecording() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(accent, style: StrokeStyle(
                        lineWidth: 2.5,
                        lineCap: .round,
                        dash: [9.94, 5.99]
                    ))
                    .modifier(PulsingModifier(isActive: !isPaused))
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(Theme.Colors.recordRed)
                    .frame(width: 14, height: 14)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Stop recording")
        .pillPointingHandOnHover()
    }

    // MARK: Timer

    /// JetBrains Mono 19 (macro I77:1305;220:845). White 0.95 recording, 0.55 paused —
    /// the paused dimming is the "time is standing still" cue.
    private var timerText: some View {
        Text(displayedDuration)
            .font(Theme.Typography.timer(19))
            .foregroundStyle(
                isPaused
                    ? Theme.Colors.textPrimary.opacity(0.55)
                    : Theme.Colors.textPrimary.opacity(0.95)
            )
            .lineLimit(1)
            .fixedSize()
    }

    // MARK: Pause / resume

    private var pauseButton: some View {
        Button {
            #if DEBUG
            if let preview { preview.togglePaused(); return }
            #endif
            Task { await recordingManager.togglePause() }
        } label: {
            ZStack {
                Circle().fill(Theme.Colors.glassControlFill)
                Circle().strokeBorder(Theme.Colors.glassStroke, lineWidth: 1)
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isPaused ? Theme.Colors.pausedAmber : Theme.Colors.textPrimary)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(isPaused ? "Resume recording" : "Pause recording")
        .pillPointingHandOnHover()
    }

    // MARK: Discard (inline two-step confirm)

    @ViewBuilder
    private var discardControl: some View {
        if confirmingDiscard {
            Button {
                confirmExpiry?.cancel()
                #if DEBUG
                if let preview { preview.endPill(); return }
                #endif
                Task { await appState.abortRecording() }
                // No morph here: abort drops isRecording, and the root's onChange
                // brings the bar back through the one shared path.
            } label: {
                Text("Discard?")
                    .font(Theme.Typography.body(11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.Colors.recordRed))
            }
            .buttonStyle(.plain)
            .help("Click again to discard this recording")
            .pillPointingHandOnHover()
        } else {
            Button {
                armDiscardConfirm()
            } label: {
                ZStack {
                    Circle().fill(Theme.Colors.glassControlFillSubtle)
                    Circle().strokeBorder(Theme.Colors.glassStrokeSubtle, lineWidth: 1)
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("Discard recording")
            .pillPointingHandOnHover()
        }
    }

    private func armDiscardConfirm() {
        withAnimation(Theme.Anim.standard) { confirmingDiscard = true }
        confirmExpiry?.cancel()
        confirmExpiry = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Theme.Anim.standard) { confirmingDiscard = false }
        }
    }
}

// MARK: - Hover cursor

/// Same recipe as CommandBarView's private helper; duplicated because that one is
/// file-private and a shared home for a 3-line modifier is phase-7 cleanup.
private extension View {
    func pillPointingHandOnHover() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
