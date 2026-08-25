import SwiftUI
import AppKit

// MARK: - Root

/// Content of the floating command-bar panel. Switches between the redesign's
/// surfaces: bar (with the storage banner under it when the quota runs low),
/// bar+drawer, and the recording pill.
struct CommandBarRootView: View {
    @Bindable var appState: AppState
    let manager: CommandBarWindowManager

    /// Same used/allocated the drawer footer reads. `.ok` for a missing/zero
    /// allocation, so a signed-out bar never grows an amber line.
    /// DEBUG: the tray's UI Preview can fake a level to show the banner.
    private var storageLevel: StorageAlertLevel {
        #if DEBUG
        if let previewLevel = UIPreviewState.shared.storageLevel { return previewLevel }
        #endif
        return StorageAlert.level(used: appState.dropboxUsedSpace,
                                  allocated: appState.dropboxAllocatedSpace)
    }

    var body: some View {
        // One stable CommandBarView across bar↔drawer↔banner (so the bar itself
        // never fades during those morphs), with transitions on what hangs under
        // it; the pill is the only surface that replaces the bar wholesale —
        // crossfade + slight scale, riding the panel's own frame animation.
        Group {
            if manager.surface == .recordingPill {
                RecordingPillView(appState: appState, manager: manager)
                    .transition(.scale(scale: 0.92, anchor: .topLeading).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    CommandBarView(appState: appState, manager: manager)
                    if case .barWithDrawer(let tab) = manager.surface {
                        drawerContent(tab)
                            .padding(.top, MorphGeometry.drawerGap)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    // Banner on the plain bar ONLY (decision, phase 4): the pill stays
                    // minimal mid-take; the drawer already shows the quota in its
                    // Dropbox row. See StorageBannerView.
                    if manager.surface == .bar, storageLevel != .ok {
                        StorageBannerView(appState: appState, level: storageLevel)
                            .padding(.top, MorphGeometry.bannerGap)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .transition(.scale(scale: 0.98, anchor: .topLeading).combined(with: .opacity))
            }
        }
        .animation(Theme.Anim.surface, value: manager.surface)
        .animation(Theme.Anim.surface, value: storageLevel)
        // The panel is `panelShadowInset` larger than the glass on every side so the
        // SwiftUI shadow has room to draw (the panel's own shadow is off).
        .padding(MorphGeometry.panelShadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keep the panel's NSAppearance pinned to the in-app theme toggle.
        .onChange(of: appState.appTheme, initial: true) {
            manager.applyPanelAppearance()
        }
        // THE morph driver for recording (phase 4): every start door (bar button,
        // hotkey, tray menu) flips `isRecording`, so observing it here collapses the
        // bar into the pill no matter who started the take — and brings the bar back
        // (drawer closed) on stop/abort.
        .onChange(of: appState.recordingManager.isRecording) { _, isRecording in
            manager.morph(to: isRecording ? .recordingPill : .bar)
        }
        // Keep the panel's frame in sync with the banner: the quota can cross the
        // threshold mid-session (an upload finishing refreshes used/allocated).
        .onChange(of: storageLevel != .ok, initial: true) { _, visible in
            manager.setStorageBannerVisible(visible)
        }
        // Same refresh contract the old MainView tabs had (onChange(selectedTab)):
        // opening the Gallery pulls fresh recording metadata, opening Settings
        // refreshes the profile and the Dropbox link state.
        .onChange(of: manager.surface) { _, newSurface in
            guard case .barWithDrawer(let tab) = newSurface,
                  appState.tracerAPIClient.isSignedIn else { return }
            switch tab {
            case .gallery:
                Task { await appState.reloadRecordingsFromTracer() }
            case .settings:
                Task { await appState.tracerAPIClient.refreshProfile() }
                Task { await appState.syncDropboxFromTracer() }
            }
        }
        #if DEBUG
        // UI Preview (tray submenu): a fake recording pill morphs the panel the
        // same way a real take does. A real recording always wins the surface.
        .onChange(of: UIPreviewState.shared.pill != nil) { _, previewActive in
            guard !appState.recordingManager.isRecording else { return }
            manager.morph(to: previewActive ? .recordingPill : .bar)
        }
        #endif
    }

    /// The open drawer. Each tab carries its own `.opacity` transition so flipping
    /// gallery↔settings crossfades, while the containing `if case` above owns the
    /// open/close slide.
    @ViewBuilder
    private func drawerContent(_ tab: CommandBarDrawerTab) -> some View {
        switch tab {
        case .gallery:
            DrawerGalleryView(appState: appState)
                .transition(.opacity)
        case .settings:
            DrawerSettingsView(appState: appState, manager: manager)
                .transition(.opacity)
        }
    }
}

// MARK: - Command bar

/// The 560×80 floating bar, laid out per Figma node 76:168: record mark, timer,
/// divider, capture-mode capsule, mic/cam toggles, divider, library/settings,
/// then a close button pinned to the trailing edge.
struct CommandBarView: View {
    @Bindable var appState: AppState
    let manager: CommandBarWindowManager

    @State private var showCaptureMenu = false
    @State private var recordHovering = false
    @State private var captureHovering = false

    private var isRecording: Bool { appState.recordingManager.isRecording }

    var body: some View {
        HStack(spacing: 13) {
            recordButton
            timerText
            divider
            captureModeButton
            micButton
            camButton
            divider
            libraryButton
            settingsButton
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(
            width: Theme.Metrics.commandBarSize.width,
            height: Theme.Metrics.commandBarSize.height
        )
        .glassSurface(cornerRadius: Theme.Metrics.barCornerRadius)
        .floatingPanelShadow()
    }

    // MARK: Record

    private var recordButton: some View {
        Button {
            Task {
                if appState.recordingManager.isRecording {
                    await appState.stopRecording()
                } else {
                    // Same start path as RecordingControlsView, deliberately WITHOUT the
                    // old window's orderOut — the bar stays up (it never joins captures:
                    // the panel's sharingType is .none).
                    try? await appState.startRecording()
                }
            }
        } label: {
            RecordRingMark(diameter: 52, isSpinning: recordHovering)
        }
        .buttonStyle(.plain)
        .scaleEffect(recordHovering ? 1.05 : 1)
        .animation(Theme.Anim.hover, value: recordHovering)
        .onHover { recordHovering = $0 }
        .help(isRecording ? "Stop recording" : "Start recording")
        .pointingHandOnHover()
    }

    // MARK: Timer

    private var timerText: some View {
        Text(isRecording ? appState.recordingManager.formattedDuration : "00:00")
            .font(Theme.Typography.timer(26))
            .foregroundStyle(isRecording ? Theme.Colors.textPrimary : Theme.Colors.timerDimmed)
            .lineLimit(1)
            .fixedSize()
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Colors.glassDivider)
            .frame(width: 1, height: 36)
    }

    // MARK: Capture mode

    /// Tooltip for the capture-mode capsule: the mode, plus what it points at when it
    /// remembers something — "Window" answers "which window?" and "Selected Area"
    /// answers "how big?" (in pixels, matching the overlay's badge) without opening
    /// the menu.
    private var captureModeHelp: String {
        if appState.captureMode == .window,
           let title = appState.captureSelection.windowTitle, !title.isEmpty {
            return "\(appState.captureMode.displayName) - \(title)"
        }
        if appState.captureMode == .selectedArea,
           let rect = appState.captureSelection.areaRect,
           let scale = areaDisplayScale {
            return "\(appState.captureMode.displayName) - \(AreaSelectionGeometry.badgeText(for: rect, scale: scale)) px"
        }
        return appState.captureMode.displayName
    }

    /// Backing scale of the display the remembered area lives on — nil once that
    /// display is gone (the tooltip then degrades to the bare mode name rather than
    /// showing pixel numbers computed against the wrong screen).
    private var areaDisplayScale: CGFloat? {
        guard let displayID = appState.captureSelection.areaDisplayID else {
            return AreaSelectionWindowManager.screenWithMouse()?.backingScaleFactor
        }
        return NSScreen.screens
            .first { AreaSelectionWindowManager.displayID(of: $0) == displayID }?
            .backingScaleFactor
    }

    private var captureModeButton: some View {
        Button {
            showCaptureMenu.toggle()
        } label: {
            HStack(spacing: 5) {
                // The icon is the mode indicator: display / macwindow / viewfinder.
                Image(systemName: appState.captureMode.symbolName)
                    .font(.system(size: 15, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, 13)
            .frame(height: Theme.Metrics.controlSize)
            .background(captureHovering ? Theme.Colors.glassControlFillHover : Theme.Colors.glassControlFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.glassStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(captureHovering ? 1.03 : 1)
        .animation(Theme.Anim.hover, value: captureHovering)
        .onHover { captureHovering = $0 }
        .help(captureModeHelp)
        .pointingHandOnHover()
        .popover(isPresented: $showCaptureMenu, arrowEdge: .bottom) {
            CaptureModeMenu(appState: appState)
        }
    }

    // MARK: Mic / cam toggles

    private var micButton: some View {
        CommandToggleButton(
            systemName: "mic.fill",
            isOn: appState.isMicrophoneEnabled,
            help: isRecording
                ? "The microphone can only be changed before a recording starts"
                : "Record the microphone"
        ) {
            appState.isMicrophoneEnabled.toggle()
        }
        // Same rule as the old window: the capture device is fixed once recording starts.
        .disabled(isRecording)
    }

    private var camButton: some View {
        CommandToggleButton(
            systemName: "video.fill",
            isOn: appState.isCameraEnabled,
            help: "Show the camera bubble"
        ) {
            // The camera bubble itself rises via the existing onChange in NoCornyTracerApp.
            appState.isCameraEnabled.toggle()
        }
    }

    // MARK: Library / settings drawers

    private var libraryButton: some View {
        CommandGlassButton(
            systemName: "folder",
            badgeCount: BackgroundActivity.totalBackgroundCount(recordings: appState.recordings),
            help: "Recordings"
        ) {
            toggleDrawer(.gallery)
        }
    }

    private var settingsButton: some View {
        CommandGlassButton(systemName: "gearshape", help: "Settings") {
            toggleDrawer(.settings)
        }
    }

    private func toggleDrawer(_ tab: CommandBarDrawerTab) {
        if manager.surface == .barWithDrawer(tab) {
            manager.morph(to: .bar)
        } else {
            manager.morph(to: .barWithDrawer(tab))
        }
    }

    // MARK: Close

    private var closeButton: some View {
        CommandGlassButton(systemName: "xmark", help: "Quit NoCorny Tracer") {
            // The existing quit chain (applicationShouldTerminate) finalizes a live take.
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Capture mode menu

/// The capture-target picker, per macro frame 72:137 (224 wide).
///
/// The click contract for modes that point at something (decision, phase 6a; areas
/// joined in 6b): the Window row ALWAYS opens the system window picker and the
/// Selected Area row ALWAYS opens the selection overlay — picking/Enter saves the
/// choice and starts recording immediately. The remembered window or area is what
/// the record BUTTON reuses without a picker. One row, one behaviour — no separate
/// "Choose…" items, no guessing whether a click switches the mode or re-picks.
private struct CaptureModeMenu: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    dismiss()
                    switch mode {
                    case .window:
                        appState.chooseWindowForCapture()
                    case .selectedArea:
                        appState.chooseAreaForCapture()
                    case .entireScreen:
                        appState.captureMode = .entireScreen
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.displayName)
                                .font(Theme.Typography.body(13))
                            if mode == .window,
                               let title = appState.captureSelection.windowTitle, !title.isEmpty {
                                Text(title)
                                    .font(Theme.Typography.body(10))
                                    .foregroundStyle(Theme.Colors.timerDimmed)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 12)
                        if appState.captureMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                // No mode is gated today (phase 6b opened the last one); the styling
                // stays wired to `isAvailable` so a future half-shipped mode reads as
                // disabled instead of silently misrecording.
                .disabled(!mode.isAvailable)
                .opacity(mode.isAvailable ? 1 : 0.4)
            }
        }
        .padding(8)
        .frame(width: 224)
    }
}

// MARK: - Reusable controls

/// A 38×38 primary glass circle with an on/off state and a green status dot
/// (mic / camera toggles).
private struct CommandToggleButton: View {
    let systemName: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(isHovering ? Theme.Colors.glassControlFillHover : Theme.Colors.glassControlFill)
                Circle().strokeBorder(Theme.Colors.glassStroke, lineWidth: 1)
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn ? Theme.Colors.textPrimary : Theme.Colors.timerDimmed)
            }
            .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
            .overlay(alignment: .topTrailing) {
                if isOn {
                    Circle()
                        .fill(Theme.Colors.statusGreen)
                        .frame(width: 8, height: 8)
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.03 : 1)
        .animation(Theme.Anim.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
        .pointingHandOnHover()
    }
}

/// A 38×38 subtle glass circle (library / settings / close), with an optional
/// red counter badge (background uploads + transcriptions on the library button).
private struct CommandGlassButton: View {
    let systemName: String
    var badgeCount: Int = 0
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Hover steps the subtle fill up to the primary one.
                Circle().fill(isHovering ? Theme.Colors.glassControlFill : Theme.Colors.glassControlFillSubtle)
                Circle().strokeBorder(Theme.Colors.glassStrokeSubtle, lineWidth: 1)
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            .frame(width: Theme.Metrics.controlSize, height: Theme.Metrics.controlSize)
            .overlay(alignment: .topTrailing) {
                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(Theme.Typography.body(9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Theme.Colors.recordRed))
                        .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.03 : 1)
        .animation(Theme.Anim.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .help(help)
        .pointingHandOnHover()
    }
}

// MARK: - Record mark (native, verdict 24.08)

/// The record mark drawn natively: a round dashed blue ring around a blue-gradient
/// play triangle over a faint dark well — the sec1-bar.png reference at 52pt.
/// Replaces the commandbar_mark* PNGs (which stay in Resources untouched); native
/// drawing is what makes the hover spin/scale and any future morphs animatable.
///
/// Every metric scales with `diameter`, and the dash period divides the ring's
/// circumference exactly (10 periods at any size), so the dashes always meet
/// cleanly instead of leaving a seam.
struct RecordRingMark: View {
    var diameter: CGFloat = 52
    /// Marching-ants spin of the dashed ring. TASTE DECISION: the spin is
    /// hover-only, NOT always-on — the bar floats over the user's work all day,
    /// and a perpetually crawling selection frame in peripheral vision is
    /// distraction (plus a permanent animation in a floating panel costs battery
    /// on a machine that is busy recording). The ring wakes up when aimed at.
    var isSpinning: Bool = false

    @State private var spinAngle: Double = 0

    static let ringBlue = Color(hex: 0x3E90FF)

    private static let triangleGradient = LinearGradient(
        colors: [Color(hex: 0x0B5BE0), Color(hex: 0x0846B5)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The faint disc behind the triangle (the reference shows the ring's inside
    /// a notch darker than the bar glass).
    private static let wellFill = Color.adaptive(
        light: Color(hex: 0x0B1220, opacity: 0.05),
        dark: Color(hex: 0x000000, opacity: 0.25)
    )

    private var scale: CGFloat { diameter / 52 }
    private var lineWidth: CGFloat { 2.5 * scale }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth)
                .fill(Self.wellFill)
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Self.ringBlue, style: StrokeStyle(
                    lineWidth: lineWidth,
                    lineCap: .round,
                    // 10 exact periods around the centerline circumference.
                    dash: [9.7 * scale, 5.85 * scale]
                ))
                .rotationEffect(.degrees(spinAngle))
            RoundedTrianglePlay(cornerRadius: 2.5 * scale)
                .fill(Self.triangleGradient)
                .frame(width: diameter * 0.34, height: diameter * 0.38)
                .offset(x: diameter * 0.035)  // optical centering of the triangle
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: isSpinning) { _, spinning in
            if spinning {
                withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
                    spinAngle += 360
                }
            } else {
                // The ants settle back to rest rather than freezing mid-crawl.
                withAnimation(.easeOut(duration: 0.35)) {
                    spinAngle = 0
                }
            }
        }
    }
}

/// A right-pointing play triangle with softly rounded corners (the reference's
/// triangle is not razor-sharp).
struct RoundedTrianglePlay: Shape {
    var cornerRadius: CGFloat = 2.5

    func path(in rect: CGRect) -> Path {
        let top = CGPoint(x: rect.minX, y: rect.minY)
        let tip = CGPoint(x: rect.maxX, y: rect.midY)
        let bottom = CGPoint(x: rect.minX, y: rect.maxY)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        path.addArc(tangent1End: top, tangent2End: tip, radius: cornerRadius)
        path.addArc(tangent1End: tip, tangent2End: bottom, radius: cornerRadius)
        path.addArc(tangent1End: bottom, tangent2End: top, radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}

// MARK: - Hover cursor

private extension View {
    func pointingHandOnHover() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
