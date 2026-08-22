import Foundation
import AVFoundation
import CoreMedia

/// Folds the system-audio sidecar back into the recording once capture has stopped, so
/// the saved MP4 plays with everything audible.
///
/// A recording where the far end of the call is missing from playback is the whole
/// problem we set out to fix, and every player that matters here (QuickTime, the browser
/// on tracer.nocorny.com) plays exactly one audio track. So the two tracks that were kept
/// apart on disk get mixed into one for the file people actually watch - offline, after
/// the fact, where a slow encode costs patience instead of a desynced take.
enum SystemAudioMerger {

    /// Rewrites `recordingURL` in place with mic + system audio mixed into a single
    /// track. Returns true only when the file on disk was actually replaced; on any
    /// failure the original recording is left exactly as it was.
    static func mergeInPlace(recording recordingURL: URL, systemAudio sidecarURL: URL) async -> Bool {
        let startedAt = Date()
        let workingDirectory = recordingURL.deletingLastPathComponent()
        let stem = recordingURL.deletingPathExtension().lastPathComponent
        let mixedAudioURL = workingDirectory.appendingPathComponent("\(stem)-merge-audio.m4a")
        let mergedURL = workingDirectory.appendingPathComponent("\(stem)-merge.mp4")

        // Temp files live next to the recording rather than in /tmp: replaceItemAt wants
        // both items on the same volume, and the recordings folder is the one place we
        // already know is writable for this user.
        defer {
            try? FileManager.default.removeItem(at: mixedAudioURL)
            try? FileManager.default.removeItem(at: mergedURL)
        }
        try? FileManager.default.removeItem(at: mixedAudioURL)
        try? FileManager.default.removeItem(at: mergedURL)

        do {
            let options = [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            let recordingAsset = AVURLAsset(url: recordingURL, options: options)
            let sidecarAsset = AVURLAsset(url: sidecarURL, options: options)

            guard let videoTrack = try await recordingAsset.loadTracks(withMediaType: .video).first else {
                throw MergeError.noVideoTrack
            }
            guard let systemTrack = try await sidecarAsset.loadTracks(withMediaType: .audio).first else {
                throw MergeError.noSystemAudioTrack
            }
            let micTrack = try await recordingAsset.loadTracks(withMediaType: .audio).first

            let videoRange = try await videoTrack.load(.timeRange)

            // Step 1: mix the audio only. Both files share t=0, and each track is
            // inserted at its own start time inside that shared timeline, so whatever
            // small head offset a track has (first mic buffer after the anchor, first
            // system buffer after the anchor) survives the mix instead of being
            // flattened to zero and pulling one source ahead of the other.
            let audioComposition = AVMutableComposition()
            var mixedMicIn = false
            if let micTrack {
                mixedMicIn = try await insert(micTrack, into: audioComposition)
            }
            guard try await insert(systemTrack, into: audioComposition) else {
                throw MergeError.noSystemAudioTrack
            }

            let mixDown = try makeExportSession(for: audioComposition, preset: AVAssetExportPresetAppleM4A)
            mixDown.timeRange = CMTimeRange(start: .zero, duration: audioComposition.duration)
            if let error = await run(mixDown, to: mixedAudioURL, as: .m4a) {
                throw error
            }

            // Step 2: put the mixed track back next to the untouched video. Passthrough
            // because the video is already H.264 at the size the user asked for - a
            // re-encode here would cost minutes and quality to change nothing.
            let mixedAsset = AVURLAsset(url: mixedAudioURL, options: options)
            guard let mixedTrack = try await mixedAsset.loadTracks(withMediaType: .audio).first else {
                throw MergeError.mixdownProducedNoAudio
            }
            let mixedRange = try await mixedTrack.load(.timeRange)

            let finalComposition = AVMutableComposition()
            guard let videoDestination = finalComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let audioDestination = finalComposition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw MergeError.compositionTrackUnavailable
            }
            try videoDestination.insertTimeRange(videoRange, of: videoTrack, at: videoRange.start)
            // Audio never outlives the picture: capture stops for both at once, so a
            // longer audio range means a rounding tail, not content worth keeping. The
            // mixed track starts at the recording's zero, so the picture's end time is
            // the cap.
            let audioDuration = min(mixedRange.duration, videoRange.end)
            try audioDestination.insertTimeRange(
                CMTimeRange(start: mixedRange.start, duration: audioDuration),
                of: mixedTrack,
                at: .zero
            )

            let assemble = try makeExportSession(for: finalComposition, preset: AVAssetExportPresetPassthrough)
            if let error = await run(assemble, to: mergedURL, as: .mp4) {
                throw error
            }

            guard FileManager.default.fileExists(atPath: mergedURL.path) else {
                throw MergeError.exportProducedNoFile
            }

            // The swap is the only destructive moment, and it happens after a complete,
            // verified export - so a failure anywhere above leaves the mic-only
            // recording on disk, which is what the app produced before this feature.
            let replaced = try FileManager.default.replaceItemAt(recordingURL, withItemAt: mergedURL)
            if let replaced, replaced != recordingURL {
                // Documented as possible: the swap may hand the file back at a different
                // location. Everything downstream only knows the original path.
                try FileManager.default.moveItem(at: replaced, to: recordingURL)
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            LogManager.shared.log(
                "🔊 System audio: merged into \(recordingURL.lastPathComponent) in \(String(format: "%.1f", elapsed))s (mic track: \(mixedMicIn ? "yes" : "none"))"
            )
            return true
        } catch {
            LogManager.shared.log(
                "🔊 System audio: merge failed (\(error.localizedDescription)) - keeping the original recording untouched. Sidecar stays at \(sidecarURL.lastPathComponent).",
                type: .error
            )
            return false
        }
    }

    // MARK: - Helpers

    /// Returns false for a track that holds nothing - a recording made with the mic off
    /// still carries an audio track that was never fed, and it deserves no place in the mix.
    private static func insert(_ track: AVAssetTrack, into composition: AVMutableComposition) async throws -> Bool {
        let range = try await track.load(.timeRange)
        guard range.duration > .zero else { return false }
        guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergeError.compositionTrackUnavailable
        }
        try destination.insertTimeRange(range, of: track, at: range.start)
        return true
    }

