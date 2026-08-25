import AppKit
import Foundation
import Sparkle

/// The pure decision behind the "Relaunch to update" chip (4.2.0): whether the
/// chip exists on the surfaces (tray menu, Settings drawer), what it says, and
/// what a click does. Kept free of Sparkle so the mapping is testable without
/// an updater.
struct UpdateChipState: Equatable {
    enum ClickAction: Equatable {
        /// Install the staged update and relaunch — no UI in between.
        case installAndRelaunch
        /// A recording is running: a relaunch would end the take, so the click
        /// explains instead. The chip stays visible mid-take on purpose.
        case explainRecordingBlock
    }

    var title: String
    var clickAction: ClickAction

    /// nil = no chip (nothing pending). Appcast versions arrive as "4.2.0" —
    /// the title adds the "v", without doubling one that is already there.
    static func decide(pendingVersion: String?, isRecording: Bool) -> UpdateChipState? {
        guard let version = pendingVersion, !version.isEmpty else { return nil }
        let display = version.hasPrefix("v") ? version : "v\(version)"
        return UpdateChipState(
            title: "Relaunch to update \(display)",
            clickAction: isRecording ? .explainRecordingBlock : .installAndRelaunch
        )
    }
}

/// Runs the app's whole update story around Sparkle. Grew out of UpdateScheduler
/// in 4.2.0 — the recording gate stayed, the Claude Code-style silent cycle is new:
///
/// 1. **Recording gate** (`updater(_:mayPerform:)`): scheduled checks are declined
///    mid-take — Sparkle's dialog would land in the capture, and "Install and
///    Relaunch" would kill the meeting. A check the user asked for passes.
/// 2. **Silent cycle**: with `SUEnableAutomaticChecks` + `SUAutomaticallyUpdate`
///    in Info.plist, scheduled checks download and stage updates with no UI at
///    all (SPUAutomaticUpdateDriver). When the staged install is ready, Sparkle
///    calls `willInstallUpdateOnQuit` — we keep its immediate-install door and
///    publish `pendingUpdateVersion`, which the chip surfaces read. Returning
///    `true` does NOT disarm install-on-quit: "In either case Sparkle will
///    always attempt to install the update when the app terminates"
///    (SPUUpdaterDelegate.h) — so an ignored chip still updates on the next quit.
/// 3. **Gentle reminders** (SPUStandardUserDriverDelegate): scheduled updates
///    Sparkle would eventually want to SHOW (the 7-day impatient reminder for a
///    staged install, major upgrades, auto-download toggled off) are routed to
///    the chip too — a Sparkle window never appears for scheduled checks. This
///    matters doubly here: for a regular app that is almost never active
///    (nonactivating panels) those windows would open BEHIND everything anyway.
/// 4. The manual "Check for Updates" flow stays fully Sparkle-standard — an
///    explicit click may show a dialog (see `requestUserInitiatedCheck`).
@Observable
final class UpdateCoordinator: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {

    /// Weak static access for the chip surfaces (tray menu, Settings drawer) —
    /// the instance itself is retained by NoCornyTracerApp for the lifetime of
    /// the process, same pattern as AppState.shared.
    private(set) static weak var shared: UpdateCoordinator?

    /// Nil until AppState exists. Read at the moment Sparkle asks rather than
    /// captured, so a recording that starts after launch still counts.
    @ObservationIgnored var isRecording: () -> Bool = { false }

    /// The version waiting for a relaunch — nil when nothing is pending. Set
    /// when a silent download finishes staging (`willInstallUpdateOnQuit`) or
    /// when Sparkle announces a scheduled update through the gentle-reminder
    /// door. Observable: the drawer row re-renders when it flips.
    private(set) var pendingUpdateVersion: String?

    /// Sparkle's immediate-install door: staged install + relaunch with no UI.
    /// Since Sparkle 2.3 it may be invoked again if a termination was cancelled
    /// (e.g. our own applicationShouldTerminate finishing a take).
    @ObservationIgnored private var immediateInstallHandler: (() -> Void)?
    /// One "downloaded" toast per version per session.
    @ObservationIgnored private var announcedVersion: String?

