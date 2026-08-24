import SwiftUI
import AppKit

// MARK: - Panel

/// Same recipe as CommandBarPanel / ToastPanel: clicks land without activating the app.
private final class BackgroundPillsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Manager

/// The small floating stack of background-activity pills (Figma 63:123): "Uploading… N%"
/// and "Transcribing K video(s)", top-right of the active screen. A panel of its own,
/// separate from the command bar, because the pills outlive every bar surface — they
/// hang around during a fresh recording and never block one.
///
/// Show/hide follows `BackgroundActivity.uploads/transcriptions` becoming nil/non-nil,
/// driven by a `withObservationTracking` loop over the same AppState fields the SwiftUI
/// content reads (the content itself re-renders via Observation once the panel is up;
/// the loop exists for the panel-level concerns SwiftUI can't do from inside an
/// ordered-out window: ordering in/out and re-fitting the frame).
@Observable @MainActor
final class BackgroundPillsWindowManager {

    /// Transparent margin inside the panel reserved for the SwiftUI pill shadows
    /// (macro: drop-shadow 0 14 18 → 32pt of reach; 40 gives it air).
    static let shadowInset: CGFloat = 40
    /// Distance from the visible pills to the screen's top/right edges (macro 13:528).
    static let screenInset: CGFloat = 24

    private var panel: BackgroundPillsPanel?
    private weak var appState: AppState?
    private var openGallery: (() -> Void)?
    private var isObserving = false

    /// Wires the manager to AppState (call once at bootstrap, safe to repeat).
    /// `openGallery` is the click-through: any pill opens the bar's Gallery drawer.
    func attach(appState: AppState, openGallery: @escaping () -> Void) {
        self.appState = appState
        self.openGallery = openGallery
        refresh()
        if !isObserving {
            isObserving = true
            observeActivity()
        }
    }

    // MARK: Observation loop

    private func observeActivity() {
        guard let appState else { isObserving = false; return }
        withObservationTracking {
            _ = BackgroundActivity.uploads(progress: appState.uploadProgress,
                                           recordings: appState.recordings)
            _ = BackgroundActivity.transcriptions(recordings: appState.recordings,
                                                  activity: appState.transcriptionActivity)
            _ = appState.appTheme
        } onChange: { [weak self] in
            // onChange fires on willSet — hop to the next main-actor turn so refresh()
            // reads the post-change values, then re-arm (tracking is one-shot).
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observeActivity()
            }
        }
    }

    // MARK: Show / hide / fit

    private func refresh() {
        guard let appState else { return }
        let uploads = BackgroundActivity.uploads(progress: appState.uploadProgress,
                                                 recordings: appState.recordings)
        let transcriptions = BackgroundActivity.transcriptions(recordings: appState.recordings,
                                                               activity: appState.transcriptionActivity)
        guard uploads != nil || transcriptions != nil else {
            panel?.orderOut(nil)
            return
        }

        let panel = ensurePanel(appState: appState)
        panel.appearance = NSAppearance.from(appState.appTheme)

        // Re-fit on every change: a second pill appearing, or "1 video" → "2 videos",
        // changes the stack's natural size. Anchor the TOP-RIGHT visible corner so the
        // stack grows leftward/downward from the screen corner.
        if let host = panel.contentViewController {
            host.view.layoutSubtreeIfNeeded()
            let fitting = host.view.fittingSize
            panel.setContentSize(fitting)
            if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                let origin = NSPoint(
                    x: visible.maxX - fitting.width - Self.screenInset + Self.shadowInset,
                    y: visible.maxY - fitting.height - Self.screenInset + Self.shadowInset
                )
                panel.setFrameOrigin(origin)
            }
        }

        panel.orderFrontRegardless()
    }

    private func ensurePanel(appState: AppState) -> BackgroundPillsPanel {
        if let panel { return panel }

        let host = NSHostingController(
            rootView: BackgroundPillsView(appState: appState) { [weak self] in
                self?.openGallery?()
            }
        )
        // The manager sizes the panel from fittingSize; don't let SwiftUI fight it.
        host.sizingOptions = []

        let newPanel = BackgroundPillsPanel(
            contentRect: .zero,
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = host
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = false          // SwiftUI draws the pill shadows
        newPanel.sharingType = .none        // never joins captures, our own included
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.becomesKeyOnlyIfNeeded = true
        panel = newPanel
        return newPanel
    }
}

// MARK: - Pills view

/// The vertical stack (gap 8, macro 63:123) of whatever is currently in flight.
/// Reads AppState directly so Observation re-renders counts and percentages live.
private struct BackgroundPillsView: View {
    @Bindable var appState: AppState
    let openGallery: () -> Void

    private var uploads: UploadPillState? {
        BackgroundActivity.uploads(progress: appState.uploadProgress,
                                   recordings: appState.recordings)
    }

    private var transcriptions: TranscribePillState? {
        BackgroundActivity.transcriptions(recordings: appState.recordings,
                                          activity: appState.transcriptionActivity)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let uploads {
                uploadingPill(uploads)
            }
            if let transcriptions {
                transcribePill(transcriptions)
            }
        }
        .padding(BackgroundPillsWindowManager.shadowInset)
        .fixedSize()
    }

    // MARK: Uploading (macro 77:1324: 262×46, r23, pl13, gap 8, icon 13, text 12/0.85)

    private func uploadingPill(_ state: UploadPillState) -> some View {
        let percent = Int((state.fraction * 100).rounded())
        let label = state.count > 1
            ? "Uploading \(state.count) clips · \(percent)%"
            : "Uploading… \(percent)%"
        return pillButton {
            HStack(spacing: 8) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary.opacity(0.85))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 13)
            .padding(.trailing, 14)
        }
    }

    // MARK: Transcribing (macro 77:1333: 262×46, r23, px14, green mono % at right)

    private func transcribePill(_ state: TranscribePillState) -> some View {
        pillButton {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary.opacity(0.85))
                Text("Transcribing \(state.count) video\(state.count == 1 ? "" : "s")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 8)
                // nil fraction = indeterminate (queued / an engine that can't measure
                // itself): no number beats a bar frozen at zero.
                if let fraction = state.fraction {
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Theme.Typography.timer(12.5))
                        .foregroundStyle(Theme.Colors.statusGreen)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    // MARK: Shared chrome

    /// 262×46 glass capsule; the whole pill is one click target → Gallery drawer.
    private func pillButton(@ViewBuilder content: () -> some View) -> some View {
        Button(action: openGallery) {
            content()
                .frame(width: 262, height: 46)
                .glassSurface(cornerRadius: 23)
                .contentShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Show recordings")
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        // Macro pill shadow: drop-shadow(0 14px 18px rgba(0,0,0,0.5)).
        .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 14)
    }
}
