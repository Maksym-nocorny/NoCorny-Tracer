import SwiftUI
import Sparkle
import AVFoundation

/// Settings panel for app configuration
struct SettingsView: View {
    @Bindable var appState: AppState
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                dropboxAccountSection
                    .cardStyle()

                recordingSettingsSection
                    .cardStyle()

                inputDevicesSection
                    .cardStyle()

                generalSection
                    .cardStyle()

                aboutSection
                    .cardStyle()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
    }

    // MARK: - Dropbox Account

    @ViewBuilder
    private var dropboxAccountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label("Dropbox", systemImage: "person.circle")
                .font(Theme.Typography.body(13, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if appState.dropboxAuthManager.isSignedIn {
                    HStack(spacing: Theme.Spacing.lg) {
                        Circle()
                            .fill(Theme.Colors.primaryGradient)
                            .frame(width: 36, height: 36)
                            .overlay {
                                Text(String(appState.dropboxAuthManager.userName?.prefix(1) ?? "?"))
                                    .font(Theme.Typography.body(16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }

                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(appState.dropboxAuthManager.userName ?? "User")
                                .font(Theme.Typography.body(13, weight: .medium))
                            Text(appState.dropboxAuthManager.userEmail ?? "")
                                .font(Theme.Typography.body(11, weight: .light))
                        }

                        Spacer()

                        Button("Sign Out") {
                            appState.dropboxAuthManager.signOut()
                        }
                        .controlSize(.small)
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                } else if !appState.dropboxAuthManager.isConfigured {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Theme.Colors.yellow)
                                .font(.system(size: 12))
                            Text("Dropbox not configured")
                                .font(Theme.Typography.body(12, weight: .medium))
                        }

                        Text("To enable Dropbox upload, set your App Key in Secrets.swift")
                            .font(Theme.Typography.body(11, weight: .light))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button {
                        appState.dropboxAuthManager.signIn()
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "arrow.down.doc")
                            Text("Connect Dropbox")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(Theme.Colors.primaryGradient)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        .font(Theme.Typography.body(13, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    if let error = appState.dropboxAuthManager.errorMessage {
                        Text(error)
                            .font(Theme.Typography.body(11))
                            .foregroundStyle(Theme.Colors.red)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Recording Settings

    @ViewBuilder
    private var recordingSettingsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label("Recording", systemImage: "video")
                .font(Theme.Typography.body(13, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Resolution")
                        .font(Theme.Typography.body(12))
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
                        .font(Theme.Typography.body(12))
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
                        .font(Theme.Typography.body(12))
                    Spacer()
                    Text("H.264 / MP4")
                        .font(Theme.Typography.mono(12, weight: .light))
                }

                HStack {
                    Text("Save Location")
                        .font(Theme.Typography.body(12))
                    Spacer()
                    Button("Open") {
                        NSWorkspace.shared.open(AppState.recordingsDirectory)
                    }
                    .controlSize(.small)
                    .font(Theme.Typography.body(11))
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Input Devices

    @ViewBuilder
    private var inputDevicesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label("Input Devices", systemImage: "mic.and.signal.meter")
                .font(Theme.Typography.body(13, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Microphone")
                        .font(Theme.Typography.body(12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appState.selectedMicrophoneID ?? "" },
                        set: { appState.selectedMicrophoneID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Default Input")
                            .tag("")
                        ForEach(appState.recordingManager.audioCaptureManager.availableDevices, id: \.uniqueID) { device in
                            Text(device.localizedName)
                                .tag(device.uniqueID)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(minWidth: 160)
                }

                HStack {
                    Text("Camera")
                        .font(Theme.Typography.body(12))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { appState.selectedCameraDeviceID ?? "" },
                        set: { appState.selectedCameraDeviceID = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Default Camera")
                            .tag("")
                        ForEach(appState.cameraManager.availableDevices, id: \.uniqueID) { device in
                            Text(device.localizedName)
                                .tag(device.uniqueID)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(minWidth: 160)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - General Settings

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label("General", systemImage: "gear")
                .font(Theme.Typography.body(13, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                    .controlSize(.small)
                    .font(Theme.Typography.body(12))
                    .onChange(of: appState.launchAtLogin) {
                        appState.updateLaunchAtLogin()
                    }

                Button("Permissions...") {
                    openWindow(id: "permissions")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .controlSize(.small)
                .font(Theme.Typography.body(12))
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button("Show Logs") {
                    NSWorkspace.shared.selectFile(LogManager.shared.getLogFileURL().path, inFileViewerRootedAtPath: "")
                }
                .controlSize(.small)
                .font(Theme.Typography.body(12, weight: .light))
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("About", systemImage: "info.circle")
                .font(Theme.Typography.body(13, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
                Text("NoCorny Tracer v\(appVersion)")
                    .font(Theme.Typography.body(12, weight: .light))

                Text("A screen recording app with Dropbox integration.")
                    .font(Theme.Typography.body(11, weight: .light))

                Text("This application uses the Dropbox API but is not endorsed or certified by Dropbox, Inc.")
                    .font(Theme.Typography.body(10, weight: .light))
                    .italic()
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.lg) {
                    Link("Privacy Policy", destination: URL(string: "https://maksym-nocorny.github.io/NoCorny-Tracer/privacy-policy")!)
                        .font(Theme.Typography.body(11))
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }

                    Link("Terms of Service", destination: URL(string: "https://maksym-nocorny.github.io/NoCorny-Tracer/terms-of-service")!)
                        .font(Theme.Typography.body(11))
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                }
                .foregroundStyle(Theme.Colors.brandPurple)

                Button {
                    updaterController.checkForUpdates(nil)
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text("Check for Updates")
                            .font(Theme.Typography.body(12))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.brandPurple)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
