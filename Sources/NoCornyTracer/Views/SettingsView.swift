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

                transcriptionSection
                    .cardStyle()

                generalSection
                    .cardStyle()

                aboutSection
                    .cardStyle()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        // .never, not .hidden: .hidden is only a request the system overrides when
        // scroll bars are persistent (a mouse connected, or "Show scroll bars: Always"),
        // which puts a legacy scroller back on screen. .never actually removes it.
        .scrollIndicators(.never)
        .background(Theme.Colors.backgroundPrimary)
        .customDropdownOverlay(activeDropdownID: $activeDropdownID)
        .alert(item: $pendingReport) { reportConfirmation($0) }
        .alert(
            "Problem report",
            isPresented: Binding(
                get: { reportOutcome != nil },
                set: { if !$0 { reportOutcome = nil } }
            ),
            actions: { Button("OK", role: .cancel) { reportOutcome = nil } },
            message: { Text(reportOutcome ?? "") }
        )
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
                                    appState.resetTracerLibraryState()
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
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Manage") {
                            appState.openTracerSettings()
                        }
                        .buttonStyle(SettingsButtonStyle())
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text("Dropbox is managed in your Tracer account on the web.")
                            .font(Theme.Typography.body(11, weight: .light))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            appState.openTracerSettings()
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Image(systemName: "arrow.up.forward.app")
                                Text("Connect Dropbox on Web")
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
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Problem Reports

    @State private var pendingReport: BugReportClient.Payload?
    @State private var isSendingReport = false
    @State private var reportOutcome: String?

    /// Confirmation before sending, listing what actually goes. The report contains the
    /// app's own diagnostic log, and telling someone that only after the fact is not
    /// consent -- so the numbers here are real ones read off the payload.
    private func reportConfirmation(_ payload: BugReportClient.Payload) -> Alert {
        Alert(
            title: Text("Send a problem report?"),
            message: Text("""
            This sends recent diagnostic log entries (about \(payload.logSizeKB) KB), \
            your app version (\(payload.appVersion)), macOS version and Mac model.

            No video, audio or transcript text is included, and links to your recordings \
            are removed.
            """),
            primaryButton: .default(Text("Send")) { send(payload) },
            secondaryButton: .cancel()
        )
    }

    private func send(_ payload: BugReportClient.Payload) {
        isSendingReport = true
        reportOutcome = nil
        Task {
            do {
                try await BugReportClient.send(payload, token: appState.tracerAPIClient.apiToken)
                reportOutcome = "Report sent. Thank you."
            } catch {
                reportOutcome = error.localizedDescription
            }
            isSendingReport = false
        }
    }

    // MARK: - Transcription

    @State private var modelDownloadError: String?

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Label("Transcription", systemImage: "waveform")
                .font(Theme.Typography.body(13, weight: .semibold))

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Engine")
                        .font(Theme.Typography.body(12))
                    Spacer()
                    CustomDropdownButton(
                        id: "transcriptionEngine",
                        options: engineOptions,
                        selection: $appState.transcriptionEngine,
                        activeDropdownID: $activeDropdownID
                    )
                }

                if appState.transcriptionEngine == .localWhisper {
                    localModelRow
                }

                Text(engineExplanation)
                    .font(Theme.Typography.body(10, weight: .light))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// On Intel the on-device option is shown but locked rather than hidden: an option that
    /// silently does not exist reads as a missing feature, not an unsupported one.
    private var engineOptions: [DropdownOption<TranscriptionEngineKind>] {
        TranscriptionEngineKind.allCases.map { kind in
            let unsupported = kind == .localWhisper && !LocalWhisperEngine.isAvailable
            return DropdownOption(
                id: kind.rawValue,
                label: kind.displayName,
                value: kind,
                isLocked: unsupported,
                badge: unsupported ? "Apple Silicon" : nil
            )
        }
    }

    private var engineExplanation: String {
        switch appState.transcriptionEngine {
        case .cloudGemini:
            return "Transcribes in the cloud. Needs a Tracer account and an internet connection."
        case .localWhisper:
            return "Transcribes on this Mac. Nothing is uploaded and there is nothing to pay for. Titles are still generated in the cloud."
        }
    }

    private var localModelRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.md) {
                Text("Model")
                    .font(Theme.Typography.body(12))
                Spacer()
                modelStatusControl(LocalModelState.shared.phase)
            }

            if case .failed(let message) = LocalModelState.shared.phase {
                Text(message)
                    .font(Theme.Typography.body(10, weight: .light))
                    .foregroundStyle(Theme.Colors.brandPurple)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let modelDownloadError {
                Text(modelDownloadError)
                    .font(Theme.Typography.body(10, weight: .light))
                    .foregroundStyle(Theme.Colors.brandPurple)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func modelStatusControl(_ phase: LocalModelState.Phase) -> some View {
        switch phase {
        case .ready:
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Colors.brandPurple)
                    .font(.system(size: 11))
                Text("Ready")
                    .font(Theme.Typography.body(12, weight: .light))
            }
            Button("Remove") {
                LocalWhisperEngine.deleteModel()
                LocalModelState.pushRefresh()
            }
            .buttonStyle(SettingsButtonStyle())

        case .downloading:
            VStack(alignment: .trailing, spacing: 2) {
                ProgressView(value: LocalModelState.shared.downloadProgress ?? 0)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                Text("\(Int((LocalModelState.shared.downloadProgress ?? 0) * 100))%")
                    .font(Theme.Typography.body(10, weight: .light))
                    .foregroundStyle(.secondary)
            }

        case .preparing:
            // The bytes are down and nothing visible happens for minutes while Core ML
            // compiles. Without saying so, a finished download looks like a hang.
            HStack(spacing: Theme.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text("Preparing model…")
                    .font(Theme.Typography.body(11, weight: .light))
                    .foregroundStyle(.secondary)
            }

        case .notDownloaded, .failed:
            Button("Download (1.5 GB)") { startModelDownload() }
                .buttonStyle(SettingsButtonStyle())
                .disabled(!LocalWhisperEngine.isAvailable)
        }
    }

    private func startModelDownload() {
        modelDownloadError = nil
        Task {
            do {
                try await LocalWhisperEngine.downloadModel()
            } catch {
                modelDownloadError = error.localizedDescription
            }
        }
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

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Toggle("Reduce background noise", isOn: $appState.reduceBackgroundNoise)
                        .controlSize(.small)
                        .font(Theme.Typography.body(12))
                    Text("Off = highest quality. On filters background noise but slightly processes your voice.")
                        .font(Theme.Typography.body(10, weight: .light))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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

                Button(isSendingReport ? "Sending…" : "Report a Problem") {
                    pendingReport = BugReportClient.makePayload()
                }
                .buttonStyle(SettingsButtonStyle())
                .disabled(isSendingReport)
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
                    Link("Privacy Policy", destination: URL(string: "https://tracer.nocorny.com/privacy")!)
                        .font(Theme.Typography.body(11))
                        .onHover { inside in
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }

                    Link("Terms of Service", destination: URL(string: "https://tracer.nocorny.com/terms")!)
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
