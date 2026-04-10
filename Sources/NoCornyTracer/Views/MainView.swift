import SwiftUI
import Sparkle

// MARK: - Theme Toggle Button

private struct ThemeToggleButton: View {
    @Bindable var appState: AppState

    var body: some View {
        Button {
            withAnimation(Theme.Anim.standard) {
                appState.appTheme = appState.appTheme == .light ? .dark : .light
            }
        } label: {
            Image(systemName: appState.appTheme == .light ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .background(Theme.Colors.backgroundSecondary.opacity(0.7))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// Main app window content
struct MainView: View {
    @Bindable var appState: AppState
    let updaterController: SPUStandardUpdaterController
    var permissionsManager: PermissionsManager
    @Environment(\.openWindow) var openWindow
    @Environment(\.colorScheme) var colorScheme
    @State private var showEmailCopied = false

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar at the top with theme toggle
            ZStack {
                tabBar
                HStack {
                    Spacer()
                    ThemeToggleButton(appState: appState)
                        .padding(.trailing, Theme.Spacing.lg)
                }
            }
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.sm)

            // Tab content
            switch appState.selectedTab {
            case .recorder:
                recorderTab
            case .recordings:
                recordingsTab
            case .settings:
                SettingsView(appState: appState, updaterController: updaterController)
            }

            // Footer
            Divider()
            footerView
        }
        .frame(width: 380)
        .background(Theme.Colors.backgroundPrimary)
        .onAppear {
            appState.cameraManager.refreshDevices()
            appState.recordingManager.audioCaptureManager.refreshDevices()
            appState.hotkeyManager.start(appState: appState)
            Task { await appState.syncDropboxState() }
            if !permissionsManager.hasAllRequiredPermissions {
                openWindow(id: "permissions")
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        .alert("Start at Login?", isPresented: $appState.showLaunchAtLoginPrompt) {
            Button("Yes, start at login") {
                appState.launchAtLogin = true
            }
            Button("No thanks", role: .cancel) {
                appState.launchAtLogin = false
            }
        } message: {
            Text("Would you like NoCorny Tracer to start automatically when you log in to your Mac?")
        }
    }

    // MARK: - Tab Bar (Claude-style pill tabs)

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppState.MainTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(Theme.Anim.standard) {
                        appState.selectedTab = tab
                    }
                } label: {
                    Text(tab.rawValue)
                        .font(Theme.Typography.body(12, weight: appState.selectedTab == tab ? .bold : .medium))
                        .foregroundStyle(appState.selectedTab == tab ? Theme.Colors.textPrimary : .secondary)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(
                            appState.selectedTab == tab
                                ? Theme.Colors.tabActiveBackground
                                : Color.clear
                        )
                        .clipShape(Capsule())
                        .contentShape(Capsule())
                        .shadow(
                            color: appState.selectedTab == tab
                                ? (colorScheme == .dark ? .black.opacity(0.3) : .black.opacity(0.08))
                                : .clear,
                            radius: 2, x: 0, y: 1
                        )
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .padding(Theme.Spacing.xs)
        .background(Theme.Colors.backgroundSecondary.opacity(0.7))
        .clipShape(Capsule())
    }

    // MARK: - Recorder Tab

    @ViewBuilder
    private var recorderTab: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                // Timer — always visible, shows 00:00 when idle
                HStack(spacing: Theme.Spacing.sm) {
                    if appState.recordingManager.isRecording {
                        Circle()
                            .fill(Theme.Colors.red)
                            .frame(width: 8, height: 8)
                            .modifier(PulsingModifier(isActive: !appState.recordingManager.isPaused))
                    }
                    Text(appState.recordingManager.isRecording
                         ? appState.recordingManager.formattedDuration
                         : "00:00")
                        .font(Theme.Typography.mono(28, weight: .medium))
                        .foregroundStyle(appState.recordingManager.isRecording ? .primary : .tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.xs)

                RecordingControlsView(appState: appState)
                    .cardStyle()

                shortcutHintsView
                    .cardStyle()

                contactMeCard
                    .cardStyle()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
    }

    // MARK: - Recordings Tab

    @ViewBuilder
    private var recordingsTab: some View {
        RecordingsListView(appState: appState)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
    }

    // MARK: - Keyboard Shortcuts

    @ViewBuilder
    private var shortcutHintsView: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "keyboard")
                    .font(.system(size: 13))
                Text("Shortcuts")
                    .font(Theme.Typography.body(13, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                shortcutRow(keys: "⌥⇧R", action: "Start / Stop")
                shortcutRow(keys: "⌥⇧P", action: "Pause / Resume")
                shortcutRow(keys: "⌥⇧X", action: "Abort Recording")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(keys: String, action: String) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text(keys)
                .font(Theme.Typography.mono(12))
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            Text(action)
                .font(Theme.Typography.body(12, weight: .light))
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerView: some View {
        HStack {
            if appState.dropboxAuthManager.isSignedIn {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "cloud.badge.checkmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Colors.green)
                    Text("Dropbox connected")
                        .font(Theme.Typography.body(11, weight: .light))
                }
            } else if appState.dropboxAuthManager.isConfigured {
                Button {
                    appState.dropboxAuthManager.signIn()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "cloud.slash")
                            .font(.system(size: 11))
                        Text("Connect Dropbox")
                            .font(Theme.Typography.body(11))
                    }
                    .foregroundStyle(Theme.Colors.brandPurple)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            } else {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text("Dropbox not configured")
                        .font(Theme.Typography.body(11, weight: .light))
                }
            }

            Spacer()

            if appState.dropboxAuthManager.isSignedIn && appState.dropboxAllocatedSpace > 0 {
                let remaining = max(0, Double(appState.dropboxAllocatedSpace) - Double(appState.dropboxUsedSpace))
                let approxMinutes = Int(remaining / (19.5 * 1024 * 1024))
                Text("~\(approxMinutes) min left")
                    .font(Theme.Typography.body(11, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    // MARK: - Contact Me

    private var contactMeCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("❤️")
                        .font(.system(size: 14))
                    Text("Made with love")
                        .font(Theme.Typography.body(13, weight: .semibold))
                }

                Text("NoCorny Tracer is free and open-source. If you need a custom app, website, or digital product — I'd love to help.")
                    .font(Theme.Typography.body(12, weight: .light))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }

            HStack(spacing: Theme.Spacing.lg) {
                Link(destination: URL(string: "https://nocorny.agency")!) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "globe")
                            .font(.system(size: 11))
                        Text("nocorny.agency")
                            .font(Theme.Typography.body(12, weight: .medium))
                    }
                    .foregroundStyle(Theme.Colors.brandPurple)
                }
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Link(destination: URL(string: "mailto:maksym@nocorny.agency")!) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: showEmailCopied ? "checkmark" : "envelope")
                            .font(.system(size: 11))
                        Text(showEmailCopied ? "Copied!" : "maksym@nocorny.agency")
                            .font(Theme.Typography.body(12, weight: .medium))
                    }
                    .foregroundStyle(showEmailCopied ? Theme.Colors.green : Theme.Colors.brandPurple)
                    .contentShape(Rectangle())
                }
                .environment(\.openURL, OpenURLAction { _ in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("maksym@nocorny.agency", forType: .string)
                    showEmailCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showEmailCopied = false
                    }
                    return .discarded
                })
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}
