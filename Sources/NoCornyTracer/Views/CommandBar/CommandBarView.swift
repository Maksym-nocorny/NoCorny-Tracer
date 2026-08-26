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
        //
        // ROUND 5 («хай плашка буде спокійною», бойова 4.0.0): drawer morphs carry
        // NO ambient animation at all. There are no `.animation(value:)` modifiers
        // here any more — every remaining transition brings its OWN animation, so
        // a surface change leaves the transaction empty and the bar row cannot
        // animate a single property during open/close (which also makes an
        // explicit `.transaction { $0.animation = nil }` on the bar unnecessary —
        // there is nothing left to silence, and a blanket kill would eat the
        // bar's own hover/spin animations).
        //
        // ROUND 5b/5c (verdicts 26.08: «анімація рвана», «рідні анімації …
        // мають більше fps»): a drawer CLOSE is not a removal. The closing
        // drawer stays in the tree and in layout (`closingDrawerTab`) inside
        // the held panel frame while its opacity animates to 0, and only the
        // deferred frame snap (`drawerCloseSnapDelay`) removes it — burst-
        // proven to change no visible pixel. Every other variant failed on
        // pixels: an instant snap clipped the ~150ms Liquid Glass
        // dematerialize across the bar's face (r5a), a bare state change
        // yanked the subtree in ONE frame (removal transitions do not animate
        // from their attached animation), and a fade carried by the
        // transaction slid the dying drawer down the bar with the layout
        // reflow.
        Group {
            if manager.surface == .recordingPill {
                RecordingPillView(appState: appState, manager: manager)
                    .transition(
                        .scale(scale: 0.92, anchor: .topLeading)
                        .combined(with: .opacity)
                        .animation(Theme.Anim.surface)
                    )
            } else {
                // The drawer sits UNDER the bar by default; it unfolds ABOVE the
                // bar only when there is no room below (verdict 26.08) — same
                // components, mirrored stack. `.leading` (round 7): the update
                // chip widens the BAR ROW past the 560pt drawer, and the drawer
                // must stay pinned to the bar's left edge (the anchor edge), not
                // re-center under the wider row.
                VStack(alignment: .leading, spacing: 0) {
                    if manager.drawerOpensUp, let tab = shownDrawerTab {
                        closableDrawer(tab)
                            .padding(.bottom, MorphGeometry.drawerGap)
                    }
                    CommandBarView(appState: appState, manager: manager)
                    if !manager.drawerOpensUp, let tab = shownDrawerTab {
                        closableDrawer(tab)
                            .padding(.top, MorphGeometry.drawerGap)
                    }
                    // Banner on the plain bar ONLY (decision, phase 4): the pill stays
                    // minimal mid-take; the drawer already shows the quota in its
                    // Dropbox row. Same round-5 policy as the drawer: frame snap,
                    // own fade, no slide. The `!drawerOpensUp` and closing-tab
                    // gates keep it out of the close-fade window (rounds 5b/5c):
                    // the dying drawer still occupies its layout slot, and a
                    // banner joining the stack would displace the bar for the
                    // length of the fade — it waits for the snap instead.
                    if manager.surface == .bar, !manager.drawerOpensUp,
                       manager.closingDrawerTab == nil, storageLevel != .ok {
                        StorageBannerView(appState: appState, level: storageLevel)
                            .padding(.top, MorphGeometry.bannerGap)
                            .transition(.asymmetric(
                                insertion: .opacity.animation(Theme.Anim.drawerFade),
                                removal: .identity
                            ))
                    }
                }
                .transition(
                    .scale(scale: 0.98, anchor: .topLeading)
                    .combined(with: .opacity)
                    .animation(Theme.Anim.surface)
                )
            }
        }
        // ROUND 5c (verdict 26.08, «рідні анімації … мають більше fps»): during
        // a pill flight the panel wears the UNION of both endpoint frames and
        // the CONTENT flies across it on this offset — a per-frame layer
        // transform at the display's native rate, instead of the old per-tick
        // window-frame animation with its full re-layout and 60fps timer cap.
        // Zero between flights, so it is inert on every other surface.
        .offset(manager.flightOffset)
        // The panel is `panelShadowInset` larger than the glass on every side so the
        // SwiftUI shadow has room to draw (the panel's own shadow is off).
        .padding(MorphGeometry.panelShadowInset)
        // Pin to whichever edge of the panel stays put on screen: the TOP edge
        // for downward growth, the BOTTOM edge while an upward drawer is
        // open/closing — that is what keeps the bar visually stationary while
        // the panel frame changes around it. A flight (round 5c) forces the
        // TOP-LEADING pin — the coordinate base of `flightOffset` — even when a
        // lingering `drawerOpensUp` would pin bottom.
        .frame(
            maxWidth: .infinity, maxHeight: .infinity,
            alignment: (manager.drawerOpensUp && !manager.flightActive)
                ? .bottomLeading : .topLeading
        )
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

    /// The drawer the stack should currently RENDER: the open one, or the one
    /// mid-close (round 5c) — a closing drawer keeps its place in the layout,
    /// fading via `closableDrawer`, until the manager's deferred snap drops it.
    private var shownDrawerTab: CommandBarDrawerTab? {
        if case .barWithDrawer(let tab) = manager.surface { return tab }
        return manager.closingDrawerTab
    }

    /// One drawer slot of the stack. INSERTION fades in via the transition (its
    /// attached animation drives insertions fine). The CLOSE is not a removal
    /// at all (round 5c): the view stays in the tree and in layout — so it can
    /// not slide with the reflow and the bar cannot move — while its opacity
    /// animates to 0 in the `drawerFade` transaction the manager's morph opens;
    /// the eventual removal happens at the frame snap, fully invisible.
    @ViewBuilder
    private func closableDrawer(_ tab: CommandBarDrawerTab) -> some View {
        drawerContent(tab)
            .opacity(manager.closingDrawerTab == nil ? 1 : 0)
            .transition(.opacity.animation(Theme.Anim.drawerFade))
    }

    /// The open drawer. Each tab carries its own fade so flipping
    /// gallery↔settings crossfades (the panel frame doesn't change between tabs),
    /// while the containing `if` above owns the open appearance. The
    /// animation rides ON the transition (round 5): the ambient transaction is
    /// deliberately empty during surface changes.
    @ViewBuilder
    private func drawerContent(_ tab: CommandBarDrawerTab) -> some View {
        switch tab {
        case .gallery:
            DrawerGalleryView(appState: appState)
                .transition(.opacity.animation(Theme.Anim.drawerFade))
        case .settings:
            DrawerSettingsView(appState: appState, manager: manager)
                .transition(.opacity.animation(Theme.Anim.drawerFade))
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
    /// The update chip's hover-unroll state (round 7, hybrid A→B): owned here
    /// because the ROW pays for it — +`updateChipHoverExtra` of width.
    @State private var chipExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            // The update chip (round 7): between settings and the spacer, so
            // its hover-unroll eats the spacer's slack first and only the
            // remainder widens the row — see barRowWidth.
            if let version = pendingUpdateVersion {
                UpdateChipView(version: version, isExpanded: $chipExpanded)
                    .transition(chipTransition)
            }
            Spacer(minLength: 0)
            closeButton
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(
            width: barRowWidth,
            height: Theme.Metrics.commandBarSize.height
        )
        .glassSurface(cornerRadius: Theme.Metrics.barCornerRadius)
        .floatingPanelShadow()
        // Scoped to chip events ONLY (the round-5 "no ambient animation on the
        // bar" policy holds: barRowWidth changes exactly when the chip appears,
        // unrolls or leaves). The same spring the chip itself springs on — the
        // spacer compresses and the close cross glides with it as one motion.
        .animation(reduceMotion ? nil : Theme.Anim.updateChip, value: barRowWidth)
        // The panel must grow/shrink around the springing row: grow snaps the
        // frame first (the new strip is transparent), shrink defers the snap
        // past the spring — the drawer-close recipe, in the manager.
        .onChange(of: barRowWidth, initial: true) { _, width in
            manager.setUpdateChipExtraWidth(width - Theme.Metrics.commandBarSize.width)
        }
    }

    // MARK: Update chip (round 7)

    /// nil = no chip in the bar. Reading the coordinator's observable
    /// `pendingUpdateVersion`/`previewVersion` re-renders the row when an
    /// update stages or the Settings preview toggle flips (round 8) — the pure
    /// `resolve` puts the real update above the preview. Mid-take the bar
    /// shows no chip (the tray/drawer keep theirs) — `showsInBar` decides.
    private var pendingUpdateVersion: String? {
        guard let coordinator = UpdateCoordinator.shared else { return nil }
        let resolved = UpdateCoordinator.resolve(
            preview: coordinator.previewVersion,
            realPending: coordinator.pendingUpdateVersion
        )
        guard let version = resolved.version,
              UpdateChipState.showsInBar(pendingVersion: version, isRecording: isRecording)
        else { return nil }
        return version
    }

    /// 560 base; +51 while the chip is present (its 38 + the 13 gap); +20 more
    /// while it is hover-expanded — the rest of the 38→87 unroll comes out of
    /// the flexible spacer (~29pt), so no control left of the chip ever moves.
    private var barRowWidth: CGFloat {
        guard pendingUpdateVersion != nil else { return Theme.Metrics.commandBarSize.width }
        var width = Theme.Metrics.commandBarSize.width + MorphGeometry.updateChipExtent
        if chipExpanded { width += MorphGeometry.updateChipHoverExtra }
        return width
    }

    /// Appearance per the handoff: spring scale 0.6→1 (`updateChip`) with a
    /// 0.12s fade — the neighbours spring apart on the same curve via the
    /// row-width animation above. Reduce Motion: a plain fade.
    private var chipTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .scale(scale: 0.6)
            .animation(Theme.Anim.updateChip)
            .combined(with: .opacity.animation(.easeOut(duration: 0.12)))
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
        .pointerOnHover()
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
    /// remembers something — "Window" answers "which window?" without opening the menu.
    private var captureModeHelp: String {
        if appState.captureMode == .window,
           let title = appState.captureSelection.windowTitle, !title.isEmpty {
            return "\(appState.captureMode.displayName) - \(title)"
        }
        return appState.captureMode.displayName
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
        // Round 3, «застосунок трясе коли відкривається меню»: the hover scale is
        // FROZEN at 1 while the popover is up. The button is the popover's anchor,
        // and NSPopover repositions itself (animated) every time its positioning
        // view's frame changes — so the 1.03↔1.0 hover animation that fires the
        // moment the cursor leaves the button for the menu made the freshly opened
        // popover chase a moving anchor. Harness-verified that the popover itself
        // never moves the panel (frame logging + pixel diffs, scratchpad round 3);
        // the moving part was the anchor. The un-scale on open is deliberately NOT
        // animated: the popover must get its final anchor rect immediately.
        .scaleEffect(captureHovering && !showCaptureMenu ? 1.03 : 1)
        .animation(Theme.Anim.hover, value: captureHovering)
        .onHover { captureHovering = $0 }
        .help(captureModeHelp)
        .pointerOnHover()
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
            // Through the permission gate (verdict 25.08): undetermined prompts,
            // denied stays off and explains itself in a toast.
            appState.requestMicrophoneEnabled(!appState.isMicrophoneEnabled)
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
            // Through the permission gate (verdict 25.08, «камера не вмикалась»):
            // undetermined shows the system prompt, denied keeps the toggle off and
            // points at System Settings. The bubble itself rises via the existing
            // isCameraEnabled didSet once the grant is real.
            appState.requestCameraEnabled(!appState.isCameraEnabled)
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
        CommandGlassButton(
            systemName: "xmark",
            help: "Close (Tracer keeps running in the menu bar)"
        ) {
            // Hide, don't quit (verdict 25.08 — overrides the macro map's
            // "close = quit"): the app lives on in the tray/Dock, a click there
            // brings the bar back. Quit stays in the tray menu (⌘Q).
            manager.hide()
        }
    }
}

