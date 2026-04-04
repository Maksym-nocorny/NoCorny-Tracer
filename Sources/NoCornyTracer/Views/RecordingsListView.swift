import SwiftUI

/// List of recent recordings with upload status and actions
struct RecordingsListView: View {
    @Bindable var appState: AppState

    var body: some View {
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
                        .background(Color.black.opacity(0.06))
                        .clipShape(Capsule())
                }

                Spacer()

                if appState.dropboxAuthManager.isSignedIn {
                    HStack(spacing: Theme.Spacing.lg) {
                        Button {
                            appState.openDropboxWebFolder()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .help("Open Dropbox folder")
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xxxl)
            } else {
                ZStack(alignment: .bottom) {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: Theme.Spacing.xs) {
                            ForEach(appState.recordings) { recording in
                                RecordingRowView(appState: appState, recording: recording)
                            }
                        }
                        .padding(.bottom, Theme.Spacing.xxl)
                    }

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
    }
}

// MARK: - Recording Row

struct RecordingRowView: View {
    @Bindable var appState: AppState
    let recording: Recording
    @State private var showCopied = false
    @State private var isLinkHovered = false
    @State private var isHovered = false
    @State private var showingDeleteAlert = false
    @State private var uptime = Date()

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var showCloudIcon: Bool {
        guard let completedAt = recording.uploadCompletedAt else { return false }
        return Date().timeIntervalSince(completedAt) < 5
    }

    var body: some View {
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
        .onReceive(timer) { input in
            uptime = input
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

    @ViewBuilder
    private var uploadStatusIcon: some View {
        switch recording.uploadStatus {
        case .notUploaded:
            Image(systemName: "icloud.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        case .uploading:
            ProgressView()
                .controlSize(.small)
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
