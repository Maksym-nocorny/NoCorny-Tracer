import AppKit
#if DEBUG
import SwiftUI  // Theme colors for the UI Preview toasts
#endif

/// The menu-bar (tray) presence of the app, extracted from AppDelegate in redesign
/// phase 5. Owns the NSStatusItem, its icon/title rendering, the click routing and
/// the context menu (Figma 89:786 for the three states, 63:153 for the menu).
///
/// State → pixels is split into two pure static functions (`state(...)` and
/// `render(...)`) so the mapping is testable without a status bar.
@MainActor
final class StatusItemController: NSObject {

    // MARK: - Pure state mapping

    /// The three tray states of the redesign (Figma 89:786). Recording wins over
    /// background activity: a red dot + timer says strictly more than "↑N".
    enum TrayState: Equatable {
        case idle
        case recording(timer: String)
        case background(count: Int)
    }

    /// What the status-item button should show for a state. Pure data — the
    /// AppKit-facing `refresh()` only translates it into an image + title.
    struct Render: Equatable {
        enum Icon: Equatable {
            case idleMark        // menubar_idle_template (the record mark, template-tinted)
            case recordingDot    // menubar_rec_light/dark (the red dot)
            case backgroundCloud // SF icloud.and.arrow.up, template
        }
        var icon: Icon
        var title: String
    }

    /// Recording has priority over background jobs; background shows only for a
    /// positive count. A recording with no formatted duration yet renders "00:00"
    /// rather than an empty timer.
    static func state(isRecording: Bool, formattedDuration: String?, backgroundCount: Int) -> TrayState {
        if isRecording {
            return .recording(timer: formattedDuration ?? "00:00")
        }
        if backgroundCount > 0 {
            return .background(count: backgroundCount)
        }
        return .idle
    }

    static func render(_ state: TrayState) -> Render {
        switch state {
        case .idle:
            return Render(icon: .idleMark, title: "")
        case .recording(let timer):
            return Render(icon: .recordingDot, title: " \(timer)")
        case .background(let count):
            return Render(icon: .backgroundCloud, title: " ↑\(count)")
        }
    }

    /// What a plain left click on the tray icon does. Pure for the same reason as
    /// `state(...)`/`render(...)` — the routing is testable without a status bar.
    ///
    /// Round 3: mid-recording the answer depends on whether the pill panel is on
    /// screen. The pill grew a "hide" button, and a hidden pill's first tray click
    /// brings it BACK; only a click with the pill visible stops the take. Стоп зі
    /// схованою пігулкою — два кліки: чесний компроміс, бо один і той самий клік
    /// не може означати і «покажи», і «зупини», а зупинка наосліп гірша за зайвий
    /// клік. (The tray menu's Stop still stops in one go from anywhere.)
    enum LeftClickAction: Equatable {
        case stopRecording
        case showRecordingPill
        case showGallery
        case showCommandBar
    }

    static func leftClickAction(state: TrayState, isCommandBarVisible: Bool) -> LeftClickAction {
        switch state {
        case .recording:
            return isCommandBarVisible ? .stopRecording : .showRecordingPill
        case .background:
            return .showGallery
        case .idle:
            return .showCommandBar
        }
    }

    // MARK: - Wiring

    /// Command-bar entry points, injected by AppDelegate so the controller never
    /// reaches into the window managers directly.
    struct Actions {
        var showCommandBar: () -> Void      // idle left click + "Open Tracer" (+ hidden pill's way back)
        var showGallery: () -> Void         // background left click → bar + gallery drawer
        var showSettings: () -> Void        // "Settings…" → bar + settings drawer
        /// Whether the command-bar panel (bar or pill) is on screen right now —
        /// feeds `leftClickAction` (round 3: hidden pill vs stop).
        var isCommandBarVisible: () -> Bool
    }

    private let actions: Actions
    private var statusItem: NSStatusItem?

    /// One 1-second tick drives every tray update. Deliberately a timer, not
    /// `withObservationTracking`: the observable `recordingDuration` mutates 10×/s
    /// (RecordingManager's 0.1s duration timer), so observation would fire ten times
    /// as often as this ticks. The tick recomputes the pure `Render` and compares it
    /// to the last one — AppKit is only touched when something actually changed, so
    /// idle ticks cost a couple of struct reads. 1s granularity is enough for a
    /// mm:ss timer (the macro shows whole seconds) and for the ↑N counter.
    private var refreshTimer: Timer?
    private var lastRender: Render?
    private var lastIsDark: Bool?

