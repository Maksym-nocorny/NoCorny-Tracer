import SwiftUI
import AppKit

/// The Settings drawer of the command bar (Figma 61:66): the old SettingsView's
/// sections re-laid as macro-style rows — label left, value right, tracked all-caps
/// section headers, hairline dividers. Same 560×332 glass sheet as the Gallery.
/// Controls are the drawer's OWN (DrawerControls.swift) since round 2 — the old
/// design's CustomDropdownButton and system switches are gone (verdict 25.08).
struct DrawerSettingsView: View {
    @Bindable var appState: AppState
    let manager: CommandBarWindowManager

    /// Why a locked engine could not be picked, shown under the Engine row.
    @State private var lockedEngineNotice: String? = nil
    /// Download failures thrown before LocalModelState hears about them (no disk
    /// space, a download already running) — see `modelPhase`.
    @State private var modelDownloadError: String? = nil

    private var isRecording: Bool { appState.recordingManager.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    recordingSection
                    accountSection
                    // After ACCOUNT, not after RECORDING — that is where the macro
                    // (Drawer / Settings, 77:1179) places it.
                    transcriptionSection
                    generalSection
                    aboutSection
                }
                .padding(.trailing, 4)
            }
            // The macro draws a scrollbar (61:233) — don't force it hidden.
            .scrollIndicators(.automatic)
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

    // MARK: Header (61:128: "Settings" + "⌘,  ·  Esc закрити" — EN copy here)

    private var header: some View {
        HStack(spacing: 8) {
            Text("Settings")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DrawerStyle.ink(0.9))

            Spacer(minLength: 8)

            // Both shortcuts are live on the panel: ⌘, toggles this drawer
            // (CommandBarPanel.onCmdComma), Esc closes it.
            Text("⌘,  ·  Esc to close")
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
                    DrawerPopUp(
                        options: VideoResolution.allCases.map {
                            DrawerPopUpOption(id: $0.rawValue, label: $0.displayName, value: $0)
                        },
                        selection: $appState.videoResolution
                    )
                }

                hairline

                // icon/play in the macro (61:158) — the ▶ reads as "motion".
                settingRow(icon: "play", label: "Frame rate") {
                    DrawerPopUp(
                        options: VideoFrameRate.allCases.map {
                            DrawerPopUpOption(id: String($0.rawValue), label: $0.displayName, value: $0)
                        },
                        selection: $appState.videoFrameRate
                    )
                }

                hairline

                settingRow(icon: "mic", label: "Microphone") {
                    DrawerPopUp(
                        options: [DrawerPopUpOption(id: "", label: "Default Input", value: "")] +
                            appState.recordingManager.audioCaptureManager.availableDevices.map {
                                DrawerPopUpOption(id: $0.uniqueID, label: $0.localizedName, value: $0.uniqueID)
                            },
                        selection: Binding(
                            get: { appState.selectedMicrophoneID ?? "" },
                            set: { appState.selectedMicrophoneID = $0.isEmpty ? nil : $0 }
                        )
                    )
                }

                hairline

                settingRow(icon: "video", label: "Camera") {
                    DrawerPopUp(
                        options: [DrawerPopUpOption(id: "", label: "Default Camera", value: "")] +
                            appState.cameraManager.availableDevices.map {
                                DrawerPopUpOption(id: $0.uniqueID, label: $0.localizedName, value: $0.uniqueID)
                            },
                        selection: Binding(
                            get: { appState.selectedCameraDeviceID ?? "" },
                            set: { appState.selectedCameraDeviceID = $0.isEmpty ? nil : $0 }
                        )
                    )
                }

                hairline

                // Blessed into the macro in phase 8 (581:2079 / 581:2090).
                settingRow(icon: "waveform", label: "Reduce background noise") {
                    DrawerToggle(isOn: $appState.reduceBackgroundNoise)
                }

                hairline

                settingRow(icon: "speaker.wave.2", label: "Record system audio") {
                    DrawerToggle(isOn: $appState.recordSystemAudio)
                }

                hairline

                // Round 6 (package 4): the DEBUG-only "capturable panels" switch,
                // legalized. Off = the bar and friends stay out of captures
                // (sharingType .none); on = they join screenshots and recordings.
                settingRow(
                    icon: "camera.viewfinder",
                    label: "Show Tracer in screen captures",
                    subtext: "Panels appear in screenshots and in your recordings"
                ) {
                    DrawerToggle(isOn: $appState.panelsCapturable)
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

            DrawerLink(title: "Sign Out") {
                Task {
                    await appState.tracerAPIClient.signOut()
                    await MainActor.run {
                        appState.dropboxAuthManager.clearProxiedState()
                        appState.resetTracerLibraryState()
                    }
                }
            }
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

                DrawerLink(title: appState.dropboxAuthManager.isSignedIn ? "Manage ↗" : "Connect ↗") {
                    appState.openTracerSettings()
                }
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

    // MARK: TRANSCRIPTION (phase 3b, macro component "Drawer / Settings" 77:1179)

    private var transcriptionSection: some View {
        VStack(spacing: 0) {
            DrawerSectionHeader(title: "TRANSCRIPTION")

            settingRow(icon: "sparkles", label: "Engine") {
                DrawerPopUp(
                    options: engineOptions,
                    selection: $appState.transcriptionEngine,
                    onLockedTap: handleLockedEngine
                )
            }

            if let lockedEngineNotice {
                Text(lockedEngineNotice)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DrawerStyle.ink(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 24)
                    .padding(.bottom, 8)
                    .padding(.trailing, 4)
            }

            if showsModelRow {
                hairline
                localModelRow
            }

            hairline

            // "Speakers" per the macro (527:3597) — the row NAME dropped the
            // "(diarization)" tail in the design.
            settingRow(icon: "person.2", label: "Speakers") {
                diarizationControl
            }

            // The default headcount for NEW recordings (macro 559:2030) — the row the
            // old SettingsView lost in phase 7. Deliberately the same person.2 icon as
            // the Speakers row: the two form the diarization group. Same visibility
            // rule as the old page: only while separation is unlocked AND on — a
            // headcount for a feature that is off would be a dead control.
            if appState.tracerAPIClient.entitlements.diarization && appState.diarizationEnabled {
                hairline

                settingRow(icon: "person.2", label: "People in new recordings") {
                    DrawerPopUp(
                        options: ExpectedSpeakers.quickPickChoices(including: appState.expectedSpeakers).map {
                            DrawerPopUpOption(id: $0.rawValue, label: $0.shortName, value: $0)
                        },
                        selection: $appState.expectedSpeakers
                    )
                }
            }
        }
    }

    /// The picker's options, padlock semantics 1:1 with the old SettingsView: an
    /// unavailable option is shown locked rather than hidden — an option that silently
    /// does not exist reads as a missing feature, one with a padlock and a reason reads
    /// as a choice you have not unlocked yet.
    private var engineOptions: [DrawerPopUpOption<TranscriptionEngineKind>] {
        let entitlements = appState.tracerAPIClient.entitlements
        return TranscriptionEngineKind.pickerCases(offeredCloudEngines: entitlements.cloudEngines).map { kind in
            switch kind {
            case .localWhisper where !LocalWhisperEngine.isAvailable:
                return DrawerPopUpOption(
                    id: kind.rawValue, label: drawerEngineLabel(kind), value: kind,
                    isLocked: true, badge: "Apple Silicon"
                )
            // Entitled, but switched off server-side. Picking it would upload a chunk and
            // collect a 503, then quietly transcribe on a different engine than the one
            // chosen -- a choice that does not exist, offered as though it did.
            case _ where !entitlements.offersCloudEngine(kind):
                return DrawerPopUpOption(
                    id: kind.rawValue, label: drawerEngineLabel(kind), value: kind,
                    isLocked: true, badge: "Unavailable"
                )
            case .cloudGemini where !entitlements.cloudTranscription,
                 .cloudGroq where !entitlements.cloudTranscription:
                return DrawerPopUpOption(
                    id: kind.rawValue, label: drawerEngineLabel(kind), value: kind,
                    isLocked: true, badge: "Premium"
                )
            default:
                return DrawerPopUpOption(id: kind.rawValue, label: drawerEngineLabel(kind), value: kind)
            }
        }
    }

    /// The macro names the local engine "On-device (Whisper)"; displayName still says
    /// "On this Mac" for the old SettingsView, so the override lives here.
    private func drawerEngineLabel(_ kind: TranscriptionEngineKind) -> String {
        kind == .localWhisper ? "On-device (Whisper)" : kind.displayName
    }

    /// Sends people to where the decision is actually made rather than pretending to
    /// switch and failing later (port of SettingsView.handleLockedEngine).
    private func handleLockedEngine(_ kind: TranscriptionEngineKind) {
        // Switched off server-side is not the same as not paid for, and sending someone
        // to a plan page over something no plan can buy wastes their time.
        guard appState.tracerAPIClient.entitlements.offersCloudEngine(kind) else {
            lockedEngineNotice = "\(kind.displayName) is switched off right now. Nothing to do on your side."
            return
        }
        switch kind {
        case .cloudGemini, .cloudGroq:
            if let url = URL(string: "\(TracerAPIClient.baseURL)/settings#plan") {
                NSWorkspace.shared.open(url)
            }
        case .localWhisper:
            lockedEngineNotice = "On-device transcription needs a Mac with Apple Silicon."
        }
    }

    // MARK: On-device model row

    /// Visible whenever the local engine is chosen OR the model exists in any form on
    /// this Mac (downloading, preparing, ready, failed) — a row that hides mid-download
    /// would take a running progress indicator with it.
    private var showsModelRow: Bool {
        appState.transcriptionEngine == .localWhisper
            || LocalModelState.shared.phase != .notDownloaded
            || modelDownloadError != nil
    }

    /// `LocalModelState` misses failures thrown before the byte fetch starts (no disk
    /// space, download already running), which the old SettingsView showed from a local
    /// catch. Merge them: the pushed phase wins whenever it is doing or saying anything.
    private var modelPhase: LocalModelState.Phase {
        let phase = LocalModelState.shared.phase
        if let modelDownloadError, phase == .notDownloaded {
            return .failed(modelDownloadError)
        }
        return phase
    }

    /// icon/folder per the macro (527:1593) — the model is a thing ON DISK.
    private var localModelRow: some View {
        settingRow(icon: "folder", label: "On-device model") {
            modelStatusCluster
        }
    }

    /// Right side of the model row: status dot + line (macro shows the Ready state:
    /// green 7pt dot, "Ready · 1.5 GB") and the action link in the Sign Out style.
    /// The other states follow the old modelStatusControl's behaviour.
    private var modelStatusCluster: some View {
        HStack(spacing: 6) {
            modelStatusContent
        }
    }

    @ViewBuilder
    private var modelStatusContent: some View {
        switch modelPhase {
        case .ready:
            modelDot(Theme.Colors.statusGreen)
            modelStatusText("Ready · 1.5 GB")
            modelLink("Remove") {
                LocalWhisperEngine.deleteModel()
                LocalModelState.pushRefresh()
            }

        case .downloading:
            modelDot(Theme.Colors.pausedAmber)
            if let progress = LocalModelState.shared.downloadProgress {
                modelStatusText("Downloading… \(Int(progress * 100))%")
            } else {
                modelStatusText("Downloading…")
            }

        case .preparing:
            // The bytes are down and nothing visible happens for minutes while Core ML
            // compiles. Without saying so, a finished download looks like a hang.
            modelStatusText("Preparing…")

        case .notDownloaded:
            modelStatusText("Not downloaded")
            modelLink("Download") { startModelDownload() }
                .disabled(!LocalWhisperEngine.isAvailable)

        case .failed(let message):
            modelDot(Theme.Colors.recordRed)
            modelStatusText(message.isEmpty ? "Failed" : message)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(message)
            modelLink("Retry") { startModelDownload() }
        }
    }

    private func modelDot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private func modelStatusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(DrawerStyle.ink(0.55))
            .monospacedDigit()
    }

    private func modelLink(_ title: String, action: @escaping () -> Void) -> some View {
        DrawerLink(title: title, action: action)
            .padding(.leading, 4)
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

    // MARK: Speakers (diarization)

    /// Same binding and padlock semantics as SettingsView.diarizationRow: the toggle
    /// reads OFF the moment the plan stops including it (bound straight to the stored
    /// setting, a downgrade left a switch sitting ON, disabled, doing nothing), and the
    /// Premium badge is the thing you click to go and unlock it.
    @ViewBuilder
    private var diarizationControl: some View {
        let unlocked = appState.tracerAPIClient.entitlements.diarization

        HStack(spacing: 8) {
            if !unlocked {
                // Ink-styled Premium tag (the purple one was the OLD design's
                // accent) — still the thing you click to go unlock the feature.
                Button {
                    if let url = URL(string: "\(TracerAPIClient.baseURL)/settings#plan") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Premium")
                            .font(.system(size: 10))
                            .foregroundStyle(DrawerStyle.ink(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DrawerStyle.ink(0.08)))
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(DrawerStyle.ink(0.55))
                    }
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }

            DrawerToggle(isOn: Binding(
                get: { unlocked && appState.diarizationEnabled },
                set: { appState.diarizationEnabled = $0 }
            ))
            .disabled(!unlocked)
            .opacity(unlocked ? 1 : 0.55)
        }
    }

    // MARK: GENERAL

    private var generalSection: some View {
        VStack(spacing: 0) {
            DrawerSectionHeader(title: "GENERAL")

            // Known delta (TASK.md): the macro reuses icon/play here; SF `power`
            // says "launch" better and stays until the kit grows an icon/power.
            settingRow(icon: "power", label: "Launch at Login") {
                DrawerToggle(isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: {
                        appState.launchAtLogin = $0
                        appState.updateLaunchAtLogin()
                    }
                ))
            }

            hairline

            settingRow(icon: "circle.lefthalf.filled", label: "Appearance") {
                DrawerPopUp(
                    options: AppState.AppTheme.allCases.map {
                        DrawerPopUpOption(id: $0.rawValue, label: $0.displayName, value: $0)
                    },
                    selection: $appState.appTheme
                )
            }

            hairline

            // Macro row 61:225 — the app finally grows it: the drawer is the only
            // Settings surface since phase 7, and Sparkle's auto-check had no
            // switch anywhere. 4.2.0: OFF also stops the silent download+staged
            // install (Sparkle couples allowsAutomaticUpdates to the checks) —
            // the subtext says what the switch really governs.
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.6))
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-updates (Sparkle)")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(DrawerStyle.ink(0.88))
                    Text("Auto-download and install")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DrawerStyle.ink(0.42))
                }

                Spacer(minLength: 8)

                DrawerToggle(isOn: autoUpdatesBinding)
            }
            .padding(.vertical, 9)
            .padding(.trailing, 4)
        }
    }

    /// The "Relaunch to update" chip (4.2.0). Reading the coordinator's
    /// observable `pendingUpdateVersion` inside body keeps the row live — it
    /// swaps in the moment a staged update lands.
    private var updateChip: UpdateChipState? {
        UpdateChipState.decide(
            pendingVersion: UpdateCoordinator.shared?.pendingUpdateVersion,
            isRecording: isRecording
        )
    }

    /// Sparkle's auto-check switch, through PermissionsManager (which owns the
    /// updater handle and the optimistic flag). Fallbacks resolve the way
    /// Sparkle does — defaults first, then Info.plist — because raw defaults
    /// miss the plist's `SUEnableAutomaticChecks=true` default (4.2.0).
    private var autoUpdatesBinding: Binding<Bool> {
        Binding(
            get: {
                PermissionsManager.shared?.isAutoUpdateEnabled
                    ?? AppDelegate.bootstrapUpdaterController?.updater.automaticallyChecksForUpdates
                    ?? UserDefaults.standard.bool(forKey: "SUEnableAutomaticChecks")
            },
            set: { newValue in
                guard let permissions = PermissionsManager.shared else { return }
                if permissions.isAutoUpdateEnabled != newValue {
                    permissions.toggleAutoUpdate()
                }
            }
        )
    }

    // MARK: ABOUT (macro 76:149: Version + the links row live under their own header)

    private var aboutSection: some View {
        VStack(spacing: 0) {
            DrawerSectionHeader(title: "ABOUT")

            // No icon — the macro's set/version row (76:151) is label + value only.
            HStack(spacing: 10) {
                Text("Version")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.88))

                Spacer(minLength: 8)

                Text(appVersion)
                    .font(.system(size: 12))
                    .foregroundStyle(DrawerStyle.ink(0.5))
            }
            .padding(.vertical, 9)
            .padding(.trailing, 4)

            hairline

            linksRow
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    /// The macro's flat link row (76:156): Check for Updates · Show Logs · Privacy.
    /// "Report a Problem" joined in phase 7, ported from the old SettingsView's
    /// General section so the reporting door survives the main window.
    private var linksRow: some View {
        HStack(spacing: 16) {
            if let chip = updateChip {
                // 4.2.0: a downloaded update replaces the manual check — green
                // dot + the same link style, one click to install and relaunch.
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.Colors.statusGreen)
                        .frame(width: 5, height: 5)
                    linkButton(chip.title) {
                        UpdateCoordinator.shared?.installPendingUpdate()
                    }
                }
            } else {
                linkButton("Check for Updates") {
                    // Activation lives inside: without it every Sparkle window
                    // opened BEHIND the frontmost app (the 4.0.0 dead button).
                    UpdateCoordinator.requestUserInitiatedCheck()
                }
            }
            linkButton("Show Logs") {
                NSWorkspace.shared.selectFile(
                    LogManager.shared.getLogFileURL().path,
                    inFileViewerRootedAtPath: ""
                )
            }
            linkButton(isSendingReport ? "Sending…" : "Report a Problem") {
                reportAProblem()
            }
            .disabled(isSendingReport)
            linkButton("Privacy") {
                if let url = URL(string: "https://tracer.nocorny.com/privacy") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }

    // MARK: Problem reports (ported from the old SettingsView in phase 7)

    @State private var isSendingReport = false

    /// Same flow as the old Settings tab: availability check, then an explicit
    /// consent dialog listing what actually goes (the report contains the app's
    /// own diagnostic log, and telling someone that only after the fact is not
    /// consent — the numbers are real ones read off the payload). NSAlert rather
    /// than SwiftUI .alert: the drawer sits on a borderless nonactivating panel,
    /// where sheet-style alerts have nothing reliable to attach to. The drawer is
    /// only open outside a recording, so the activation NSAlert brings is fine.
    private func reportAProblem() {
        switch BugReportComposer.availability {
        case .ready:
            let payload = BugReportClient.makePayload()
            let alert = NSAlert()
            alert.messageText = "Send a problem report?"
            alert.informativeText = """
            This sends recent diagnostic log entries (about \(payload.logSizeKB) KB), \
            your app version (\(payload.appVersion)), macOS version and Mac model.

            No video, audio or transcript text is included, and links to your recordings \
            are removed.
            """
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                sendReport(payload)
            }
        case .noLogYet:
            showReportOutcome("There is nothing in the log to send yet.")
        case .onlyOlderVersions:
            // Normal right after an update, and worth saying plainly: a report
            // only carries entries this version wrote, and it has not written
            // any yet.
            showReportOutcome("Everything logged so far came from the previous version. Reports only include entries from the current one - use the app for a moment and try again.")
        }
    }

    private func sendReport(_ payload: BugReportClient.Payload) {
        isSendingReport = true
        Task {
            let outcome: String
            do {
                try await BugReportClient.send(payload, token: appState.tracerAPIClient.apiToken)
                outcome = "Report sent. Thank you."
            } catch {
                outcome = error.localizedDescription
            }
            await MainActor.run {
                isSendingReport = false
                showReportOutcome(outcome)
            }
        }
    }

    private func showReportOutcome(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Problem report"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        DrawerLink(title: title, opacity: 0.6, action: action)
    }

    // MARK: Row scaffolding (macro: icon 14 / label 12.5 medium / value right, py 9)

    private func settingRow(
        icon: String,
        label: String,
        subtext: String? = nil,
        @ViewBuilder value: () -> some View
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.6))
                .frame(width: 14)

            // The optional subtext (round 6) rides UNDER the label, dimmer and
            // smaller — the row grows, the trailing control stays centered.
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.88))
                if let subtext {
                    Text(subtext)
                        .font(.system(size: 10))
                        .foregroundStyle(DrawerStyle.ink(0.45))
                }
            }

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
