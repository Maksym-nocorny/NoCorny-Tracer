import SwiftUI
import Sparkle

/// Main popover content displayed from the menu bar icon
struct MenuBarView: View {
    @Bindable var appState: AppState
    let updaterController: SPUStandardUpdaterController

    var body: some View {
        VStack(spacing: 0) {
            if appState.showSettings {
                SettingsView(appState: appState, updaterController: updaterController)
            } else {
                mainContent
            }
        }
        .frame(width: 340)
        .frame(minHeight: 500)
        .onAppear {
            appState.cameraManager.refreshDevices()
            appState.recordingManager.audioCaptureManager.refreshDevices()
            appState.hotkeyManager.start(appState: appState)
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

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Recording Controls
            RecordingControlsView(appState: appState)
                .padding(.vertical, 12)

            Divider()

            // Keyboard Shortcuts Hints
            shortcutHintsView

            Divider()

            // Recordings List
            RecordingsListView(appState: appState)
                .padding(.vertical, 10)

            Divider()

            // Footer
            footerView
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerView: some View {
        HStack {
            // App branding
            HStack(spacing: 6) {
                if let resourceURL = Bundle.appResources.url(forResource: "in_app_icon", withExtension: "png", subdirectory: "Resources") ??
                                     Bundle.appResources.url(forResource: "in_app_icon", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: resourceURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 27, height: 27)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(.red.gradient)
                }

                Text("NoCorny Tracer")
                    .font(.system(size: 19, weight: .bold))
            }

            Spacer()

            // Settings gear
            Button {
                appState.showSettings.toggle()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Keyboard Shortcuts

    @ViewBuilder
    private var shortcutHintsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("Shortcuts")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                shortcutRow(keys: "⌥⇧R", action: "Start / Stop")
                shortcutRow(keys: "⌥⇧P", action: "Pause / Resume")
                shortcutRow(keys: "⌥⇧X", action: "Abort Recording")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func shortcutRow(keys: String, action: String) -> some View {
        HStack(spacing: 10) {
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Text(action)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footerView: some View {
        HStack {
            if appState.dropboxAuthManager.isSignedIn {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.icloud.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                    Text("Dropbox connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else if appState.dropboxAuthManager.isConfigured {
                Button {
                    appState.dropboxAuthManager.signIn()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.slash")
                            .font(.system(size: 11))
                        Text("Connect Dropbox")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 11))
                    Text("Dropbox not configured")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}
