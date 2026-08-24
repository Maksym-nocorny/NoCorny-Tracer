import SwiftUI

/// List of recent recordings with upload status and actions
struct RecordingsListView: View {
    @Bindable var appState: AppState
    /// Hoisted to the list because the dropdown overlay has to sit outside the card, or the
    /// menu is clipped by it. One id at a time across the whole list, same as in Settings.
    @State private var activeDropdownID: String? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text("Your Recordings")
                            .font(Theme.Typography.body(13, weight: .semibold))
                            .textCase(.uppercase)

                        Text("\(appState.recordings.count)")
                            .font(Theme.Typography.body(11, weight: .medium))
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.08))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    if appState.dropboxAuthManager.isSignedIn {
                        HStack(spacing: Theme.Spacing.lg) {
                            Button {
                                appState.openTracerDashboard()
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .help("Open on tracer.nocorny.com")
                            .onHover { inside in
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }

                            Button {
                                Task { await appState.syncDropboxState() }
                            } label: {
                                if appState.isSyncingDropbox {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .disabled(appState.isSyncingDropbox)
                            .onHover { inside in
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }
                        }
                    }
                }

                if appState.recordings.isEmpty {
                    VStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No recordings yet")
                            .font(Theme.Typography.body(12, weight: .light))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, Theme.Spacing.xxxl)
                } else {
                    ZStack(alignment: .bottom) {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: Theme.Spacing.xs) {
                                ForEach(appState.recordings) { recording in
                                    RecordingRowView(
                                        appState: appState,
                                        recording: recording,
                                        activeDropdownID: $activeDropdownID
                                    )
                                }
                            }
                            .padding(.bottom, Theme.Spacing.xxl)
                        }
                        // See SettingsView for why this is .never — `showsIndicators: false`
                        // is equivalent to .hidden and gets overridden the same way.
                        .scrollIndicators(.never)

                        // Bottom fade to indicate more content
                        LinearGradient(
                            colors: [
                                Theme.Colors.cardBackground.opacity(0),
                                Theme.Colors.cardBackground
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 32)
                        .allowsHitTesting(false)
                    }
                }
            }
            .cardStyle()

            if appState.dropboxAuthManager.isSignedIn && appState.dropboxAllocatedSpace > 0 {
                storageBarView
                    .cardStyle()
            }
        }
        .customDropdownOverlay(activeDropdownID: $activeDropdownID)
    }

    // MARK: - Storage Bar

    private var storageBarView: some View {
        let used = Double(appState.dropboxUsedSpace)
        let allocated = Double(appState.dropboxAllocatedSpace)
        let remaining = max(0, allocated - used)
        let percentLeft = remaining / allocated

        let isLowSpace = percentLeft < 0.2

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        let usedStr = formatter.string(fromByteCount: Int64(used))
        let allocatedStr = formatter.string(fromByteCount: Int64(allocated))

        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "cloud")
                        .font(.system(size: 10))
                    Text("Dropbox Storage")
                        .font(Theme.Typography.body(10, weight: .bold))
                }

                Spacer()

                Text("\(usedStr) / \(allocatedStr)")
                    .font(Theme.Typography.body(10, weight: .medium))
            }
            .foregroundStyle(isLowSpace ? Theme.Colors.red : .secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(isLowSpace ? AnyShapeStyle(Theme.Colors.dangerGradient) : AnyShapeStyle(Theme.Colors.primaryGradient))
                        .frame(width: max(2, geometry.size.width * CGFloat(used / allocated)), height: 4)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Recording Row

struct RecordingRowView: View {
    @Bindable var appState: AppState
    let recording: Recording
    @Binding var activeDropdownID: String?
    @State private var showCopied = false
    @State private var isLinkHovered = false
    @State private var isHovered = false
    @State private var showingDeleteAlert = false
    // Drives the brief post-upload checkmark. Previously every row ran a perpetual
    // 1 Hz Timer that re-rendered the whole list every second just to expire this —
    // now it's a one-shot toggle scheduled only when an upload completes.
    @State private var showCloudIcon = false

    private func scheduleCloudIcon(_ completedAt: Date?) {
        guard let completedAt else { showCloudIcon = false; return }
        let remaining = 5 - Date().timeIntervalSince(completedAt)
        guard remaining > 0 else { showCloudIcon = false; return }
        showCloudIcon = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            showCloudIcon = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            mainRow
            if canReapplySpeakers {
                speakersRow
            }
        }
    }

    private var mainRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Play icon / thumbnail
            Button {
                if let shareURL = recording.shareURL {
                    NSWorkspace.shared.open(shareURL)
                }
            } label: {
                ZStack {
                    if let path = recording.dropboxPath {
                        DropboxThumbnailView(path: path, appState: appState)
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(.quaternary)
                            .frame(width: 64, height: 42)

                        Image(systemName: "play.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if isHovered {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Color.black.opacity(0.15))
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .frame(width: 64, height: 42)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }

            // Recording info
            VStack(alignment: .leading, spacing: 1) {
                Text(recording.displayName)
                    .font(Theme.Typography.body(13, weight: .medium))
                    .lineLimit(1)

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.Spacing.xs) {
                        if !recording.formattedFileSize.isEmpty {
                            Text(recording.formattedFileSize)
                                .font(Theme.Typography.body(11, weight: .light))

                            Text("·")
                                .font(Theme.Typography.body(11, weight: .light))
                        }

                        Text(recording.formattedDuration)
                            .font(Theme.Typography.body(11, weight: .light))
                    }

                    Text(recording.formattedDate)
                        .font(Theme.Typography.body(11, weight: .light))
                }
            }

            Spacer(minLength: 4)

            // Action buttons
            HStack(spacing: Theme.Spacing.sm) {
                if showingDeleteAlert {
                    Button("Delete") {
                        Task {
                            await appState.deleteRecording(recording)
                        }
                    }
                    .fixedSize()
                    .font(Theme.Typography.body(11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Theme.Colors.red)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Button("Cancel") {
                        showingDeleteAlert = false
                    }
                    .fixedSize()
                    .font(Theme.Typography.body(11))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .buttonStyle(.plain)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                } else {
                    Button {
                        showingDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.red)
                            .frame(width: 22, height: 22)
                            .background(Theme.Colors.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || showingDeleteAlert ? 1 : 0)
                    .disabled(!isHovered && !showingDeleteAlert)
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Button {
                        guard let url = recording.shareURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    } label: {
                        Image(systemName: showCopied ? "checkmark" : "link")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                showCopied ? Theme.Colors.green :
                                (recording.shareURL == nil ? Color.primary.opacity(0.15) :
                                (isLinkHovered ? Theme.Colors.brandPurple : .secondary))
                            )
                            .frame(width: 22, height: 22)
                            .background(isLinkHovered && recording.shareURL != nil ? Theme.Colors.brandPurple.opacity(0.1) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isLinkHovered = hovering
                        if hovering && recording.shareURL != nil { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    uploadStatusIcon
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .onHover { hovering in
            isHovered = hovering
        }
        .onAppear { scheduleCloudIcon(recording.uploadCompletedAt) }
        .onChange(of: recording.uploadCompletedAt) { _, newValue in
            scheduleCloudIcon(newValue)
        }
        .background(.clear)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if let shareURL = recording.shareURL {
                    NSWorkspace.shared.open(shareURL)
                } else if FileManager.default.fileExists(atPath: recording.fileURL.path) {
                    NSWorkspace.shared.open(recording.fileURL)
                }
            }
        )
    }

    // MARK: - Speakers

    /// The count can only be corrected where all three hold: the plan includes separation,
    /// there is a transcript to re-label, and the audio to re-run against still exists either
    /// here or in Dropbox. Anything less and the control would be a button that fails.
    private var canReapplySpeakers: Bool {
        guard appState.tracerAPIClient.entitlements.diarization else { return false }
        guard recording.hasTranscript else { return false }
        return DiarizationAudioCache.shared.hasMicAudio(for: recording.id)
            || recording.diarizationMicPath != nil
    }

    /// No equality check on the way in: picking the value that is already selected is how you
    /// retry a run that failed, and refusing it would look like the control was stuck.
    private var speakersBinding: Binding<ExpectedSpeakers> {
        Binding(
            get: { recording.expectedSpeakers ?? appState.expectedSpeakers },
            set: { newValue in
                Task { await appState.reapplySpeakers(recordingID: recording.id, expected: newValue) }
            }
        )
    }

    private var speakersRow: some View {
        let isRunning = appState.reapplyingSpeakers.contains(recording.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "person.2")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text("Speakers")
                    .font(Theme.Typography.body(11, weight: .light))
                    .foregroundStyle(.secondary)

                Spacer(minLength: Theme.Spacing.xs)

                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    CustomDropdownButton(
                        id: "speakers-\(recording.id.uuidString)",
                        options: ExpectedSpeakers.allCases.map {
                            DropdownOption(id: $0.rawValue, label: $0.displayName, value: $0)
                        },
                        selection: speakersBinding,
                        activeDropdownID: $activeDropdownID,
                        minWidth: 128
                    )
                }
            }

            if let failure = appState.speakerReapplyErrors[recording.id] {
                Text(failure)
                    .font(Theme.Typography.body(10, weight: .light))
                    .foregroundStyle(Theme.Colors.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Full row width, inset to the same edges as the row above it. Indenting it under the
        // title would leave the dropdown 190pt to live in inside a 380pt window, which is how
        // a label ends up reading "Spea...".
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.xs)
    }

    @ViewBuilder
    private var uploadStatusIcon: some View {
        switch recording.uploadStatus {
        case .notUploaded:
            Image(systemName: "icloud.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .uploading:
            // Determinate when the byte counter is flowing, a spinner in the moments before
            // it starts. The spinner alone was the whole story for a 20-minute recording,
            // which is indistinguishable from stuck.
            if let fraction = appState.uploadProgress[recording.id] {
                HStack(spacing: 5) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 56)
                    Text("\(Int(fraction * 100))%")
                        .font(Theme.Typography.body(9))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .help("Uploading to Dropbox")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .uploaded:
            if showCloudIcon {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.green)
            }
        case .failed:
            Button {
                Task { await appState.retryUpload(recording) }
            } label: {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.red)
            }
            .buttonStyle(.plain)
            .help(recording.uploadError ?? "Upload failed — click to retry")
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}
