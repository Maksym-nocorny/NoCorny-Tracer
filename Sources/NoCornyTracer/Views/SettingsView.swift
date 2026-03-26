import SwiftUI
import Sparkle

/// Settings panel for app configuration
struct SettingsView: View {
    @Bindable var appState: AppState
    let updaterController: SPUStandardUpdaterController


    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button {
                    appState.showSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: -8) // Keep visual alignment while expanding hit area

                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))

                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Google Account Section
                    googleAccountSection

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
    }

    // MARK: - Google Account

    @ViewBuilder
    private var googleAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Google Account", systemImage: "person.circle")
                .font(.system(size: 13, weight: .semibold))

            if appState.googleAuthManager.isSignedIn {
                HStack(spacing: 10) {
                    // User avatar placeholder
                    Circle()
                        .fill(.blue.gradient)
                        .frame(width: 36, height: 36)
                        .overlay {
                            Text(String(appState.googleAuthManager.userName?.prefix(1) ?? "?"))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.googleAuthManager.userName ?? "User")
                            .font(.system(size: 13, weight: .medium))
                        Text(appState.googleAuthManager.userEmail ?? "")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Sign Out") {
                        appState.googleAuthManager.signOut()
                    }
                    .controlSize(.small)
                }
            } else if !appState.googleAuthManager.isConfigured {
                // Not configured yet
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .font(.system(size: 12))
                        Text("Google Sign-In not configured")
                            .font(.system(size: 12, weight: .medium))
                    }

                    Text("To enable Google Drive upload, set your OAuth Client ID in GoogleAuthManager.swift")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Button {
                    appState.googleAuthManager.signIn()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "globe")
                        Text("Sign in with Google")
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 36)
                    .background(.blue.gradient)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain)

                if let error = appState.googleAuthManager.errorMessage {
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
            .padding(.leading, 4)
        }
    }



    // MARK: - General Settings

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("General", systemImage: "gear")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Start NoCornyTracer on System Startup", isOn: $appState.launchAtLogin)
                .controlSize(.small)
                .font(.system(size: 12))
                .onChange(of: appState.launchAtLogin) {
                    appState.updateLaunchAtLogin()
                }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("About", systemImage: "info.circle")
                .font(.system(size: 13, weight: .semibold))

            Text("NoCornyTracer v1.3.3")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("A screen recording app with Google Drive integration")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

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
            .padding(.top, 4)
        }
    }
}
