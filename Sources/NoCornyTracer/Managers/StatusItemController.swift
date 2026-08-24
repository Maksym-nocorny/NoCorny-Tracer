import AppKit

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

    // MARK: - Wiring

    /// Command-bar entry points, injected by AppDelegate so the controller never
    /// reaches into the window managers directly.
    struct Actions {
        var showCommandBar: () -> Void      // idle left click + "Open Tracer"
        var showGallery: () -> Void         // background left click → bar + gallery drawer
        var showSettings: () -> Void        // "Settings…" → bar + settings drawer
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

        switch Self.state(isRecording: isRecording, formattedDuration: nil, backgroundCount: backgroundCount) {
        case .recording:
            Task { @MainActor in
                await AppState.shared?.stopRecording()
            }
        case .background:
            actions.showGallery()
        case .idle:
            actions.showCommandBar()
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

        // Recording controls on top, mid-take only (the old menu's functionality;
        // the macro's menu is drawn in the idle state).
        if isRecording {
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

    @objc private func stopRecording() {
        Task { @MainActor in
            await AppState.shared?.stopRecording()
        }
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
}
