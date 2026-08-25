#if DEBUG
import Foundation
import Observation

/// Fake data source for eyeballing the recording pill, the background-activity
/// pills and the storage banner without Screen Recording permission or a live
/// take (verdict 24.08: the demo build could not show any of them). Driven from
/// the tray's DEBUG-only "UI Preview" submenu (StatusItemController); the views
/// read this state FIRST and fall back to the real managers when nothing is
/// being previewed. Toasts need no state here — the preview menu pushes them
/// through the real `presentToast` door, which is transient by nature.
///
/// DEBUG-only by construction: the class, the menu and every reading branch sit
/// behind `#if DEBUG`, so none of this code exists in a release build. Nothing
/// is persisted and the real RecordingManager / Recording / UserDefaults are
/// never touched (the live-test-app-pollutes-real-defaults lesson).
@Observable @MainActor
final class UIPreviewState {
    static let shared = UIPreviewState()
    private init() {}

    enum PillState { case recording, paused }

    // MARK: State the views read

    /// Recording-pill preview (nil = off). CommandBarRootView morphs the panel
    /// to/from `.recordingPill` when this flips.
    private(set) var pill: PillState?
    /// Fake seconds behind the pill timer; ticks while `pill == .recording`.
    private(set) var elapsed: TimeInterval = 0

    private(set) var isUploading = false
    private(set) var transcribingCount: Int?
    /// Fake background-pill progress, cycling 0→1→0 so the numbers visibly move.
    private(set) var progress: Double = 0.34

    /// Fake quota level for the storage banner (nil = the real quota decides).
    var storageLevel: StorageAlertLevel?

    // MARK: Derived shapes the pill views consume

    var uploadPill: UploadPillState? {
        isUploading ? UploadPillState(count: 1, fraction: progress) : nil
    }

    var transcribePill: TranscribePillState? {
        transcribingCount.map { TranscribePillState(count: $0, fraction: progress) }
    }

    var hasBackgroundPills: Bool { isUploading || transcribingCount != nil }

    /// mm:ss, same shape as RecordingManager.formattedDuration.
    var formattedElapsed: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Menu entry points

    func showPill(paused: Bool) {
        pill = paused ? .paused : .recording
        if elapsed == 0 {
            // A paused take frozen at 00:00 reads as broken — start mid-take.
            elapsed = paused ? 83 : 0
        }
        ensureTicker()
    }

    func endPill() {
        pill = nil
        elapsed = 0
    }

    func togglePaused() {
        guard let pill else { return }
        self.pill = pill == .paused ? .recording : .paused
        ensureTicker()
    }

    func showUploading() {
        isUploading = true
        progress = 0.34
        ensureTicker()
    }

    func showTranscribing(count: Int) {
        transcribingCount = count
        ensureTicker()
    }

    func reset() {
        pill = nil
        elapsed = 0
        isUploading = false
        transcribingCount = nil
        storageLevel = nil
        stopTicker()
    }

    // MARK: Fake clock

    private var ticker: Task<Void, Never>?

    private var needsTicker: Bool { pill == .recording || hasBackgroundPills }

    private func ensureTicker() {
        guard ticker == nil, needsTicker else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                self.tick()
                if !self.needsTicker {
                    self.stopTicker()
                    return
                }
            }
        }
    }

    /// One half-second beat: the pill timer counts, the pill progress loops
    /// (~22s per lap, restarting low rather than at zero so the loop is obvious).
    private func tick() {
        if pill == .recording { elapsed += 0.5 }
        if hasBackgroundPills {
            progress += 0.015
            if progress >= 1 { progress = 0.05 }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }
}
#endif
