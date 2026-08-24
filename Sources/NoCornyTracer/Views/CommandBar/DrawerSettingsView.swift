import SwiftUI
import AppKit

/// The Settings drawer of the command bar (Figma 61:66): the old SettingsView's
/// sections re-laid as macro-style rows — label left, value right, tracked all-caps
/// section headers, hairline dividers. Same 560×332 glass sheet as the Gallery.
struct DrawerSettingsView: View {
    @Bindable var appState: AppState
    let manager: CommandBarWindowManager

    /// One open dropdown at a time across the whole drawer, same as SettingsView.
    @State private var activeDropdownID: String? = nil

    private var isRecording: Bool { appState.recordingManager.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    recordingSection

                    // MARK: Transcription section lands after design sync (phase 3b)

                    accountSection
                    generalSection
                }
                .padding(.trailing, 4)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)

            DrawerFooterView(appState: appState)
        }
        .padding(.leading, DrawerStyle.leadingInset)
        .padding(.trailing, DrawerStyle.trailingInset)
        .padding(.top, DrawerStyle.topInset)
        .frame(
            width: Theme.Metrics.drawerSize.width,
            height: Theme.Metrics.drawerSize.height
        )
        .glassSurface(cornerRadius: DrawerStyle.cornerRadius)
        .floatingPanelShadow()
        // On the drawer ROOT and after the glass clip, so menus draw above every row
        // and are not cut off by the glass surface's clipShape.
        .customDropdownOverlay(activeDropdownID: $activeDropdownID)
        .onAppear {
            appState.cameraManager.refreshDevices()
            appState.recordingManager.audioCaptureManager.refreshDevices()
        }
        // Esc while SwiftUI focus is inside the drawer; the panel-level fallback in
        // CommandBarPanel.onEsc covers the no-focus case.
        .onExitCommand {
            manager.morph(to: .bar)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Settings")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DrawerStyle.ink(0.9))

            Spacer(minLength: 8)

            Text("Esc to close")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.4))
        }
        .padding(.bottom, 8)
        .padding(.trailing, 4)
    }

    // MARK: RECORDING

    private var recordingSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                DrawerSectionHeader(title: "RECORDING", topPadding: 2)
                if isRecording {
                    Text("Locked during recording")
                        .font(.system(size: 10))
                        .foregroundStyle(DrawerStyle.ink(0.4))
                        .padding(.top, 2)
                }
            }

            Group {
                settingRow(icon: "display", label: "Resolution") {
                    CustomDropdownButton(
                        id: "drawer-resolution",
                        options: VideoResolution.allCases.map {
                            DropdownOption(id: $0.rawValue, label: $0.displayName, value: $0)
                        },
                        selection: $appState.videoResolution,
                        activeDropdownID: $activeDropdownID
                    )
                }

                hairline

                settingRow(icon: "film", label: "Frame rate") {
                    CustomDropdownButton(
                        id: "drawer-framerate",
                        options: VideoFrameRate.allCases.map {
                            DropdownOption(id: String($0.rawValue), label: $0.displayName, value: $0)
                        },
                        selection: $appState.videoFrameRate,
                        activeDropdownID: $activeDropdownID
                    )
                }

                hairline

                settingRow(icon: "mic", label: "Microphone") {
                    CustomDropdownButton(
                        id: "drawer-microphone",
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

                hairline

                settingRow(icon: "video", label: "Camera") {
                    CustomDropdownButton(
                        id: "drawer-camera",
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
            // Same rule as the old Settings: capture parameters are fixed mid-recording.
            .disabled(isRecording)
            .opacity(isRecording ? 0.55 : 1)
        }
    }

    // MARK: ACCOUNT

    private var accountSection: some View {
        VStack(spacing: 0) {
            DrawerSectionHeader(title: "ACCOUNT")

            if appState.tracerAPIClient.isSignedIn {
                signedInAccountRow
                hairline
                dropboxRow
            } else {
                VStack(spacing: 8) {
                    DrawerGoogleSignInButton(appState: appState)
                    if let error = appState.tracerAPIClient.errorMessage {
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.Colors.recordRed)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
            }
        }
    }

    private var signedInAccountRow: some View {
        HStack(spacing: 10) {
            drawerAvatar

            VStack(alignment: .leading, spacing: 1) {
                Text("\(tracerDisplayName) — Google")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.9))
                    .lineLimit(1)
                Text(appState.tracerAPIClient.userEmail ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DrawerStyle.ink(0.42))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button("Sign Out") {
                Task {
                    await appState.tracerAPIClient.signOut()
                    await MainActor.run {
                        appState.dropboxAuthManager.clearProxiedState()
                        appState.resetTracerLibraryState()
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(DrawerStyle.ink(0.55))
            .pointerOnHover()
        }
        .padding(.top, 6)
        .padding(.bottom, 9)
        .padding(.trailing, 4)
    }

    /// Compact Dropbox status (macro node 61:199): one line + a 4pt quota bar.
    /// Managing/disconnecting lives on the web, so the action is "Manage ↗".
    private var dropboxRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cloud")
                    .font(.system(size: 12))
                    .foregroundStyle(DrawerStyle.ink(0.7))
                    .frame(width: 14)

                Text(dropboxLine)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.88))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button(appState.dropboxAuthManager.isSignedIn ? "Manage ↗" : "Connect ↗") {
                    appState.openTracerSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.55))
                .pointerOnHover()
            }

            if appState.dropboxAuthManager.isSignedIn && appState.dropboxAllocatedSpace > 0 {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DrawerStyle.ink(0.1))
                        Capsule()
                            .fill(Theme.Colors.statusGreen)
                            .frame(width: max(2, geometry.size.width * usedFraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 10)
        .padding(.trailing, 4)
    }

    private var dropboxLine: String {
        guard appState.dropboxAuthManager.isSignedIn else { return "Dropbox not connected" }
        guard appState.dropboxAllocatedSpace > 0 else { return "Dropbox connected" }
        return "Dropbox — \(Self.gigabytes(appState.dropboxUsedSpace)) / \(Self.gigabytes(appState.dropboxAllocatedSpace)) GB"
    }

    private var usedFraction: CGFloat {
        let allocated = Double(appState.dropboxAllocatedSpace)
        guard allocated > 0 else { return 0 }
        return CGFloat(min(1, Double(appState.dropboxUsedSpace) / allocated))
    }

    /// "34.2" under 10 GB precision matters, "48" once it doesn't (macro shows both).
    private static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / (1024 * 1024 * 1024)
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded)
            : String(format: "%.1f", rounded)
    }

    private var tracerDisplayName: String {
        if let name = appState.tracerAPIClient.userName, !name.isEmpty { return name }
        if let email = appState.tracerAPIClient.userEmail {
            return email.split(separator: "@").first.map(String.init) ?? email
        }
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

    /// Port of SettingsView.tracerAvatar at the macro's 30pt (node 61:192).
    @ViewBuilder
    private var drawerAvatar: some View {
        let urlString = appState.tracerAPIClient.userImageURL
        ZStack {
            if let image = AvatarCache.shared.image, urlString != nil {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color.adaptive(light: Color(hex: 0xD8DCE6), dark: Color(hex: 0x2A3140)))
                Text(tracerInitial)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DrawerStyle.ink(0.9))
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(DrawerStyle.ink(0.15), lineWidth: 1))
        .task(id: urlString) {
            AvatarCache.shared.ensure(urlString: urlString)
        }
    }

    // MARK: GENERAL

    private var generalSection: some View {
        VStack(spacing: 0) {
            DrawerSectionHeader(title: "GENERAL")

            settingRow(icon: "power", label: "Launch at Login") {
                Toggle("", isOn: $appState.launchAtLogin)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: appState.launchAtLogin) {
                        appState.updateLaunchAtLogin()
                    }
            }

            hairline

            settingRow(icon: "circle.lefthalf.filled", label: "Appearance") {
                CustomDropdownButton(
                    id: "drawer-appearance",
                    options: AppState.AppTheme.allCases.map {
                        DropdownOption(id: $0.rawValue, label: $0.displayName, value: $0)
                    },
                    selection: $appState.appTheme,
                    activeDropdownID: $activeDropdownID
                )
            }

            hairline

            settingRow(icon: "info.circle", label: "Version") {
                Text(appVersion)
                    .font(.system(size: 12))
                    .foregroundStyle(DrawerStyle.ink(0.5))
            }

            hairline

            linksRow
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// The macro's flat link row (76:156): Check for Updates · Show Logs · Privacy.
    private var linksRow: some View {
        HStack(spacing: 16) {
            linkButton("Check for Updates") {
                (NSApp.delegate as? AppDelegate)?.updaterController?.checkForUpdates(nil)
            }
            linkButton("Show Logs") {
                NSWorkspace.shared.selectFile(
                    LogManager.shared.getLogFileURL().path,
                    inFileViewerRootedAtPath: ""
                )
            }
            linkButton("Privacy") {
                if let url = URL(string: "https://tracer.nocorny.com/privacy") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.6))
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    // MARK: Row scaffolding (macro: icon 14 / label 12.5 medium / value right, py 9)

    private func settingRow(
        icon: String,
        label: String,
        @ViewBuilder value: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.6))
                .frame(width: 14)

            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.88))

            Spacer(minLength: 8)

            value()
        }
        .padding(.vertical, 9)
        .padding(.trailing, 4)
    }

    private var hairline: some View {
        Rectangle()
            .fill(DrawerStyle.hairline)
            .frame(height: 1)
    }
}
