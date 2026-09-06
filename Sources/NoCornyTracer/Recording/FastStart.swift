import Foundation
import AVFoundation

/// Puts the movie index (the `moov` atom) at the front of a finished recording.
///
/// AVAssetWriter leaves the index at the very end of the file, after all the frames, and
/// every shared recording paid for it on tracer.nocorny.com: the browser fetched the head
/// of the file, found no index, fetched the tail, and only then the actual video - 3 round
/// trips to Dropbox at about 1.5 s each before the first frame, 6 s cold on a 280 MB take.
///
/// Setting `shouldOptimizeForNetworkUse` on the live writer is not the fix. Measured on a
/// bench: with it the writer stages every byte in a sidecar file and copies it over in
/// `finishWriting`, which doubles the disk the recording needs and, on a nearly full disk,
/// leaves a truncated file whose index still claims the full duration - salvage would then
/// ship half a meeting as a whole one. So the index moves afterwards, in the finishing
/// phase, the way the system-audio merge already rewrites the file: export to a temp file
/// next to the recording, verify, swap. On any failure - or when there is not enough room
/// for the copy - the original stays exactly as it was; it plays either way, just slower
/// to start.
enum FastStart {

    /// Room the pass must find on the volume beyond what the export itself takes.
    static let headroom: Int64 = 256 * 1024 * 1024

    /// The export stages the whole `mdat` in a sidecar and then copies it into the output,
    /// so at its peak it holds 2 copies of the recording next to the original. Measured on
    /// a bench: 1.9x the file size, not 1x.
    static let copiesTheExportHolds: Int64 = 2