    override init() {
        super.init()
        Self.shared = self
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, mayPerform check: SPUUpdateCheck) throws {
        // A check the user asked for is theirs to make - they can see what is on screen.
        guard check == .updatesInBackground, isRecording() else { return }
        LogManager.shared.log("⬆️ Updater: declined a background check - a recording is running")
        throw NSError(
            domain: "com.nocorny.tracer.updater",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "A recording is in progress"]
        )
    }

    /// A silent update finished downloading and is staged for install-on-quit.
    /// Keep the handler for the chip and say `true` — install-on-quit stays
    /// armed either way (see the class note), this only stalls further update
    /// cycles while ours is pending.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        self.immediateInstallHandler = immediateInstallHandler
        noteUpdatePending(version: item.displayVersionString, downloaded: true)
        return true
    }

    // MARK: - SPUStandardUserDriverDelegate (gentle reminders)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// `false` = the app handles showing scheduled updates itself (the chip);
    /// Sparkle's own window never appears for a scheduled check.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Only when the standard driver is NOT handling it (we returned false
        // above). `.installing` covers a staged install resurfacing after the
        // impatient interval; `.notDownloaded` is the rare non-silent scheduled
        // update (major upgrade, info-only) — chip too, honest toast skipped.
        guard !handleShowingUpdate else { return }
        noteUpdatePending(
            version: update.displayVersionString,
            downloaded: state.stage != .notDownloaded
        )
    }

    // MARK: - Pending state

    private func noteUpdatePending(version: String, downloaded: Bool) {
        if pendingUpdateVersion != version {
            LogManager.shared.log(
                "⬆️ Updater: v\(version) pending (\(downloaded ? "staged" : "not downloaded yet")) — relaunch chip on"
            )
        }
        pendingUpdateVersion = version

        // The one-time heads-up; the chip carries the state from here on.
        guard downloaded, announcedVersion != version else { return }
        announcedVersion = version
        let display = version.hasPrefix("v") ? version : "v\(version)"
        AppState.shared?.presentToast?(ToastContent(
            icon: "arrow.down.circle",
            iconColor: Theme.Colors.statusGreen,
            message: "Update \(display) downloaded. Relaunch when convenient.",
            duration: 6
        ))
    }

    // MARK: - The chip's click (tray menu item + drawer row)

    /// What the surfaces render right now — nil hides the chip.
    var chipState: UpdateChipState? {
        UpdateChipState.decide(pendingVersion: pendingUpdateVersion, isRecording: isRecording())
    }

    func installPendingUpdate() {
        guard let chip = chipState else { return }
        switch chip.clickAction {
        case .explainRecordingBlock:
            AppState.shared?.presentToast?(ToastContent(
                icon: "arrow.triangle.2.circlepath",
                iconColor: Theme.Colors.pausedAmber,
                message: "The update installs after this recording finishes"
            ))
        case .installAndRelaunch:
            LogManager.shared.log(
                "⬆️ Updater: relaunch-to-update clicked (\(pendingUpdateVersion ?? "?"))"
            )
            if let install = immediateInstallHandler {
                // Staged install + relaunch, no UI (SPUAutomaticUpdateDriver).
                install()
            } else {
                // The chip came from a scheduled announcement without a staged
                // install (major upgrade / info-only / auto-download off): fall
                // back to the focused user-initiated flow — Sparkle resumes the
                // update with its standard dialog, in front.
                Self.requestUserInitiatedCheck()
            }
        }
    }

    // MARK: - Manual check (the drawer's "Check for Updates" link)

    /// Activation FIRST, and unconditionally: Sparkle only self-activates for
    /// LSUIElement apps, and this regular-but-never-active panel app otherwise
    /// gets every Sparkle window ("Checking for updates…", "You're up to date",
    /// the update dialog) opened BEHIND the frontmost app — the 4.0.0 "button
    /// does nothing" bug. The click is explicit user intent, so stealing focus
    /// is the correct move.
    static func requestUserInitiatedCheck() {
        LogManager.shared.log("⬆️ Updater: update check requested")
        NSApp.activate(ignoringOtherApps: true)
        guard let controller = (NSApp.delegate as? AppDelegate)?.updaterController
                ?? AppDelegate.bootstrapUpdaterController else {
            LogManager.shared.log(
                "⬆️ Updater: no updater controller at click — check not started",
                type: .error
            )
            return
        }
        controller.checkForUpdates(nil)
    }
}
