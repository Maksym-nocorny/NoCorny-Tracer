import Foundation

/// Where a recording's transcript lives on disk.
///
/// It used to live inside the `Recording` value itself, which meant it rode along in the
/// JSON blob `AppState.saveRecordings()` writes to `UserDefaults`. Two things made that
/// untenable at the same time: the library sync started filling the transcript for every row
/// in the account, and processing one recording calls `updateRecording` about fourteen times,
/// each of which re-encodes and rewrites the whole array. A hundred and fifty meetings is
/// several megabytes of speech rewritten fourteen times per recording, sitting in plaintext
/// in `~/Library/Preferences` where nothing ever expects to find someone's conversations.
///
/// A file per recording fixes all three at once: the list stays small, a write touches one
/// transcript rather than the library, and the text is in Application Support with the rest
/// of the recording's data instead of in the preferences plist.
final class TranscriptStore {
    static let shared = TranscriptStore()

    let root: URL
    private let fileManager = FileManager.default

    /// Injectable so tests can point at a temporary directory rather than the user's library.
    init(root: URL = TranscriptStore.defaultRoot) {
        self.root = root
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
    }

    func url(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).srt")
    }

    /// True without reading the file. The Recordings list asks this once per row per render
    /// pass, and reading a 60 KB transcript to answer "is there one" would be the same
    /// mistake in a different place.
    func hasTranscript(for id: UUID) -> Bool {
        fileManager.fileExists(atPath: url(for: id).path)
    }

    /// An empty file is the same answer as no file, so callers only ever have two cases.
    func load(for id: UUID) -> String? {
        guard let text = try? String(contentsOf: url(for: id), encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    /// Saving nothing removes the file rather than leaving an empty one behind, so `load`
    /// and `hasTranscript` never disagree.
    func save(_ srt: String?, for id: UUID) {
        guard let srt, !srt.isEmpty else {
            remove(for: id)
            return
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try srt.write(to: url(for: id), atomically: true, encoding: .utf8)
        } catch {
            // The transcript is also on the server and in the recording's Dropbox folder, so
            // a failed local write costs a re-fetch, not the transcript.
            LogManager.shared.log(
                "📝 Transcript store: ❌ could not keep the transcript: \(error.localizedDescription)",
                type: .error
            )
        }
    }

    func remove(for id: UUID) {
        try? fileManager.removeItem(at: url(for: id))
    }
}
