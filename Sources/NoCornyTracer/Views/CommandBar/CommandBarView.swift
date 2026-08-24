import SwiftUI
import AppKit

// MARK: - Root

/// Content of the floating command-bar panel. Switches between the redesign's
/// surfaces; the drawers and the recording pill are placeholders until phases 3–4.
struct CommandBarRootView: View {
    @Bindable var appState: AppState
    let manager: CommandBarWindowManager

    var body: some View {
        Group {
            switch manager.surface {
            case .bar:
                CommandBarView(appState: appState, manager: manager)
            case .barWithDrawer(let tab):
                VStack(spacing: MorphGeometry.drawerGap) {
                    CommandBarView(appState: appState, manager: manager)
                    CommandBarDrawerStub(tab: tab)
                }
            case .recordingPill:
                RecordingPillStub()
            }
        }
        // The panel is `panelShadowInset` larger than the glass on every side so the
        // SwiftUI shadow has room to draw (the panel's own shadow is off).
        .padding(MorphGeometry.panelShadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Keep the panel's NSAppearance pinned to the in-app theme toggle.
        .onChange(of: appState.appTheme, initial: true) {
            manager.applyPanelAppearance()
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
            RecordMarkView()
                .frame(width: 52, height: 52)
        }
        .buttonStyle(.plain)
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

    private var captureModeButton: some View {
        Button {
            showCaptureMenu.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "display")
                    .font(.system(size: 15, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.textPrimary)
            .padding(.horizontal, 13)
            .frame(height: Theme.Metrics.controlSize)
            .background(Theme.Colors.glassControlFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.glassStroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Metrics.controlCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("What to record")
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

/// The capture-target picker, per macro frame 72:137 (224 wide). Window and
/// selected-area capture ship in phase 6, so those rows are disabled — more honest
/// than a selection that silently records the whole screen anyway.
private struct CaptureModeMenu: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                Button {
                    appState.captureMode = mode
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: mode.symbolName)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(mode.displayName)
                            .font(Theme.Typography.body(13))
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
                .disabled(!mode.isAvailable)
                .opacity(mode.isAvailable ? 1 : 0.4)
                .help(mode.isAvailable ? "" : "Coming in this update")
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

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.Colors.glassControlFill)
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

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.Colors.glassControlFillSubtle)
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
        .help(help)
        .pointingHandOnHover()
    }
}

// MARK: - Record mark

/// The icon-v2 record mark (dashed frame + blue play triangle, without the red status
/// dot), rendered from design/icon-v2/svg/mark(.dark).svg into @1x/@2x/@3x PNGs at 52pt
/// — same multi-representation recipe as the menu-bar icons in AppDelegate.
private struct RecordMarkView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let mark = CommandBarMarkImage.image(dark: colorScheme == .dark) {
            Image(nsImage: mark)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            // PNGs missing from the bundle — fall back to a recognizable glyph.
            Image(systemName: "play.circle")
                .font(.system(size: 34))
                .foregroundStyle(Theme.Colors.brandPurple)
        }
    }
}

@MainActor
enum CommandBarMarkImage {
    private static var cache: [Bool: NSImage] = [:]

    static func image(dark: Bool) -> NSImage? {
        if let cached = cache[dark] { return cached }

        let baseName = dark ? "commandbar_mark_dark" : "commandbar_mark"
        let bundle = Bundle.appResources
        let pointSize = NSSize(width: 52, height: 52)
        let image = NSImage(size: pointSize)

        for suffix in ["", "@2x", "@3x"] {
            let name = baseName + suffix
            guard let url = bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources")
                    ?? bundle.url(forResource: name, withExtension: "png"),
                  let data = try? Data(contentsOf: url),
                  let rep = NSBitmapImageRep(data: data) else { continue }
            rep.size = pointSize  // 52pt regardless of pixel density
            image.addRepresentation(rep)
        }

        guard !image.representations.isEmpty else { return nil }
        cache[dark] = image
        return image
    }
}

// MARK: - Phase stubs

/// Placeholder drawer (real gallery/settings content is phase 3): an empty glass
/// sheet at the drawer's exact final size, so the morph geometry is honest.
private struct CommandBarDrawerStub: View {
    let tab: CommandBarDrawerTab

    var body: some View {
        Text(tab == .gallery ? "Gallery" : "Settings")
            .font(Theme.Typography.heading(20))
            .foregroundStyle(Theme.Colors.timerDimmed)
            .frame(
                width: Theme.Metrics.drawerSize.width,
                height: Theme.Metrics.drawerSize.height
            )
            .glassSurface(cornerRadius: Theme.Radius.xl)
            .floatingPanelShadow()
    }
}

/// Placeholder recording pill (phase 4). Nothing morphs to it yet.
private struct RecordingPillStub: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Circle()
                .fill(Theme.Colors.recordRed)
                .frame(width: 10, height: 10)
            Text("00:00")
                .font(Theme.Typography.timer(20))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .frame(
            width: Theme.Metrics.recordingPillSize.width,
            height: Theme.Metrics.recordingPillSize.height
        )
        .glassSurface(cornerRadius: Theme.Metrics.recordingPillSize.height / 2)
        .floatingPanelShadow()
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
