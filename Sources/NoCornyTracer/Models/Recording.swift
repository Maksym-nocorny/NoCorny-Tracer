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
