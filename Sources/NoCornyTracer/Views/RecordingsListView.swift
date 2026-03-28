import SwiftUI

/// List of recent recordings with upload status and actions
struct RecordingsListView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your Recordings")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if appState.dropboxAuthManager.isSignedIn {
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
                }
            }
            .padding(.horizontal)

            if appState.recordings.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                    Text("No recordings yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appState.recordings.prefix(10)) { recording in
                            RecordingRowView(appState: appState, recording: recording)
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 450)
            }
        }
    }
}

// MARK: - Recording Row

struct RecordingRowView: View {
    @Bindable var appState: AppState // Need bindable for delete
    let recording: Recording
    @State private var showCopied = false
    @State private var isLinkHovered = false
    @State private var isHovered = false
    @State private var showingDeleteAlert = false
    @State private var uptime = Date() // For Timer trigger
    
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var showCloudIcon: Bool {
        guard let completedAt = recording.uploadCompletedAt else { return false }
        return Date().timeIntervalSince(completedAt) < 5
    }

    var body: some View {
        HStack(spacing: 12) {
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
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .frame(width: 48, height: 32)
                        
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    
                    // Hover overlay
                    if isHovered {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.15))
                            .overlay {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                            }
                    }
                }
                .frame(width: 48, height: 32)
            }
            .buttonStyle(.plain)

            // Recording info
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(recording.formattedDuration)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text("·")
                        .foregroundStyle(.quaternary)
                    
                    if !recording.formattedFileSize.isEmpty {
                        Text(recording.formattedFileSize)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        
                        Text("·")
                            .foregroundStyle(.quaternary)
                    }

                    Text(recording.formattedDate)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Copy URL button (only when uploaded)
            // Action buttons container
            HStack(spacing: 8) {
                if showingDeleteAlert {
                    Button("Delete") {
                        Task {
                            await appState.deleteRecording(recording)
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)
                    
                    Button("Cancel") {
                        showingDeleteAlert = false
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .buttonStyle(.plain)
                } else {
                    // Trash / Delete button (always takes space but hides opacity)
                    Button {
                        showingDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .frame(width: 24, height: 24)
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || showingDeleteAlert ? 1 : 0)
                    .disabled(!isHovered && !showingDeleteAlert)
                    
                    if recording.shareURL != nil {
                        Button {
                            if let url = recording.shareURL {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    showCopied = false
                                }
                            }
                        } label: {
                            Image(systemName: showCopied ? "checkmark" : "link")
                                .font(.system(size: 11))
                                .foregroundStyle(showCopied ? .green : (isLinkHovered ? .blue : .secondary))
                                .frame(width: 24, height: 24)
                                .background(isLinkHovered ? Color.blue.opacity(0.1) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            isLinkHovered = hovering
                        }
                    }

                    // Upload status
                    uploadStatusIcon
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 4)
        .onHover { hovering in
            isHovered = hovering
        }
        .onReceive(timer) { input in
            uptime = input
        }
        .background(.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let shareURL = recording.shareURL {
                NSWorkspace.shared.open(shareURL)
            } else if FileManager.default.fileExists(atPath: recording.fileURL.path) {
                NSWorkspace.shared.open(recording.fileURL)
            }
        }
    }

    @ViewBuilder
    private var uploadStatusIcon: some View {
        switch recording.uploadStatus {
        case .notUploaded:
            Image(systemName: "icloud.slash")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        case .uploading:
            ProgressView()
                .controlSize(.small)
        case .uploaded:
            if showCloudIcon {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        case .failed:
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }
}