// MARK: - Capture mode menu

/// The capture-target picker, per macro frame 72:137 (224 wide).
///
/// The click contract for modes that point at something (decision, phase 6a): the
/// Window row ALWAYS opens the system window picker — picking saves the choice and
/// starts recording immediately. The remembered window is what the record BUTTON
/// reuses without a picker. One row, one behaviour — no separate "Choose…" items,
/// no guessing whether a click switches the mode or re-picks.
///
/// Only `CaptureMode.menuCases` are listed (round 6): a retired mode — Selected
/// Area — is hidden outright, not greyed out.
private struct CaptureModeMenu: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CaptureMode.menuCases, id: \.self) { mode in
                Button {
                    dismiss()
                    switch mode {
                    case .window:
                        appState.chooseWindowForCapture()
                    case .entireScreen:
                        appState.captureMode = .entireScreen
                    case .selectedArea:
                        break   // retired (round 6) — never in menuCases
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
                    // 6pt and one notch deeper than the macro green, no glow
                    // (verdict 25.08: the 8pt raw #32D74B dots read as acid on
                    // the bar) — see Theme.Colors.statusGreenDot.
                    Circle()
                        .fill(Theme.Colors.statusGreenDot)
                        .frame(width: 6, height: 6)
                        .offset(x: 1, y: -1)
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
        .pointerOnHover()
    }
}

// The record mark (RecordRingMark / RoundedTrianglePlay) moved to RecordMark.swift
// in round 3 — the Gallery empty state and the thumbnail play badge share it now.
