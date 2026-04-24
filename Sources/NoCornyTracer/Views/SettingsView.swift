import SwiftUI
import Sparkle
import AVFoundation

/// Settings panel for app configuration
struct SettingsView: View {
    @Bindable var appState: AppState
    let updaterController: SPUStandardUpdaterController
    @Environment(\.openWindow) var openWindow
    @State private var activeDropdownID: String? = nil

    private var isRecording: Bool { appState.recordingManager.isRecording }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                tracerAccountSection
                    .cardStyle()

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
        .scrollIndicators(.hidden)
        .background(Theme.Colors.backgroundPrimary)
        .customDropdownOverlay(activeDropdownID: $activeDropdownID)
        .sheet(isPresented: Binding(
            get: { appState.dropboxAuthManager.showConnectionConfirmation },
            set: { appState.dropboxAuthManager.showConnectionConfirmation = $0 }
        )) {
            DropboxConnectedView(
                userName: appState.dropboxAuthManager.userName ?? "User",
                userEmail: appState.dropboxAuthManager.userEmail ?? ""
            ) {
                appState.dropboxAuthManager.showConnectionConfirmation = false
            }
        }
    }

    // MARK: - Tracer Account

    @ViewBuilder
    private var tracerAccountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Label("NoCorny Tracer Account", systemImage: "person.crop.circle.badge.checkmark")
                    .font(Theme.Typography.body(13, weight: .semibold))

                Spacer()

                if appState.tracerAPIClient.isSignedIn {
                    Button {
                        appState.openTracerSettings()
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                            Text("Edit")
                                .font(Theme.Typography.body(11))
                        }
                        .foregroundStyle(Theme.Colors.brandPurple)
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                    .help("Edit name and avatar on tracer.nocorny.com")
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if appState.tracerAPIClient.isSignedIn {
                    HStack(spacing: Theme.Spacing.lg) {
                        tracerAvatar

                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text(tracerDisplayName)
                                .font(Theme.Typography.body(13, weight: .medium))
                            Text(appState.tracerAPIClient.userEmail ?? "")
                                .font(Theme.Typography.body(11, weight: .light))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Sign Out") {
                            Task {
                                await appState.tracerAPIClient.signOut()
                                await MainActor.run {
                                    appState.dropboxAuthManager.clearProxiedState()
                                }
                            }
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                } else {
                    Text("Sign in to automatically publish recordings to tracer.nocorny.com and get shareable links.")
                        .font(Theme.Typography.body(11, weight: .light))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)

                    Button {
                        appState.tracerAPIClient.errorMessage = nil
                        appState.tracerAPIClient.startBrowserSignIn()
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "safari.fill")
                            Text("Sign in with Browser")
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

                    if let error = appState.tracerAPIClient.errorMessage {
                        Text(error)
                            .font(Theme.Typography.body(11))
                            .foregroundStyle(Theme.Colors.red)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tracerDisplayName: String {
        if let name = appState.tracerAPIClient.userName, !name.isEmpty { return name }
        if let email = appState.tracerAPIClient.userEmail { return email.split(separator: "@").first.map(String.init) ?? email }
        return "User"
    }

    private var tracerInitial: String {
        if let name = appState.tracerAPIClient.userName, let first = name.first {
            return String(first).uppercased()
        }
        if let email = appState.tracerAPIClient.userEmail, let first = email.first {
            return String(first).uppercased()
        }
        return "?"
    }

    @ViewBuilder
    private var tracerAvatar: some View {
        let urlString = appState.tracerAPIClient.userImageURL
        ZStack {
            if let image = AvatarCache.shared.image, urlString != nil {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Theme.Colors.primaryGradient)
                    .overlay {
                        Text(tracerInitial)
                            .font(Theme.Typography.body(16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .task(id: urlString) {
            AvatarCache.shared.ensure(urlString: urlString)
        }
    }

    // MARK: - Dropbox Account

    @ViewBuilder
    private var dropboxAccountSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label("Storage — Dropbox", systemImage: "externaldrive")
                .font(Theme.Typography.body(13, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if !appState.tracerAPIClient.isSignedIn {
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Sign in to NoCorny Tracer first")
                                .font(Theme.Typography.body(12, weight: .medium))
                            Text(appState.dropboxAuthManager.isSignedIn
                                 ? "Your existing Dropbox connection is paused until you sign in. Recordings need a Tracer account to get a share link."
                                 : "Dropbox is where recordings are stored so Tracer can publish a share link.")
                                .font(Theme.Typography.body(11, weight: .light))
                                .fixedSize(horizontal: false, vertical: true)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if appState.dropboxAuthManager.isSignedIn {
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
                        .buttonStyle(SettingsButtonStyle())
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
            HStack {
                Label("Recording", systemImage: "video")
                    .font(Theme.Typography.body(13, weight: .semibold))
                Spacer()
                if isRecording {
                    Text("Locked during recording")
                        .font(Theme.Typography.body(10, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack {
                        Text("Resolution")
                            .font(Theme.Typography.body(12))
                        Spacer()
                        CustomDropdownButton(
                            id: "resolution",
                            options: VideoResolution.allCases.map {
                                DropdownOption(id: $0.rawValue, label: $0.displayName, value: $0)
                            },
                            selection: $appState.videoResolution,
                            activeDropdownID: $activeDropdownID
                        )
                    }

                    HStack {
                        Text("Frame Rate")
                            .font(Theme.Typography.body(12))
                        Spacer()
                        CustomDropdownButton(
                            id: "framerate",
                            options: VideoFrameRate.allCases.map {
                                DropdownOption(id: String($0.rawValue), label: $0.displayName, value: $0)
                            },
                            selection: $appState.videoFrameRate,
                            activeDropdownID: $activeDropdownID
                        )
                    }
                }
                .disabled(isRecording)

                HStack {
                    Text("Format")
                        .font(Theme.Typography.body(12))
                    Spacer()
                    Text("H.264 / MP4")
                        .font(Theme.Typography.mono(12, weight: .light))
                }

            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Input Devices

    @ViewBuilder
    private var inputDevicesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack {
                Label("Input Devices", systemImage: "mic.and.signal.meter")
                    .font(Theme.Typography.body(13, weight: .semibold))
                Spacer()
                if isRecording {
                    Text("Locked during recording")
                        .font(Theme.Typography.body(10, weight: .light))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Microphone")
                        .font(Theme.Typography.body(12))
                    Spacer()
                    CustomDropdownButton(
                        id: "microphone",
                        options: [DropdownOption(id: "", label: "Default Input", value: "")] +
                            appState.recordingManager.audioCaptureManager.availableDevices.map {
                                DropdownOption(id: $0.uniqueID, label: $0.localizedName, value: $0.uniqueID)
                            },
                        selection: Binding(
                            get: { appState.selectedMicrophoneID ?? "" },
                            set: { appState.selectedMicrophoneID = $0.isEmpty ? nil : $0 }
                        ),
                        activeDropdownID: $activeDropdownID,
                        minWidth: 160
                    )
                }

                HStack {
                    Text("Camera")
                        .font(Theme.Typography.body(12))
                    Spacer()
                    CustomDropdownButton(
                        id: "camera",
                        options: [DropdownOption(id: "", label: "Default Camera", value: "")] +
                            appState.cameraManager.availableDevices.map {
                                DropdownOption(id: $0.uniqueID, label: $0.localizedName, value: $0.uniqueID)
                            },
                        selection: Binding(
                            get: { appState.selectedCameraDeviceID ?? "" },
                            set: { appState.selectedCameraDeviceID = $0.isEmpty ? nil : $0 }
                        ),
                        activeDropdownID: $activeDropdownID,
                        minWidth: 160
                    )
                }
            }
            .disabled(isRecording)
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
                .buttonStyle(SettingsButtonStyle())
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }

                Button("Show Logs") {
                    NSWorkspace.shared.selectFile(LogManager.shared.getLogFileURL().path, inFileViewerRootedAtPath: "")
                }
                .buttonStyle(SettingsButtonStyle())
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
