import SwiftUI
import Sparkle

/// Settings panel for app configuration
struct SettingsView: View {
    @Bindable var appState: AppState
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow


    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    appState.showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 27, height: 27)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: -8) // Keep visual alignment while expanding hit area

                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            VStack(alignment: .leading, spacing: 20) {
                // Dropbox Account Section
                dropboxAccountSection

                Divider()
                
                // Recording Settings
                recordingSettingsSection

                Divider()

                // General Settings
                generalSection

                Divider()

                // About
                aboutSection
            }
            .padding()
        }
    }

    // MARK: - Dropbox Account

    @ViewBuilder
    private var dropboxAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Dropbox", systemImage: "person.circle")
                .font(.system(size: 13, weight: .semibold))

            if appState.dropboxAuthManager.isSignedIn {
                HStack(spacing: 10) {
                    // User avatar placeholder
                    Circle()
                        .fill(.blue.gradient)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Text(String(appState.dropboxAuthManager.userName?.prefix(1) ?? "?"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.dropboxAuthManager.userName ?? "User")
                            .font(.system(size: 13, weight: .medium))
                        Text(appState.dropboxAuthManager.userEmail ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Sign Out") {
                        appState.dropboxAuthManager.signOut()
                    }
                    .controlSize(.small)
                }
            } else if !appState.dropboxAuthManager.isConfigured {
                // Not configured yet
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.system(size: 12))
                        Text("Dropbox not configured")
                            .font(.system(size: 12, weight: .medium))
                    }

                    Text("To enable Dropbox upload, set your App Key in Secrets.swift")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    appState.dropboxAuthManager.signIn()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc")
                        Text("Connect Dropbox")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(.blue.gradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)

                if let error = appState.dropboxAuthManager.errorMessage {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
        }
    }



    @ViewBuilder
    private var recordingSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recording", systemImage: "video")
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Resolution")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $appState.videoResolution) {
                        ForEach(VideoResolution.allCases) { res in
                            Text(res.displayName).tag(res)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }

                HStack {
                    Text("Frame Rate")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $appState.videoFrameRate) {
                        ForEach(VideoFrameRate.allCases) { rate in
                            Text(rate.displayName).tag(rate)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                }

                HStack {
                    Text("Format")
                        .font(.system(size: 12))
                    Spacer()
                    Text("H.264 / MP4")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Save Location")
                        .font(.system(size: 12))
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(AppState.recordingsDirectory)
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
            }
            .padding(.leading, 24)
        }
    }



    // MARK: - General Settings

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("General", systemImage: "gear")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                .controlSize(.small)
                .font(.system(size: 12))
                .onChange(of: appState.launchAtLogin) {
                    appState.updateLaunchAtLogin()
                }
                
            Button("Permissions...") {
                openWindow(id: "permissions")
                NSApp.activate(ignoringOtherApps: true)
            }
            .controlSize(.small)
            .font(.system(size: 12))
            .padding(.top, 4)
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("About", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold))

            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
            Text("NoCorny Tracer v\(appVersion)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("A screen recording app with Dropbox integration.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                
                Text("This application uses the Dropbox API but is not endorsed or certified by Dropbox, Inc.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .italic()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            HStack(spacing: 12) {
                Link("Privacy Policy", destination: URL(string: "https://maksym-nocorny.github.io/NoCorny-Tracer/privacy-policy")!)
                    .font(.system(size: 11))
                
                Link("Terms of Service", destination: URL(string: "https://maksym-nocorny.github.io/NoCorny-Tracer/terms-of-service")!)
                    .font(.system(size: 11))
            }
            .foregroundStyle(.blue)

            Button {
                updaterController.checkForUpdates(nil)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                    Text("Check for Updates")
                        .font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .padding(.top, 6)
        }
    }
}
