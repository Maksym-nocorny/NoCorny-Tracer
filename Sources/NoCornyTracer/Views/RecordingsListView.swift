import SwiftUI

/// List of recent recordings with upload status and actions
struct RecordingsListView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Recordings")
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
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "video.slash")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No recordings yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appState.recordings.prefix(10)) { recording in
                            RecordingRowView(recording: recording)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            
            if appState.dropboxAuthManager.isSignedIn && appState.dropboxAllocatedSpace > 0 {
                storageBarView
                    .padding(.horizontal)
                    .padding(.top, 4)
            }
        }
    }
    
    @ViewBuilder
    private var storageBarView: some View {
        let used = Double(appState.dropboxUsedSpace)
        let allocated = Double(appState.dropboxAllocatedSpace)
        let remaining = max(0, allocated - used)
        let percentLeft = remaining / allocated
        
        // approx 46 MB per minute = 46 * 1024 * 1024 bytes
        let approxMinutes = remaining / (46.0 * 1024 * 1024)
        let isLowSpace = percentLeft < 0.2
        
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Dropbox Storage")
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text("~\(Int(approxMinutes)) min left")
                    .font(.system(size: 10))
            }
            .foregroundStyle(isLowSpace ? .red : .secondary)
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isLowSpace ? Color.red : Color.blue)
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(used / allocated))), height: 4)
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Recording Row

struct RecordingRowView: View {
    let recording: Recording
    @State private var showCopied = false
    @State private var isLinkHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Play icon / thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .frame(width: 40, height: 28)

                Image(systemName: "play.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

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

                    Text(recording.formattedDate)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Copy URL button (only when uploaded)
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
                        .animation(.easeInOut(duration: 0.15), value: isLinkHovered)
                        .animation(.easeInOut(duration: 0.2), value: showCopied)
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isLinkHovered = hovering
                }
                .overlay(alignment: .top) {
                    if showCopied {
                        Text("Copied!")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.8))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .offset(y: -28)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .animation(.easeOut(duration: 0.2), value: showCopied)
                    }
                }
            }

            // Upload status
            uploadStatusIcon
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
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
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.icloud.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
        }
    }
}
