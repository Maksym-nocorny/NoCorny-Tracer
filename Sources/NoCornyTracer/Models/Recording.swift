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
    /// Where transcription stands for this recording, persisted so a run interrupted by a
    /// quit is a visible `.failed` on the next launch rather than a green tick over nothing.
    /// Optional ON PURPOSE: `loadRecordings` decodes with `try?`, so a non-optional field
    /// would silently wipe the entire history of anyone upgrading from an older build.
    /// Read `effectiveTranscriptionStatus`, which derives an answer for rows written before
    /// this field existed.
    var transcriptionStatus: TranscriptionStatus?
    /// Why the last transcription attempt failed, in words meant for the row's tooltip.
    /// Nil whenever `transcriptionStatus` is not `.failed`.
    var transcriptionError: String?

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

    /// Where transcription stands, with an answer even for rows that predate the persisted
    /// field: a transcript in hand (in the store, or still inline in a legacy row that has
    /// not been migrated yet) means the work was done; no field and no transcript means it
    /// was never attempted as far as this recording knows.
    var effectiveTranscriptionStatus: TranscriptionStatus {
        if let transcriptionStatus { return transcriptionStatus }
        if hasTranscript || legacyInlineTranscript?.isEmpty == false { return .done }
        return .idle
    }

    /// True while transcription is claimed by a live run. The pair shows up together
    /// everywhere activity matters: the pills, the server reconcile's do-not-clobber rule,
    /// and the stranded-at-launch check are all asking this one question.
    var isTranscriptionActive: Bool {
        transcriptionStatus == .queued || transcriptionStatus == .transcribing
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
        case transcriptionStatus, transcriptionError
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
        try container.encodeIfPresent(transcriptionStatus, forKey: .transcriptionStatus)
        try container.encodeIfPresent(transcriptionError, forKey: .transcriptionError)
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

    /// Whether a click has anything to copy — the drawer row's link-copy gate.
    /// Mirrors `shareURL`'s priority (tracer page → Dropbox link → legacy Drive).
    var canCopyLink: Bool {
        shareURL != nil
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

/// The transcription axis, independent of `UploadStatus` on purpose: a recording uploads
/// and transcribes on separate tracks, and one word cannot say "uploaded fine, transcript
/// failed". `idle` rather than `none`, so `Recording.transcriptionStatus` -- an Optional of
/// this type -- never reads as `.none` meaning two different things in a switch.
enum TranscriptionStatus: String, Codable {
    /// Never attempted (auto-upload off, or the recording predates transcription).
    case idle
    /// A run owns this recording and has not produced its first progress yet.
    case queued
    /// The engine is audibly working: at least one progress callback has arrived.
    case transcribing
    /// A transcript (or a legitimate "nothing was said") is in hand.
    case done
    /// The run ended with nothing. `transcriptionError` says why; retry is on offer.
    case failed
}