    private static func makeExportSession(for asset: AVAsset, preset: String) throws -> AVAssetExportSession {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MergeError.exportSessionUnavailable
        }
        return session
    }

    /// Runs an export and returns the failure, if any. macOS 15 replaced the whole
    /// callback API; the app still supports 14, so both paths stay until the floor moves.
    private static func run(_ session: AVAssetExportSession, to url: URL, as fileType: AVFileType) async -> Error? {
        if #available(macOS 15.0, *) {
            do {
                try await session.export(to: url, as: fileType)
                return nil
            } catch {
                return error
            }
        }

        session.outputURL = url
        session.outputFileType = fileType
        return await withCheckedContinuation { continuation in
            session.exportAsynchronously {
                if session.status == .completed {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: session.error ?? MergeError.exportFailed)
                }
            }
        }
    }
}

enum MergeError: LocalizedError {
    case noVideoTrack
    case noSystemAudioTrack
    case compositionTrackUnavailable
    case exportSessionUnavailable
    case mixdownProducedNoAudio
    case exportProducedNoFile
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The recording has no video track to merge into"
        case .noSystemAudioTrack: return "The system audio sidecar has no audio track"
        case .compositionTrackUnavailable: return "Could not create a composition track"
        case .exportSessionUnavailable: return "Could not create an export session"
        case .mixdownProducedNoAudio: return "The audio mixdown produced no audio track"
        case .exportProducedNoFile: return "The export reported success but wrote no file"
        case .exportFailed: return "The export failed"
        }
    }
}
