import Foundation
import AVFoundation

/// Keeps, per recording, the audio that a re-run of speaker separation needs.
///
/// Separation used to be a question asked before recording, because the local file is deleted
/// the moment the upload finishes and nothing was left to re-run against. Keeping the audio is
/// what turns "how many people?" into something the user answers after reading the transcript,
/// which is the only moment they actually know the answer.
///
/// What we keep is deliberately not what was recorded. Diarization downsamples to 16 kHz mono
/// before it looks at a single sample, so storing the mic track at recording quality or the
/// system sidecar at its captured 128 kbps stereo 48 kHz would be paying about four times over
/// for audio the models throw away. Both files here are the same 32 kbps mono 16 kHz m4a the
/// transcription path already produces: roughly 14 MB per hour per track.
///
/// Eviction below is a disk-space policy, never an availability one. Every file kept here also
/// goes to the recording's own Dropbox folder, so an evicted, reinstalled or moved-to-another-Mac
/// cache costs a download, not the feature.
final class DiarizationAudioCache {
    static let shared = DiarizationAudioCache()

    /// Which of the two tracks a file holds. The raw value is the filename because the layout
    /// is a contract with the Dropbox copy: the same two names land in the recording's folder.
    enum Kind: String, CaseIterable {
        case mic = "mic.m4a"
        case system = "system.m4a"

        var filename: String { rawValue }
    }

    /// One cached recording, as the eviction pass sees it.
    struct Entry {
        let recordingID: UUID
        let bytes: UInt64
        /// Newest modification date across the entry's files. Downloading a file back from
        /// Dropbox rewrites it, so an entry a re-run just needed stops looking old.
        let lastModified: Date
    }

    let root: URL
    private let maxBytes: UInt64
    private let maxAge: TimeInterval
    private let fileManager = FileManager.default

    /// Injectable so the eviction rule can be tested against a temporary directory instead of
    /// the user's real cache.
    init(
        root: URL = DiarizationAudioCache.defaultRoot,
        maxBytes: UInt64 = 2 * 1024 * 1024 * 1024,
        maxAge: TimeInterval = 90 * 24 * 60 * 60
    ) {
        self.root = root
        self.maxBytes = maxBytes
        self.maxAge = maxAge
    }

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
            .appendingPathComponent("DiarizationAudio", isDirectory: true)
    }

    // MARK: - Layout

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(_ kind: Kind, for id: UUID) -> URL {
        directory(for: id).appendingPathComponent(kind.filename)
    }

    /// The path only when something is actually on disk at it, so callers never hand a
    /// diarizer a URL to a file eviction removed.
    func existingURL(_ kind: Kind, for id: UUID) -> URL? {
        let candidate = url(kind, for: id)
        return fileManager.fileExists(atPath: candidate.path) ? candidate : nil
    }

    func urls(for id: UUID) -> (mic: URL?, system: URL?) {
        (existingURL(.mic, for: id), existingURL(.system, for: id))
    }

    /// A re-run needs the mic track at minimum: the system sidecar alone describes the far end
    /// and has nothing to say about the words the user spoke.
    func hasMicAudio(for id: UUID) -> Bool {
        existingURL(.mic, for: id) != nil
    }

    // MARK: - Storing

    /// Takes ownership of `source` and moves it into the cache. A move rather than a copy
    /// because every caller here has just produced the file in the temporary directory; on
    /// failure the source is deleted rather than left behind as an orphaned 15 MB of temp.
    @discardableResult
    func install(_ source: URL, as kind: Kind, for id: UUID) -> URL? {
        let destination = url(kind, for: id)
        do {
            try fileManager.createDirectory(at: directory(for: id), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: source)
            LogManager.shared.log("🎛️ Diarization cache: ❌ could not keep \(kind.filename): \(error.localizedDescription)", type: .error)
            return nil
        }
    }

    /// Re-encodes the raw `-system.m4a` sidecar down to the format the models consume before
    /// keeping it. The sidecar is captured at 128 kbps stereo 48 kHz for the mixdown into the
    /// MP4; that is roughly four times the bytes of what diarization will actually read.
    func storeSystemAudio(from sidecar: URL, for id: UUID) async -> URL? {
        guard fileManager.fileExists(atPath: sidecar.path) else { return nil }

        let asset = AVAsset(url: sidecar)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            LogManager.shared.log("🎛️ Diarization cache: ❌ could not read the system sidecar: \(error.localizedDescription)", type: .error)
            return nil
        }
        guard let track = tracks.first,
              let encoded = await AudioPreparation.encodeSpeechAudio(from: asset, sourceTrack: track) else {
            return nil
        }
        return install(encoded, as: .system, for: id)
    }

    // MARK: - Removing

    func remove(for id: UUID) {
        try? fileManager.removeItem(at: directory(for: id))
    }

    // MARK: - Accounting

    func entries() -> [Entry] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [Entry] = []
        for child in children {
            guard let id = UUID(uuidString: child.lastPathComponent) else { continue }
            var bytes: UInt64 = 0
            var newest = Date.distantPast
            for kind in Kind.allCases {
                let file = child.appendingPathComponent(kind.filename)
                guard let attributes = try? fileManager.attributesOfItem(atPath: file.path) else { continue }
                bytes += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                if let modified = attributes[.modificationDate] as? Date, modified > newest {
                    newest = modified
                }
            }
            guard bytes > 0 else { continue }
            result.append(Entry(recordingID: id, bytes: bytes, lastModified: newest))
        }
        return result.sorted { $0.lastModified < $1.lastModified }
    }

    func totalBytes() -> UInt64 {
        entries().reduce(0) { $0 + $1.bytes }
    }

    /// Drops anything past its ninetieth day, then the oldest entries until the cache fits its
    /// budget. Returns what it removed so the caller (and the tests) can see the decision
    /// rather than infer it from a directory listing.
    @discardableResult
    func evict(now: Date = Date()) -> [UUID] {
        var surviving = entries()
        var evicted: [UUID] = []

        let expired = surviving.filter { now.timeIntervalSince($0.lastModified) > maxAge }
        for entry in expired {
            remove(for: entry.recordingID)
            evicted.append(entry.recordingID)
        }
        surviving.removeAll { entry in expired.contains { $0.recordingID == entry.recordingID } }

        var total = surviving.reduce(UInt64(0)) { $0 + $1.bytes }
        var index = 0
        while total > maxBytes, index < surviving.count {
            let entry = surviving[index]
            remove(for: entry.recordingID)
            evicted.append(entry.recordingID)
            total -= min(total, entry.bytes)
            index += 1
        }

        if !evicted.isEmpty {
            let expiredCount = expired.count
            LogManager.shared.log(
                "🎛️ Diarization cache: evicted \(evicted.count) recording(s) - \(expiredCount) past 90 days, \(evicted.count - expiredCount) over the size budget; \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)) left"
            )
        }
        return evicted
    }
}
