import Foundation

/// Pure math behind the "~N min left" footer figure. The formula used to live inline
/// in MainView's footer; now both that footer and the command-bar drawer footer call
/// this one place, so the two can't drift apart.
enum DropboxQuota {
    /// Approximate bytes one minute of recording occupies (the long-standing
    /// footer constant: 19.5 MB per minute of 1080p30).
    static let bytesPerMinute: Double = 19.5 * 1024 * 1024

    /// Whole minutes of recording that still fit into the quota, rounded down.
    /// Zero when the allocation is unknown (0) or already exhausted — never negative.
    static func minutesLeft(used: UInt64, allocated: UInt64) -> Int {
        guard allocated > 0 else { return 0 }
        let remaining = max(0, Double(allocated) - Double(used))
        return Int(remaining / bytesPerMinute)
    }
}

/// The signed-out drawer's "N clips waiting locally": recordings that still hold a
/// local file on this Mac and have not made it to Dropbox yet. Pure over an injected
/// file-existence check so the count is testable without touching the disk.
enum LocalClipQueue {
    static func waitingCount(recordings: [Recording], fileExists: (URL) -> Bool) -> Int {
        recordings
            .filter { $0.uploadStatus != .uploaded && fileExists($0.fileURL) }
            .count
    }
}