    /// Rewrites `recordingURL` in place. Returns true only when the file on disk was
    /// actually replaced.
    static func applyInPlace(recording recordingURL: URL) async -> Bool {
        let startedAt = Date()
        let name = recordingURL.lastPathComponent

        if (try? indexComesFirst(at: recordingURL)) == true {
            LogManager.shared.log("⏩ Fast start: \(name) already has its index at the front")
            return false
        }

        guard hasRoomToRewrite(fileAt: recordingURL) else {
            LogManager.shared.log("⏩ Fast start: skipping \(name) - not enough room on the volume for the rewrite. The file plays as it is.")
            return false
        }
        let workingDirectory = recordingURL.deletingLastPathComponent()
        let size = sizeOnDisk(of: recordingURL)

        let stem = recordingURL.deletingPathExtension().lastPathComponent
        let tempURL = workingDirectory.appendingPathComponent("\(stem)-faststart.mp4")
        // Next to the recording, not in /tmp: replaceItemAt wants both on one volume.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try? FileManager.default.removeItem(at: tempURL)

        do {
            let asset = AVURLAsset(url: recordingURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            // Passthrough: the samples are copied untouched, only the container is laid
            // out again. Seconds per gigabyte, no re-encode.
            let session = try SystemAudioMerger.makeExportSession(for: asset, preset: AVAssetExportPresetPassthrough)
            session.shouldOptimizeForNetworkUse = true
            if let error = await SystemAudioMerger.run(session, to: tempURL, as: .mp4) {
                throw error
            }
            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                throw FastStartError.exportProducedNoFile
            }
            guard try indexComesFirst(at: tempURL) else {
                throw FastStartError.indexStillLast
            }
            // A passthrough copy cannot be much smaller than its source; one that is has
            // dropped something, and the original is the safer file to keep.
            let copyAttrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
            let copySize = (copyAttrs[.size] as? NSNumber)?.int64Value ?? 0
            guard copySize >= size / 10 * 9 else {
                throw FastStartError.copyTooSmall(original: size, copy: copySize)
            }
            // Size cannot tell a missing audio track from a quiet one (the mic is 1-2% of
            // the file), so count the tracks as well.
            let originalTracks = try await tracksByType(of: asset)
            let copyTracks = try await tracksByType(of: AVURLAsset(url: tempURL))
            guard originalTracks == copyTracks else {
                throw FastStartError.tracksChanged(original: originalTracks, copy: copyTracks)
            }

            // The user may have deleted the take while the export ran. `replaceItemAt` on a
            // path that no longer exists simply puts the copy there - an orphan file that no
            // row points at - so a missing original ends the pass instead.
            guard FileManager.default.fileExists(atPath: recordingURL.path) else {
                throw FastStartError.originalGone
            }

            // The swap is the only destructive moment, after a complete, verified copy.
            let replaced = try FileManager.default.replaceItemAt(recordingURL, withItemAt: tempURL)
            if let replaced, replaced != recordingURL {
                try FileManager.default.moveItem(at: replaced, to: recordingURL)
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            LogManager.shared.log("⏩ Fast start: index moved to the front of \(name) in \(String(format: "%.1f", elapsed))s")
            return true
        } catch {
            LogManager.shared.log(
                "⏩ Fast start: pass failed for \(name) (\(error.localizedDescription)) - keeping the original, it plays as it is.",
                type: .error
            )
            return false
        }
    }

    /// Whether a network-optimised export of this file fits on its volume.
    ///
    /// Shared with the system-audio merge, which rewrites the same file the same way: the
    /// export stages the data in a sidecar and copies it into place, so it holds 2 copies
    /// at its peak. Without the room the answer is no and the caller writes the file the
    /// plain way - slower to start on the web, which is the cheaper thing to lose.
    static func hasRoomToRewrite(fileAt url: URL) -> Bool {
        let size = sizeOnDisk(of: url)
        guard size > 0 else { return false }
        let free = availableRoom(on: url.deletingLastPathComponent())
        let needed = size * copiesTheExportHolds + headroom
        if free <= needed {
            LogManager.shared.log(
                "⏩ Fast start: \(free / 1_048_576) MB free where \(url.lastPathComponent) lives, a network-optimised rewrite needs about \(needed / 1_048_576) MB (2 copies of \(size / 1_048_576) MB plus headroom)"
            )
            return false
        }
        return true
    }

    static func sizeOnDisk(of url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Free space for a new file next to `directory`. The "important usage" figure is the
    /// honest one on the boot volume (it counts what the system would purge for us), but
    /// on any other volume it comes back as 0, which would switch the pass off for everyone
    /// who keeps their Movies folder on an external disk. Fall back to the plain figure then.
    static func availableRoom(on directory: URL) -> Int64 {
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }

    /// Video and audio track counts, the two kinds a recording carries.
    private static func tracksByType(of asset: AVAsset) async throws -> [String: Int] {
        let tracks = try await asset.load(.tracks)
        var counts: [String: Int] = [:]
        for track in tracks {
            counts[track.mediaType.rawValue, default: 0] += 1
        }
        return counts
    }

    /// Walks the top-level atoms at the head of the file. `moov` before `mdat` means the
    /// index is first; `mdat` first means a player has to reach the end of the file for it.
    static func indexComesFirst(at url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        for _ in 0..<8 {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return false }
            let bytes = [UInt8](header)
            var size = bytes[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: bytes[4..<8], as: UTF8.self)
            if size == 1 {
                // 64-bit atom size, used for an mdat past 4 GB.
                guard bytes.count >= 16 else { return false }
                size = bytes[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            switch type {
            case "moov": return true
            case "mdat": return false
            default: break
            }
            // 0 means "to the end of the file": nothing follows, and no index was seen. A
            // size that runs past the file, or wraps, is a damaged header - also a no.
            guard size >= 8 else { return false }
            let (next, wrapped) = offset.addingReportingOverflow(size)
            guard !wrapped, next < fileSize else { return false }
            offset = next
        }
        return false
    }

    /// Removes what an interrupted pass or merge leaves behind: `<take>-faststart.mp4`, the
    /// merger's `<take>-merge.mp4` / `<take>-merge-audio.m4a`, and the `.sb-*` sidecars the
    /// export stages its data in. A force quit, a crash or the quit deadline can cut either
    /// one mid-copy, and nothing else in the app sweeps this folder. Files younger than
    /// `olderThan` are left alone: they may belong to a pass that is still running.
    @discardableResult
    static func sweepOrphans(in directory: URL, olderThan age: TimeInterval = 3600) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        let cutoff = Date().addingTimeInterval(-age)
        var removed = 0
        for name in names {
            let isLeftover = name.contains("-faststart.mp4") || name.contains("-merge.mp4") || name.contains("-merge-audio.m4a")
            guard isLeftover else { continue }
            let url = directory.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            guard modified < cutoff else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        if removed > 0 {
            LogManager.shared.log("⏩ Fast start: swept \(removed) leftover file(s) from an interrupted pass or merge")
        }
        return removed
    }
}

enum FastStartError: LocalizedError {
    case exportProducedNoFile
    case indexStillLast
    case copyTooSmall(original: Int64, copy: Int64)
    case tracksChanged(original: [String: Int], copy: [String: Int])
    case originalGone

    var errorDescription: String? {
        switch self {
        case .exportProducedNoFile: return "The export reported success but wrote no file"
        case .indexStillLast: return "The export still left the index at the end of the file"
        case let .copyTooSmall(original, copy): return "The copy is \(copy) bytes against \(original) in the original"
        case let .tracksChanged(original, copy): return "The copy carries tracks \(copy) against \(original) in the original"
        case .originalGone: return "The recording was deleted while the pass ran"
        }
    }
}
