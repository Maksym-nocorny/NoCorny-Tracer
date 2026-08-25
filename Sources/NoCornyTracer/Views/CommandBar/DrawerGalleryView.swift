import SwiftUI
import AppKit

/// The Gallery drawer of the command bar (Figma 59:3; empty state 87:708;
/// signed-out 87:561). A fixed 560×332 glass sheet that morphs open under the bar —
/// it does not move on its own, the panel is one surface.
struct DrawerGalleryView: View {
    @Bindable var appState: AppState

    var body: some View {
        Group {
            if appState.tracerAPIClient.isSignedIn {
                signedInContent
            } else {
                DrawerSignedOutView(appState: appState)
            }
        }
        .frame(
            width: Theme.Metrics.drawerSize.width,
            height: Theme.Metrics.drawerSize.height
        )
        .glassSurface(cornerRadius: DrawerStyle.cornerRadius)
        .floatingPanelShadow()
    }

    // MARK: Signed in — header / list / footer

    private var signedInContent: some View {
        VStack(spacing: 0) {
            header

            if appState.recordings.isEmpty {
                emptyState
            } else {
                recordingList
            }

            DrawerFooterView(appState: appState)
        }
        .padding(.leading, DrawerStyle.leadingInset)
        .padding(.trailing, DrawerStyle.trailingInset)
        .padding(.top, DrawerStyle.topInset)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Recent")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DrawerStyle.ink(0.9))

            Text("\(appState.recordings.count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DrawerStyle.ink(0.7))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(DrawerStyle.ink(0.1)))

            Spacer(minLength: 8)

            Button {
                appState.openTracerDashboard()
            } label: {
                Text("Library ↗")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.5))
            }
            .buttonStyle(.plain)
            .help("Open the full library on tracer.nocorny.com")
            .pointerOnHover()
        }
        .padding(.bottom, 8)
        .padding(.trailing, 4)
    }

    private var recordingList: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 6) {
                ForEach(appState.recordings) { recording in
                    DrawerRecordingRow(appState: appState, recording: recording)
                }
            }
            .padding(.trailing, 4)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    // MARK: Empty state (87:708; mark redrawn native per verdict 24.08)

    @State private var emptyMarkHovering = false

    private var emptyState: some View {
        VStack(spacing: 10) {
            // The smaller round record mark — and a real button: the empty state's
            // whole message is "hit record", so the mark starts a take like the
            // bar's big one does (isRecording then morphs the panel to the pill).
            Button {
                Task { try? await appState.startRecording() }
            } label: {
                RecordRingMark(diameter: 44, isSpinning: emptyMarkHovering)
            }
            .buttonStyle(.plain)
            .scaleEffect(emptyMarkHovering ? 1.05 : 1)
            .animation(Theme.Anim.hover, value: emptyMarkHovering)
            .onHover { emptyMarkHovering = $0 }
            .help("Start recording")
            .pointerOnHover()
            .padding(.bottom, 4)

            Text("No recordings yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DrawerStyle.ink(0.88))

            Text("Hit ⌥⇧R — your first clip lands here,\nnamed by AI and synced to Dropbox.")
                .font(.system(size: 11.5))
                .foregroundStyle(DrawerStyle.ink(0.45))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Recording row

/// One row of the Gallery drawer (Figma 59:58): thumbnail, name, meta line, and the
/// two independent status axes (upload / transcription) on the right — logic ported
/// from the old RecordingsListView (deleted in phase 6b). Clicking the row copies
/// the share link; right-click opens the row's context menu.
private struct DrawerRecordingRow: View {
    @Bindable var appState: AppState
    let recording: Recording

    @State private var showCopied = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 11) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(recording.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DrawerStyle.ink(0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(metaLine)
                    .font(.system(size: 11))
                    .foregroundStyle(DrawerStyle.ink(0.45))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if showCopied {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Colors.statusGreen)
                    Text("Copied")
                        .font(.system(size: 9))
                        .foregroundStyle(DrawerStyle.ink(0.45))
                }
            } else {
                speakersActivity
                transcriptionStatus
                uploadStatus
            }
        }
        .padding(.leading, 9)
        .padding(.trailing, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DrawerStyle.rowCornerRadius, style: .continuous)
                .fill(isHovered && recording.canCopyLink ? DrawerStyle.ink(0.08) : DrawerStyle.rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DrawerStyle.rowCornerRadius, style: .continuous)
                .strokeBorder(DrawerStyle.rowStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DrawerStyle.rowCornerRadius, style: .continuous))
        // A gesture rather than wrapping the row in a Button: the retry controls on the
        // right are buttons of their own, and nesting them inside one would swallow them.
        .onTapGesture { copyLink() }
        .onHover { hovering in
            isHovered = hovering
            if hovering && recording.canCopyLink {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(recording.canCopyLink ? "Click to copy the share link" : "No link yet — the recording hasn't uploaded")
        .contextMenu { rowContextMenu }
    }

    // MARK: Context menu (phase 6b — system menu, no macro)

    /// Right-click actions for a row. Everything here is a second door to an action
    /// that already exists elsewhere, plus the per-recording speaker correction that
    /// lost its only UI when phase 6b deleted the orphaned RecordingsListView — the
    /// "Speakers" submenu is that control's compensation (same reapplySpeakers call,
    /// same gates), pending the phase-8 design blessing.
    ///
    /// Inapplicable actions are shown disabled rather than hidden (macOS convention:
    /// a stable menu is scannable; items that come and go read as missing features).
    /// The Speakers submenu is the exception — it appears only when a re-run is
    /// possible at all, exactly like the old control did.
    @ViewBuilder
    private var rowContextMenu: some View {
        Button("Copy link") { copyLink() }
            .disabled(!recording.canCopyLink)

        Button("Open on web") {
            if let url = tracerPageURL { NSWorkspace.shared.open(url) }
        }
        .disabled(tracerPageURL == nil)

        Divider()

        Button("Retry upload") {
            Task { await appState.retryUpload(recording) }
        }
        // Same set retryUpload itself accepts: .notUploaded counts (a processing task
        // that died with the process never left that state).
        .disabled(recording.uploadStatus != .failed && recording.uploadStatus != .notUploaded)

        Button("Retry transcription") {
            appState.retryTranscription(recording)
        }
        .disabled(recording.effectiveTranscriptionStatus != .failed
                  || appState.retryingTranscriptions.contains(recording.id))

        if canReapplySpeakers {
            Divider()
            Menu("Speakers") {
                ForEach(ExpectedSpeakers.quickPickChoices(including: currentSpeakers)) { choice in
                    // A plain Button, not a Picker: re-picking the CURRENT value must
                    // still fire — that is how a failed re-run is retried (the old
                    // control's contract, kept on purpose).
                    Button {
                        Task { await appState.reapplySpeakers(recordingID: recording.id, expected: choice) }
                    } label: {
                        if choice == currentSpeakers {
                            Label(choice.shortName, systemImage: "checkmark")
                        } else {
                            Text(choice.shortName)
                        }
                    }
                }
            }
            .disabled(appState.reapplyingSpeakers.contains(recording.id))
        }

        Divider()

        // The one destructive action, last and behind a confirmation — the old list's
        // Delete lost its only door when phase 6b removed that list.
        Button("Delete…", role: .destructive) {
            confirmDelete()
        }
    }

    /// NSAlert rather than SwiftUI .alert for the same reason as the Problem Reports
    /// consent dialog: the drawer sits on a borderless nonactivating panel, where
    /// sheet-style alerts have nothing reliable to attach to. The drawer is only open
    /// outside a recording, so the activation NSAlert brings is fine. The text mirrors
    /// what `deleteRecording` will actually do: the server + Dropbox copy goes only for
    /// a registered recording while signed in; otherwise only the local file goes.
    private func confirmDelete() {
        let deletesFromServer = recording.tracerSlug != nil && appState.tracerAPIClient.isSignedIn
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \u{201C}\(recording.displayName)\u{201D}?"
        alert.informativeText = deletesFromServer
            ? "Deletes this recording from Tracer and Dropbox. This cannot be undone."
            : "Deletes the local file. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Task { await appState.deleteRecording(recording) }
        }
    }

    /// "Open on web" means the tracer page specifically — no Dropbox fallback here,
    /// unlike `shareURL` (a share link and "where this recording lives on the site"
    /// are different questions).
    private var tracerPageURL: URL? {
        recording.tracerURL.flatMap(URL.init(string:))
    }

    private var currentSpeakers: ExpectedSpeakers {
        recording.expectedSpeakers ?? appState.expectedSpeakers
    }

    /// Port of the deleted RecordingsListView.canReapplySpeakers: a re-run needs all
    /// three — the plan includes separation, a transcript to re-label, and the audio
    /// to re-run against (still cached here, or in Dropbox). Anything less and the
    /// submenu would be a control that fails.
    private var canReapplySpeakers: Bool {
        guard appState.tracerAPIClient.entitlements.diarization else { return false }
        guard recording.hasTranscript else { return false }
        return DiarizationAudioCache.shared.hasMicAudio(for: recording.id)
            || recording.diarizationMicPath != nil
    }

    /// Compact echo of a speaker re-run in the row itself: a mini spinner while it
    /// works, and on failure a small alert glyph whose tooltip carries the full
    /// sentence from `speakerReapplyErrors` (the drawer row has no room for the old
    /// list's inline error text).
    @ViewBuilder
    private var speakersActivity: some View {
        if appState.reapplyingSpeakers.contains(recording.id) {
            ProgressView()
                .controlSize(.mini)
                .help("Re-labelling speakers…")
        } else if let failure = appState.speakerReapplyErrors[recording.id] {
            Image(systemName: "person.2.slash")
                .font(.system(size: 11))
                .foregroundStyle(TranscriptionStatusCluster.failedAlert)
                .help(failure)
        }
    }

    // MARK: Link copy (gate: shareURL == nil → inert)

    private func copyLink() {
        guard let url = recording.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showCopied = false
        }
    }

    // MARK: Thumbnail (62×42, r9)

    private var thumbnail: some View {
        ZStack {
            if let path = recording.dropboxPath {
                DropboxThumbnailView(path: path, appState: appState)
            } else {
                RoundedRectangle(cornerRadius: DrawerStyle.thumbCornerRadius, style: .continuous)
                    .fill(DrawerStyle.thumbFill)
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(DrawerStyle.ink(0.5))
            }
        }
        .frame(width: 62, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: DrawerStyle.thumbCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DrawerStyle.thumbCornerRadius, style: .continuous)
                .strokeBorder(DrawerStyle.ink(0.1), lineWidth: 1)
        )
    }

    // MARK: Meta line ("612 MB · 41:05 · Today, 11:20")

    private var metaLine: String {
        var parts: [String] = []
        if !recording.formattedFileSize.isEmpty {
            parts.append(recording.formattedFileSize)
        }
        parts.append(recording.formattedDuration)
        parts.append(Self.drawerDate(recording.createdAt))
        return parts.joined(separator: " · ")
    }

    /// The macro's date style: "Today, 11:20" / "Yesterday, 18:05" / "Aug 18, 14:32".
    /// Older dates reuse Recording.formattedDate so the two formats never diverge.
    static func drawerDate(_ date: Date, now: Date = Date()) -> String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let time = timeFormatter.string(from: date)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }

    // MARK: Status axes

    /// The transcription axis (Figma 533:1606) — the shared spark cluster.
    private var transcriptionStatus: some View {
        TranscriptionStatusCluster(appState: appState, recording: recording)
    }

    @ViewBuilder
    private var uploadStatus: some View {
        switch recording.uploadStatus {
        case .notUploaded:
            Image(systemName: "icloud.slash")
                .font(.system(size: 11))
                .foregroundStyle(DrawerStyle.ink(0.45))
        case .uploading:
            if let fraction = appState.uploadProgress[recording.id] {
                HStack(spacing: 5) {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                        .frame(width: 44)
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(DrawerStyle.ink(0.45))
                }
                .help("Uploading to Dropbox")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        case .uploaded:
            // Persistent in the drawer (macro shows a status on every row), unlike the
            // old list's 5-second transient tick.
            Image(systemName: "checkmark.icloud.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Colors.statusGreen)
        case .failed:
            Button {
                Task { await appState.retryUpload(recording) }
            } label: {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.recordRed)
            }
            .buttonStyle(.plain)
            .help(recording.uploadError ?? "Upload failed — click to retry")
            .pointerOnHover()
        }
    }
}

// MARK: - Signed out (87:561)

/// The signed-out drawer body: person mark, pitch, Google sign-in, and the local
/// waiting-clips line. Replaces the whole drawer content, not just the list.
struct DrawerSignedOutView: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(DrawerStyle.ink(0.8))

            Text("Sign in to sync & share")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(DrawerStyle.ink(0.95))

            Text("Record freely — clips wait on this Mac\nand fly to Dropbox once you're in.")
                .font(.system(size: 12))
                .foregroundStyle(DrawerStyle.ink(0.5))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            DrawerGoogleSignInButton(appState: appState)

            if let error = appState.tracerAPIClient.errorMessage {
                Text(error)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Colors.recordRed)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.Colors.pausedAmber)
                    .frame(width: 7, height: 7)
                Text("Not signed in · \(waitingLine)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DrawerStyle.ink(0.5))
            }
            .padding(.top, 22)
        }
        .padding(.top, 40)
        .padding(.bottom, 20)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var waitingLine: String {
        let count = LocalClipQueue.waitingCount(recordings: appState.recordings) {
            FileManager.default.fileExists(atPath: $0.path)
        }
        return count == 1 ? "1 clip waiting locally" : "\(count) clips waiting locally"
    }
}
