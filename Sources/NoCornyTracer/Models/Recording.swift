import Foundation

/// Represents a single screen recording
struct Recording: Identifiable, Codable {
    let id: UUID
    let fileURL: URL
    let createdAt: Date
    var duration: TimeInterval
    var aiGeneratedName: String?
    var uploadStatus: UploadStatus
    var driveFileID: String?
    var thumbnailData: Data?

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
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "Recording_\(formatter.string(from: createdAt))"
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    /// Google Drive URL for the uploaded video
    var driveURL: URL? {
        guard let fileID = driveFileID else { return nil }
        return URL(string: "https://drive.google.com/file/d/\(fileID)/view")
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: createdAt)
    }
}

enum UploadStatus: String, Codable {
    case notUploaded
    case uploading
    case uploaded
    case failed
}
