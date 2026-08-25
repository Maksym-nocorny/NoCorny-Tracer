import SwiftUI
import AppKit

// MARK: - Recording pill

/// The pill the command bar collapses into while recording (Figma 77:1305, paused
/// variant 88:744; the round-3 v2 mockup is the metric canon): base 341×54 r34 —
/// stop 38 · timer 57 · pause 28 · discard 28 · divider · mic 30 · cam 30 ·
/// divider · hide 28, gaps of 10, paddings 10. The mic/cam toggles are the bar's
/// actions at pill scale; the hide chevron sends the panel away while the take
/// keeps recording.
///
/// Transient states the mockup doesn't draw — the armed "Discard?" capsule, a
/// timer wider than its 57-pt slot on 100+ minute takes — are NOT baked into the
/// base: the content hugs, reports its laid-out width to the manager
/// (`setRecordingPillContentWidth`), and the PANEL grows dynamically to the right
/// of the held top-left anchor, toast-style.
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
        // No fixed width and no Spacer: the content HUGS (base sums to exactly the
        // 341-pt canon) and the panel follows its real width — see the type comment.
        HStack(spacing: 10) {
            stopButton
            timerText
            pauseButton
            discardControl
            pillDivider
            micToggle
            camToggle
            pillDivider
            hideButton
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Metrics.recordingPillSize.height)
        .glassSurface(cornerRadius: 34)   // r34 per the v2 mockup — same as the bar
        // The dynamic-width channel: whatever the content lays out to, the panel
        // resizes to (growing right of the held anchor). Idempotent in the manager,
        // so the resize→relayout→report cycle settles immediately.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            manager.setRecordingPillContentWidth(width)
        }
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
        .pointerOnHover()
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
            // The mockup's 57-pt timer slot: a floor, not a cap — "mm:ss" sits in
            // it exactly, and a 100+ minute "mmm:ss" overflows into the dynamic
            // panel width instead of squeezing the neighbours.
            .frame(minWidth: 57, alignment: .leading)
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
        .pointerOnHover()
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
            .pointerOnHover()
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
            .pointerOnHover()
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

    // MARK: Divider (round 3)

    /// Thin divider between the take controls and the capture toggles — the bar's
    /// divider recipe scaled to the pill's height.
    private var pillDivider: some View {
        Rectangle()
            .fill(Theme.Colors.glassDivider)
            .frame(width: 1, height: 24)
    }

    // MARK: Mic / cam toggles (round 3 — shrunken bar buttons, same actions)

    /// Same rule as the bar's mic toggle: the capture device is fixed once the
    /// recording starts, so mid-take the toggle is visible but disabled with the
    /// explanatory tooltip. (The DEBUG preview pill has no live take, so there the
    /// toggle stays interactive — same as the bar behaves outside a recording.)
    private var micToggle: some View {
        PillToggleButton(
            systemName: "mic.fill",
            isOn: appState.isMicrophoneEnabled,
            isPausedDimmed: isPaused,
            help: isRecordingForReal
                ? "The microphone can only be changed before a recording starts"
                : "Record the microphone"
        ) {
            appState.requestMicrophoneEnabled(!appState.isMicrophoneEnabled)
        }
        .disabled(isRecordingForReal)
    }

    /// The camera CAN flip mid-take — the toggle shows/hides the camera bubble,
    /// through the same permission gate as the bar's button.
    private var camToggle: some View {
        PillToggleButton(
            systemName: "video.fill",
            isOn: appState.isCameraEnabled,
            isPausedDimmed: isPaused,
            help: "Show the camera bubble"
        ) {
            appState.requestCameraEnabled(!appState.isCameraEnabled)
        }
    }

    private var isRecordingForReal: Bool { recordingManager.isRecording }

    // MARK: Hide (round 3)

    /// Sends the pill away while the take keeps recording — the timer stays in the
    /// tray. Getting it back: a left click on the tray icon shows the pill again
    /// (only the SECOND click stops — the honest two-click compromise, see
    /// StatusItemController.leftClickAction), or the tray menu's "Show recording
    /// pill" item.
    /// 28×28 r14 per the v2 mockup, fills a notch softer than the toggles (7%/13%
    /// on the ink/white base — the designer's own values, between the primary and
    /// subtle glass tokens). Tooltip deliberately differs from the bar's xmark:
    /// the glyphs differ on purpose, and so must the promise.
    private var hideButton: some View {
        Button {
            #if DEBUG
            // A preview pill has no real take to keep running — hiding it just
            // ends the preview, mirroring what its stop button does.
            if let preview { preview.endPill(); return }
            #endif
            manager.hideRecordingPill()
        } label: {
            ZStack {
                Circle().fill(Self.hideFill)
                Circle().strokeBorder(Self.hideStroke, lineWidth: 1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help("Hide pill (recording continues)")
        .pointerOnHover()
    }

    /// v2 mockup values (dark: white 7%/13%); light derives from the ink base the
    /// same way the phase-0 glass tokens do.
    private static let hideFill = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.07),
        dark: Color(hex: 0xFFFFFF, opacity: 0.07)
    )
    private static let hideStroke = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.13),
        dark: Color(hex: 0xFFFFFF, opacity: 0.13)
    )
}

// MARK: - Pill toggle button (round 3, metrics per the v2 mockup)

/// The bar's CommandToggleButton at pill scale: 30×30 r15, 14pt icon, 6pt status
/// dot at ~(23,1) — the dot is the macro's own `statusGreen` (#32D74B), NOT the
/// bar's deepened `statusGreenDot`: the designer sampled the pill mockup, and the
/// pill lives on its own glass. While the take is PAUSED the icons dim to 0.55
/// and the dots to 0.35 — capture is standing still, and the toggles say so.
private struct PillToggleButton: View {
    let systemName: String
    let isOn: Bool
    var isPausedDimmed: Bool = false
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isHovering ? Theme.Colors.glassControlFillHover : Theme.Colors.glassControlFill)
                Circle().strokeBorder(Theme.Colors.glassStroke, lineWidth: 1)
                Image(systemName: systemName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOn ? Theme.Colors.textPrimary : Theme.Colors.timerDimmed)
                    .opacity(isPausedDimmed ? 0.55 : 1)
            }
            .frame(width: 30, height: 30)
            .overlay(alignment: .topTrailing) {
                if isOn {
                    // 6×6 at ~(23,1) of the 30-pt circle: topTrailing puts it at
                    // (24,0); the 1-pt nudge lands the mockup's position.
                    Circle()
                        .fill(Theme.Colors.statusGreen)
                        .frame(width: 6, height: 6)
                        .offset(x: -1, y: 1)
                        .opacity(isPausedDimmed ? 0.35 : 1)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.03 : 1)
        .animation(Theme.Anim.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
        .pointerOnHover()
    }
}