    // Preloaded menu bar images (moved verbatim from AppDelegate).
    private var idleImage: NSImage?       // template — macOS auto-tints for menubar
    private var recordingLightImage: NSImage?
    private var recordingDarkImage: NSImage?
    private lazy var backgroundImage: NSImage? = {
        // The macro's cloud at 15pt (89:797). Template so it tints like the idle mark.
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let image = NSImage(
            systemSymbolName: "icloud.and.arrow.up",
            accessibilityDescription: "NoCorny Tracer, background activity"
        )?.withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }()

    init(actions: Actions) {
        self.actions = actions
        super.init()
    }

    // MARK: - Lifecycle

    func attach() {
        loadMenuBarImages()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Monospaced digits stop the recording timer from wiggling as digits change
        // (the macro's timer is mono — 89:795).
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        refresh()

        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        refreshTimer = timer

        // The recording dot is a colored (non-template) asset, so it must be swapped
        // when the menubar's appearance flips.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    func detach() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        DistributedNotificationCenter.default().removeObserver(self)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    // MARK: - Rendering

    @objc private func appearanceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.lastIsDark = nil // force refresh
            self?.refresh()
        }
    }

    private func refresh() {
        guard let button = statusItem?.button else { return }

        let appState = AppState.shared
        let isRecording = appState?.recordingManager.isRecording ?? false
        let duration = appState?.recordingManager.formattedDuration
        let backgroundCount = appState.map { BackgroundActivity.totalBackgroundCount(recordings: $0.recordings) } ?? 0

        let render = Self.render(Self.state(
            isRecording: isRecording,
            formattedDuration: duration,
            backgroundCount: backgroundCount
        ))
        // System appearance (not NSApp.effectiveAppearance, which follows the app's theme).
        let isDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"

        guard render != lastRender || isDark != lastIsDark else { return }
        lastRender = render
        lastIsDark = isDark

        button.title = render.title
        button.image = image(for: render.icon, isDark: isDark)
    }

    private func image(for icon: Render.Icon, isDark: Bool) -> NSImage? {
        let image: NSImage?
        switch icon {
        case .idleMark:
            image = idleImage
        case .recordingDot:
            image = isDark ? recordingDarkImage : recordingLightImage
        case .backgroundCloud:
            image = backgroundImage
        }
        if let image { return image }

        // Fallback to SF Symbols if a PNG set failed to load.
        let fallbackName: String
        switch icon {
        case .idleMark: fallbackName = "record.circle"
        case .recordingDot: fallbackName = "record.circle.fill"
        case .backgroundCloud: fallbackName = "icloud.and.arrow.up"
        }
        let fallback = NSImage(systemSymbolName: fallbackName, accessibilityDescription: "NoCorny Tracer")
        fallback?.isTemplate = true
        return fallback
    }

    // MARK: - Menu bar images (moved from AppDelegate)

    private func loadMenuBarImages() {
        // icon-v2 menubar set: drawn at natural 22×22 pt, shipped as @1x/@2x/@3x PNGs.
        idleImage = loadMenuBarImage(baseName: "menubar_idle_template", isTemplate: true)
        recordingLightImage = loadMenuBarImage(baseName: "menubar_rec_light", isTemplate: false)
        recordingDarkImage = loadMenuBarImage(baseName: "menubar_rec_dark", isTemplate: false)
    }

    /// Builds one NSImage out of the @1x/@2x/@3x PNG scale set so the menubar
    /// picks the right representation for the current display.
    private func loadMenuBarImage(baseName: String, isTemplate: Bool) -> NSImage? {
        let bundle = Bundle.appResources
        let pointSize = NSSize(width: 22, height: 22)
        let image = NSImage(size: pointSize)

        for suffix in ["", "@2x", "@3x"] {
            let name = baseName + suffix
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources")
                    ?? bundle.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = pointSize  // 22 pt regardless of pixel density
            image.addRepresentation(rep)
        }

        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = isTemplate  // template = macOS auto-tints for menubar appearance
        image.accessibilityDescription = "NoCorny Tracer"
        return image
    }

    // MARK: - Click routing

    /// Left click: idle → command bar, recording → stop, background → bar + gallery.
    /// ⌥-left-click → Show Logs (the design note on 63:153). Right click → menu.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showMenu()
            return
        }

        if event.modifierFlags.contains(.option) {
            showLogs()
            return
        }

        let appState = AppState.shared
        let isRecording = appState?.recordingManager.isRecording ?? false
        let backgroundCount = appState.map { BackgroundActivity.totalBackgroundCount(recordings: $0.recordings) } ?? 0

        let state = Self.state(isRecording: isRecording, formattedDuration: nil, backgroundCount: backgroundCount)
        switch Self.leftClickAction(state: state, isCommandBarVisible: actions.isCommandBarVisible()) {
        case .stopRecording:
            Task { @MainActor in
                await AppState.shared?.stopRecording()
            }
        case .showRecordingPill, .showCommandBar:
            // Same door: `show()` comes up as the pill whenever a take is live.
            actions.showCommandBar()
        case .showGallery:
            actions.showGallery()
        }
    }

    private func showMenu() {
        guard let item = statusItem else { return }
        let menu = buildMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    // MARK: - Context menu (Figma 63:153)

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let isRecording = AppState.shared?.recordingManager.isRecording ?? false
        let isPaused = AppState.shared?.recordingManager.isPaused ?? false

        // 4.2.0: a downloaded update waits for a relaunch — the chip rides on top
        // of everything, mid-take included (the click then explains instead of
        // relaunching; UpdateChipState decides).
        if let chip = UpdateCoordinator.shared?.chipState {
            let updateItem = NSMenuItem(
                title: chip.title,
                action: #selector(relaunchToUpdate),
                keyEquivalent: ""
            )
            updateItem.target = self
            menu.addItem(updateItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Recording controls on top, mid-take only (the old menu's functionality;
        // the macro's menu is drawn in the idle state).
        if isRecording {
            // Round 3: a pill hidden via its chevron gets an explicit way back in
            // the menu, above the take controls (a left tray click does the same).
            if !actions.isCommandBarVisible() {
                let showPillItem = NSMenuItem(
                    title: "Show recording pill",
                    action: #selector(showRecordingPill),
                    keyEquivalent: ""
                )
                showPillItem.target = self
                menu.addItem(showPillItem)
                menu.addItem(NSMenuItem.separator())
            }

            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopRecording), keyEquivalent: "r")
            stopItem.keyEquivalentModifierMask = [.option, .shift]
            stopItem.target = self
            menu.addItem(stopItem)

            let pauseItem = NSMenuItem(
                title: isPaused ? "Resume" : "Pause",
                action: #selector(togglePause),
                keyEquivalent: "p"
            )
            pauseItem.keyEquivalentModifierMask = [.option, .shift]
            pauseItem.target = self
            menu.addItem(pauseItem)

            let discardItem = NSMenuItem(title: "Discard", action: #selector(discardRecording), keyEquivalent: "x")
            discardItem.keyEquivalentModifierMask = [.option, .shift]
            discardItem.target = self
            menu.addItem(discardItem)

            menu.addItem(NSMenuItem.separator())
        }

        // The macro pairs "Open Tracer" with ⌥⇧R. Mid-take that combo belongs to
        // Stop (above) — showing it twice in one menu would be a lie, so the hint
        // only appears when idle.
        let openItem = NSMenuItem(
            title: "Open Tracer",
            action: #selector(openTracer),
            keyEquivalent: isRecording ? "" : "r"
        )
        if !isRecording { openItem.keyEquivalentModifierMask = [.option, .shift] }
        openItem.target = self
        menu.addItem(openItem)

        // "Library ↗" — the arrow marks it as leaving the app (opens the web dashboard).
        let libraryItem = NSMenuItem(title: "Library ↗", action: #selector(openLibrary), keyEquivalent: "")
        libraryItem.target = self
        menu.addItem(libraryItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        menu.addItem(settingsItem)

        #if DEBUG
        menu.addItem(NSMenuItem.separator())
        menu.addItem(uiPreviewMenuItem())
        #endif

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About NoCorny Tracer", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Menu actions

    /// The "Relaunch to update vX.Y.Z" chip: staged install + relaunch, or the
    /// mid-take explanation — the coordinator decides.
    @objc private func relaunchToUpdate() {
        UpdateCoordinator.shared?.installPendingUpdate()
    }

    @objc private func stopRecording() {
        Task { @MainActor in
            await AppState.shared?.stopRecording()
        }
    }

    /// "Show recording pill" (round 3): the pill was hidden mid-take — bring the
    /// panel back; `show()` restores the pill surface for a live recording.
    @objc private func showRecordingPill() {
        actions.showCommandBar()
    }

    @objc private func togglePause() {
        Task { @MainActor in
            await AppState.shared?.recordingManager.togglePause()
        }
    }

    @objc private func discardRecording() {
        Task { @MainActor in
            await AppState.shared?.abortRecording()
        }
    }

    @objc private func openTracer() {
        actions.showCommandBar()
    }

    @objc private func openLibrary() {
        AppState.shared?.openTracerDashboard()
    }

    @objc private func openSettings() {
        actions.showSettings()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(self)
    }

    /// Same destination as the Settings drawer's "Show Logs" link.
    private func showLogs() {
        NSWorkspace.shared.selectFile(
            LogManager.shared.getLogFileURL().path,
            inFileViewerRootedAtPath: ""
        )
    }

    // MARK: - UI Preview (DEBUG builds only, verdict 24.08)

    #if DEBUG
    /// Fake-state previews of the surfaces a demo cannot reach without Screen
    /// Recording permission and a live take: the recording/paused pill, both
    /// toast kinds and the storage banner. Everything runs through
    /// `UIPreviewState` (never the real recording path) except the toasts,
    /// which use the real `presentToast` door — they are transient anyway.
    private func uiPreviewMenuItem() -> NSMenuItem {
        let submenu = NSMenu(title: "UI Preview")
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            submenu.addItem(item)
        }
        add("Recording pill", #selector(previewRecordingPill))
        add("Paused pill", #selector(previewPausedPill))
        submenu.addItem(.separator())
        add("Update chip preview", #selector(previewUpdateChip))
        submenu.addItem(.separator())
        add("Toast: link copied", #selector(previewToastLinkCopied))
        add("Toast: mic lost (critical)", #selector(previewToastMicLost))
        submenu.addItem(.separator())
        add("Storage banner: low", #selector(previewBannerLow))
        add("Storage banner: full", #selector(previewBannerFull))
        submenu.addItem(.separator())
        // Round 12 removed "Capturable panels (design review)": the bar is an
        // ordinary window and shows up in captures by itself, so a design review
        // needs no escape hatch, and the pill's invisibility is not negotiable.
        add("Reset preview", #selector(previewReset))

        let root = NSMenuItem(title: "UI Preview", action: nil, keyEquivalent: "")
        root.submenu = submenu
        return root
    }

    /// The bar must be up for the pill/banner previews — CommandBarRootView is
    /// what reads the preview state and morphs the panel.
    @objc private func previewRecordingPill() {
        actions.showCommandBar()
        UIPreviewState.shared.showPill(paused: false)
    }

    @objc private func previewPausedPill() {
        actions.showCommandBar()
        UIPreviewState.shared.showPill(paused: true)
    }

    /// The bar chip's preview (round 8: the same product door as the Settings
    /// toggle — session-only, current version, real update outranks it).
    /// "Reset preview" clears it.
    @objc private func previewUpdateChip() {
        actions.showCommandBar()
        UpdateCoordinator.shared?.setChipPreview(enabled: true)
    }

    /// Mirrors the upload-completion FALLBACK toast (round 7: the primary
    /// announcement is a system notification; this toast shows only when
    /// notifications are unavailable or denied — see AppNotifications).
    @objc private func previewToastLinkCopied() {
        AppState.shared?.presentToast?(ToastContent(
            icon: "link",
            iconColor: Theme.Colors.statusGreen,
            message: "Uploaded — link copied"
        ))
    }

    /// Mirrors the real mic-death critical toast (AppState's device-loss hook).
    @objc private func previewToastMicLost() {
        AppState.shared?.presentToast?(ToastContent(
            icon: "mic.slash",
            iconColor: Theme.Colors.recordRed,
            message: "The microphone stopped recording — stop and start a new take to get your voice back",
            duration: 8,
            priority: .critical
        ))
    }

    @objc private func previewBannerLow() {
        actions.showCommandBar()
        UIPreviewState.shared.storageLevel = .low(minutesLeft: 12)
    }

    @objc private func previewBannerFull() {
        actions.showCommandBar()
        UIPreviewState.shared.storageLevel = .full
    }

    @objc private func previewReset() {
        UIPreviewState.shared.reset()
        UpdateCoordinator.shared?.setChipPreview(enabled: false)
    }

    #endif
}
