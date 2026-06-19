import SwiftUI
import AppKit

/// A floating panel that can host clickable controls (buttons) without activating the whole app.
/// `.nonactivatingPanel` keeps focus where it is (the recording flow isn't disrupted), while
/// `canBecomeKey` lets the buttons receive clicks.
private final class NoiseToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Manages the floating "noisy environment" suggestion toast shown during recording.
///
/// The main app window is hidden while recording, so an in-window banner would never be seen —
/// this mirrors `CameraWindowManager`'s floating-NSPanel approach instead. The toast appears near
/// the top-center of the active screen, auto-dismisses after a few seconds, and offers to enable
/// noise reduction (which applies to the next recording).
@Observable
final class NoiseSuggestionWindowManager {
    private var window: NSWindow?
    private var dismissTimer: Timer?

    /// Show/hide driven by `appState.showNoiseSuggestion` via `.onChange` in the app scene.
    func update(show: Bool, appState: AppState) {
        if show {
            showWindow(appState: appState)
        } else {
            hideWindow()
        }
    }

    private func showWindow(appState: AppState) {
        if window == nil {
            let toast = NoiseSuggestionToastView(appState: appState)
            let hostingController = NSHostingController(rootView: toast)

            let newWindow = NoiseToastPanel(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
                styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            newWindow.contentViewController = hostingController
            newWindow.backgroundColor = .clear
            newWindow.isOpaque = false
            newWindow.hasShadow = true
            newWindow.level = .floating
            newWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // Size to the SwiftUI content, then position near top-center of the active screen.
            let fitting = hostingController.view.fittingSize
            newWindow.setContentSize(fitting)
            if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
                let origin = NSPoint(
                    x: visible.midX - fitting.width / 2,
                    y: visible.maxY - fitting.height - 24
                )
                newWindow.setFrameOrigin(origin)
            }

            self.window = newWindow
        }

        window?.orderFrontRegardless()

        // Auto-dismiss after a few seconds if the user doesn't act.
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak appState] _ in
            appState?.dismissNoiseSuggestion(forever: false)
        }
    }

    private func hideWindow() {
        dismissTimer?.invalidate()
        dismissTimer = nil
        window?.orderOut(nil)
        window = nil
    }
}

// MARK: - Toast View

/// The compact suggestion card shown inside the floating panel.
private struct NoiseSuggestionToastView: View {
    @Bindable var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 18))
                .foregroundStyle(Theme.Colors.orange)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Noisy environment detected")
                    .font(Theme.Typography.body(13, weight: .semibold))

                Text("Turn on noise reduction for your next recordings?")
                    .font(Theme.Typography.body(11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.sm) {
                    Button("Enable") {
                        appState.enableNoiseReductionFromSuggestion()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Not now") {
                        appState.dismissNoiseSuggestion(forever: false)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Don't suggest again") {
                        appState.dismissNoiseSuggestion(forever: true)
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .font(Theme.Typography.body(10, weight: .light))
                    .foregroundStyle(.secondary)
                }
                .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(width: 320, alignment: .leading)
        .cardStyle()
    }
}
