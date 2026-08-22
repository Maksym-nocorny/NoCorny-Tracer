import Foundation

/// Represents a single screen recording
struct Recording: Identifiable, Codable {
    let id: UUID
    let fileURL: URL
    let createdAt: Date
    var duration: TimeInterval
    var aiGeneratedName: String?
    var uploadStatus: UploadStatus
    var driveFileID: String?       // Legacy: old Google Drive file ID (kept for backward compat)
    var dropboxPath: String?       // Dropbox file path (e.g. "/videos/xFel134/video.mp4")
    var dropboxFolder: String?     // Slug-keyed folder, e.g. "/videos/xFel134" — cached so retry across launches uploads to the same place.
    var dropboxSharedURL: String?  // Dropbox shared link URL
    var tracerSlug: String?        // Short slug on tracer.nocorny.com (e.g. "xFel134")
    var tracerURL: String?         // Full public URL on tracer.nocorny.com
    var thumbnailURL: String?      // Public Dropbox URL for the generated JPG thumbnail
    var thumbnailData: Data?
    var fileSize: UInt64?
    var uploadCompletedAt: Date?
    var uploadError: String?
    /// The transcript as an older build cached it: inline, and therefore inside the JSON blob
    /// that `AppState.saveRecordings()` writes to `UserDefaults`. Decoded so `loadRecordings`
    /// can move it into `TranscriptStore` once, never encoded again -- see `encode(to:)`.
    /// Read `transcript` instead; this is nil for every recording since the migration ran.
    var legacyInlineTranscript: String?
    /// Which engine produced the transcript. Kept for support: "the transcript is bad"
    /// is a different bug depending on the answer.
    var transcriptEngine: String?
    /// Sidecar file holding the system audio of this recording, when it was captured.
    /// The MP4 already plays everything mixed; this keeps the far end on its own track,
    /// which is what speaker separation will want to work from.
    /// Optional with a default so an older cached recordings list still decodes.
    var systemAudioURL: URL?
    /// Durable copies of the two 16 kHz tracks speaker separation re-runs from, sitting in this
    /// recording's own Dropbox folder. The local cache is the fast path; these are what make a
    /// re-run survive cache eviction, a reinstall, or a different Mac.
    /// Optional with a default so an older cached recordings list still decodes.
    var diarizationMicPath: String?
    var diarizationSystemPath: String?
    /// The headcount the current speaker labels were produced with, so the Recordings list can
    /// show what was assumed rather than what the settings happen to say today.
    /// Optional with a default so an older cached recordings list still decodes.
    var expectedSpeakers: ExpectedSpeakers?

    // MARK: - Transcript

    /// This recording's transcript, read from the file store. The text is deliberately not
    /// carried in the value: a `Recording` is re-encoded into `UserDefaults` on every state
    /// change, and an hour of speech has no business being rewritten fourteen times because
    /// an upload's byte counter moved.
    var transcript: String? {
        TranscriptStore.shared.load(for: id)
    }

    /// Whether there is a transcript at all, without reading it back off disk.
    var hasTranscript: Bool {
        TranscriptStore.shared.hasTranscript(for: id)
    }

    // MARK: - Codable
    //
    // Hand-written on the encode side only. The decode side stays synthesized, so an older
    // cached list still hands us its inline transcript for migration, while `encode(to:)`
    // makes it structurally impossible for a transcript to end up back in the preferences
    // plist -- which is the whole point, and not something a convention would survive.

    enum CodingKeys: String, CodingKey {
        case id, fileURL, createdAt, duration, aiGeneratedName, uploadStatus
        case driveFileID, dropboxPath, dropboxFolder, dropboxSharedURL
        case tracerSlug, tracerURL, thumbnailURL, thumbnailData, fileSize
        case uploadCompletedAt, uploadError
        case legacyInlineTranscript = "transcriptSrt"
        case transcriptEngine, systemAudioURL
        case diarizationMicPath, diarizationSystemPath, expectedSpeakers
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(fileURL, forKey: .fileURL)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(aiGeneratedName, forKey: .aiGeneratedName)
        try container.encode(uploadStatus, forKey: .uploadStatus)
        try container.encodeIfPresent(driveFileID, forKey: .driveFileID)
        try container.encodeIfPresent(dropboxPath, forKey: .dropboxPath)
        try container.encodeIfPresent(dropboxFolder, forKey: .dropboxFolder)
        try container.encodeIfPresent(dropboxSharedURL, forKey: .dropboxSharedURL)
        try container.encodeIfPresent(tracerSlug, forKey: .tracerSlug)
        try container.encodeIfPresent(tracerURL, forKey: .tracerURL)
        try container.encodeIfPresent(thumbnailURL, forKey: .thumbnailURL)
        try container.encodeIfPresent(thumbnailData, forKey: .thumbnailData)
        try container.encodeIfPresent(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(uploadCompletedAt, forKey: .uploadCompletedAt)
        try container.encodeIfPresent(uploadError, forKey: .uploadError)
        try container.encodeIfPresent(transcriptEngine, forKey: .transcriptEngine)
        try container.encodeIfPresent(systemAudioURL, forKey: .systemAudioURL)
        try container.encodeIfPresent(diarizationMicPath, forKey: .diarizationMicPath)
        try container.encodeIfPresent(diarizationSystemPath, forKey: .diarizationSystemPath)
        try container.encodeIfPresent(expectedSpeakers, forKey: .expectedSpeakers)
        // legacyInlineTranscript is deliberately absent: transcripts live in TranscriptStore.
    }

    init(
        id: UUID = UUID(),
        fileURL: URL,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        aiGeneratedName: String? = nil,
        uploadStatus: UploadStatus = .notUploaded
    ) {
        self.id = id
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.duration = duration
        self.aiGeneratedName = aiGeneratedName
        self.uploadStatus = uploadStatus
    }

    var displayName: String {
        if let aiName = aiGeneratedName, !aiName.isEmpty {
            return aiName
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Recording_\(formatter.string(from: createdAt))"
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Shared URL for the uploaded video.
    /// Prefers the Tracer web page (tracer.nocorny.com/v/{slug}) when available,
    /// falls back to the raw Dropbox shared link, then legacy Google Drive.
    var shareURL: URL? {
        if let tracerURL = tracerURL, let url = URL(string: tracerURL) {
            return url
        }
        if let sharedURL = dropboxSharedURL {
            return URL(string: sharedURL)
        }
        // Legacy fallback for old Google Drive recordings
        if let fileID = driveFileID {
            return URL(string: "https://drive.google.com/file/d/\(fileID)/view")
        }
        return nil
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: createdAt)
    }

    var formattedFileSize: String {
        guard let size = fileSize else { return "" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }
}

enum UploadStatus: String, Codable {
    case notUploaded
    case uploading
    case uploaded
    case failed
}
