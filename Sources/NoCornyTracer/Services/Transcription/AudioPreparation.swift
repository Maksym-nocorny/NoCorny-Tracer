import Foundation
import AVFoundation
import CoreMedia

/// Turning a finished recording into audio an engine can transcribe: extract, measure
/// speech, drop silence, cut chunks.
///
/// Every engine consumes the same artifacts, so this had to leave AINamingService before
/// a second engine could exist. `encodeSpeechAudio` and `buildChunkAudio` live together
/// on purpose -- they share one set of 32 kbps encoder settings and the entire
/// request-size budget is derived from that number, so splitting them would let the two
/// drift apart silently.
enum AudioPreparation {

    /// Audio chunks at or below this RMS in dBFS are silence for trim purposes.
    static let trimSilenceThresholdDBFS: Float = -45

    /// Hard cutoff for skip-if-silent: only fire when the file is essentially mute.
    static let skipSilenceThresholdDBFS: Float = -50

    /// If ≥95% of the audio is below skipSilenceThresholdDBFS, skip transcription entirely.
    static let skipSilenceCoverage: Float = 0.95

    /// Builds one chunk's audio as a composition over the original extracted track, encoded
    /// with the same 32 kbps/16 kHz/mono settings as the full-file path.
    static func buildChunkAudio(sourceAsset: AVAsset, sourceTrack: AVAssetTrack, plan: PlannedChunk) async -> AudioChunk? {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            LogManager.shared.log("🤖 Chunk \(plan.index): ❌ Could not add composition track", type: .error)
            return nil
        }

        // Integer sample counts at a 16 kHz timescale — exact, no float drift.
        let timeScale: CMTimeScale = 16000
        var mapping: [TimestampMapping] = []
        var local = 0

        for r in plan.ranges {
            guard r.length > 0 else { continue }
            do {
                try track.insertTimeRange(
                    CMTimeRange(
                        start: CMTime(value: CMTimeValue(r.start), timescale: timeScale),
                        duration: CMTime(value: CMTimeValue(r.length), timescale: timeScale)
                    ),
                    of: sourceTrack,
                    at: CMTime(value: CMTimeValue(local), timescale: timeScale)
                )
            } catch {
                LogManager.shared.log("🤖 Chunk \(plan.index): ❌ insertTimeRange failed: \(error.localizedDescription)", type: .error)
                return nil
            }
            mapping.append(TimestampMapping(
                stitchedStartSamples: local,
                stitchedEndSamples: local + r.length,
                originalStartSamples: r.start
            ))
            local += r.length
        }

        guard local > 0 else { return nil }

        let compositionTracks: [AVAssetTrack]
        do {
            compositionTracks = try await composition.loadTracks(withMediaType: .audio)
        } catch {
            LogManager.shared.log("🤖 Chunk \(plan.index): ❌ loadTracks failed: \(error.localizedDescription)", type: .error)
            return nil
        }
        guard let compTrack = compositionTracks.first,
              let url = await encodeSpeechAudio(from: composition, sourceTrack: compTrack) else {
            LogManager.shared.log("🤖 Chunk \(plan.index): ❌ Encode failed", type: .error)
            return nil
        }

        return AudioChunk(
            index: plan.index,
            url: url,
            mapping: mapping,
            localDuration: Double(local) / 16000.0,
            speechSeconds: plan.speechSeconds,
            speedupFactor: 1.0
        )
    }

    /// Reads the compressed m4a as PCM, computes per-100ms RMS, and groups active chunks
    /// into speech segments. All bookkeeping is in integer sample counts to avoid float drift.
    static func analyzeSpeech(audioURL: URL) async -> SpeechAnalysis {
        return await Task.detached(priority: .userInitiated) {
            guard let file = try? AVAudioFile(forReading: audioURL) else {
                return SpeechAnalysis(totalDuration: 0, totalSpeechDuration: 0, segments: [], silenceCoverage: 1.0, shouldSkipTranscription: true)
            }

            let format = file.processingFormat
            let totalFrames = AVAudioFramePosition(file.length)
            let sampleRate = format.sampleRate
            let totalDuration = Double(totalFrames) / sampleRate
            let chunkSamples = Int(sampleRate * 0.1)

            guard chunkSamples > 0, totalFrames > 0 else {
                return SpeechAnalysis(totalDuration: totalDuration, totalSpeechDuration: 0, segments: [], silenceCoverage: 1.0, shouldSkipTranscription: true)
            }

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkSamples)) else {
                return SpeechAnalysis(totalDuration: totalDuration, totalSpeechDuration: 0, segments: [], silenceCoverage: 1.0, shouldSkipTranscription: true)
            }

            var rmsByChunk: [Float] = []
            do {
                while file.framePosition < totalFrames {
                    let remaining = totalFrames - file.framePosition
                    let toRead = AVAudioFrameCount(min(AVAudioFramePosition(chunkSamples), remaining))
                    buffer.frameLength = 0
                    try file.read(into: buffer, frameCount: toRead)
                    let count = Int(buffer.frameLength)
                    guard count > 0, let channelData = buffer.floatChannelData else { break }

                    var sumSquares: Float = 0
                    let ptr = channelData[0]
                    for i in 0..<count {
                        let v = ptr[i]
                        sumSquares += v * v
                    }
                    let mean = sumSquares / Float(count)
                    let rms = sqrt(max(mean, 1e-12))
                    let dbfs = 20 * log10(rms)
                    rmsByChunk.append(dbfs)
                }
            } catch {
                return SpeechAnalysis(totalDuration: totalDuration, totalSpeechDuration: 0, segments: [], silenceCoverage: 1.0, shouldSkipTranscription: true)
            }

            // Skip-if-silent coverage check.
            let silentChunks = rmsByChunk.filter { $0 < AudioPreparation.skipSilenceThresholdDBFS }.count
            let silenceCoverage = rmsByChunk.isEmpty ? 1.0 : Float(silentChunks) / Float(rmsByChunk.count)
            let skipDueToSilence = silenceCoverage >= AudioPreparation.skipSilenceCoverage

            // Group consecutive active chunks into raw segments.
            let activeMask = rmsByChunk.map { $0 > AudioPreparation.trimSilenceThresholdDBFS }
            var rawSegments: [(start: Int, end: Int)] = []
            var i = 0
            while i < activeMask.count {
                if activeMask[i] {
                    let start = i * chunkSamples
                    var j = i
                    while j < activeMask.count && activeMask[j] { j += 1 }
                    let end = min(j * chunkSamples, Int(totalFrames))
                    rawSegments.append((start, end))
                    i = j
                } else {
                    i += 1
                }
            }

            // Merge adjacent (gap < 800ms).
            let mergeGapSamples = Int(sampleRate * 0.8)
            var merged: [(Int, Int)] = []
            for seg in rawSegments {
                if let last = merged.last, seg.start - last.1 < mergeGapSamples {
                    merged[merged.count - 1] = (last.0, seg.end)
                } else {
                    merged.append(seg)
                }
            }

            // Drop short (< 300ms).
            let minSegmentSamples = Int(sampleRate * 0.3)
            let filtered = merged.filter { $0.1 - $0.0 >= minSegmentSamples }

            // Add 200ms padding each side.
            let paddingSamples = Int(sampleRate * 0.2)
            let padded: [(Int, Int)] = filtered.map { seg in
                let s = max(0, seg.0 - paddingSamples)
                let e = min(Int(totalFrames), seg.1 + paddingSamples)
                return (s, e)
            }

            // Merge overlapping after padding.
            var final: [(Int, Int)] = []
            for seg in padded {
                if let last = final.last, seg.0 <= last.1 {
                    final[final.count - 1] = (last.0, max(last.1, seg.1))
                } else {
                    final.append(seg)
                }
            }

            let segments = final.map { SpeechSegment(startSamples: $0.0, endSamples: $0.1) }
            let totalSpeechSamples = segments.reduce(0) { $0 + ($1.endSamples - $1.startSamples) }
            let totalSpeechDuration = Double(totalSpeechSamples) / sampleRate

            let shouldSkip = skipDueToSilence || segments.isEmpty || totalSpeechDuration < 1.0

            return SpeechAnalysis(
                totalDuration: totalDuration,
                totalSpeechDuration: totalSpeechDuration,
                segments: segments,
                silenceCoverage: silenceCoverage,
                shouldSkipTranscription: shouldSkip
            )
        }.value
    }

    /// Builds an AVMutableComposition that contains only the speech segments and exports
    /// it as m4a. Returns nil (caller falls back to original) when trimming wouldn't help
    /// or any AV step fails.
    static func stitchSpeechAudio(audioURL: URL, segments: [SpeechSegment], originalDuration: Double) async -> StitchResult? {
        guard !segments.isEmpty else { return nil }

        let speechSeconds = segments.reduce(0.0) { $0 + ($1.endSeconds - $1.startSeconds) }

        if originalDuration > 0 {
            let speechFraction = speechSeconds / originalDuration
            if speechFraction > 0.95 {
                LogManager.shared.log("🤖 Trim: Speech covers >95% of audio — skipping trim (no benefit)")
                return nil
            }
            if speechFraction < 0.05 {
                LogManager.shared.log("🤖 Trim: Speech covers <5% of audio — falling back to original")
                return nil
            }
        }
        if speechSeconds < 5.0 {
            LogManager.shared.log("🤖 Trim: Stitched audio would be < 5s — skipping trim (transcription quality concern)")
            return nil
        }

        let asset = AVAsset(url: audioURL)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            LogManager.shared.log("🤖 Trim: ❌ loadTracks failed: \(error.localizedDescription)", type: .error)
            return nil
        }
        guard let sourceTrack = audioTracks.first else {
            LogManager.shared.log("🤖 Trim: ❌ No audio track in source", type: .error)
            return nil
        }

        let timeScale: CMTimeScale = 16000
        var mapping: [TimestampMapping] = []
        var stitchedSamples = 0

        for seg in segments {
            let segDurationSamples = seg.endSamples - seg.startSamples
            if segDurationSamples <= 0 { continue }

            let sourceStart = CMTime(value: CMTimeValue(seg.startSamples), timescale: timeScale)
            let sourceDur = CMTime(value: CMTimeValue(segDurationSamples), timescale: timeScale)
            let insertionTime = CMTime(value: CMTimeValue(stitchedSamples), timescale: timeScale)

            do {
                try track.insertTimeRange(
                    CMTimeRange(start: sourceStart, duration: sourceDur),
                    of: sourceTrack,
                    at: insertionTime
                )
            } catch {
                LogManager.shared.log("🤖 Trim: ❌ insertTimeRange failed: \(error.localizedDescription)", type: .error)
                return nil
            }

            mapping.append(TimestampMapping(
                stitchedStartSamples: stitchedSamples,
                stitchedEndSamples: stitchedSamples + segDurationSamples,
                originalStartSamples: seg.startSamples
            ))
            stitchedSamples += segDurationSamples
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            LogManager.shared.log("🤖 Trim: ❌ Could not create AVAssetExportSession", type: .error)
            return nil
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        await exportSession.export()

        if exportSession.status == .completed {
            return StitchResult(url: outputURL, mapping: mapping)
        } else {
            LogManager.shared.log("🤖 Trim: ❌ Export failed: \(exportSession.error?.localizedDescription ?? "unknown")", type: .error)
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    /// Speeds up the audio by `factor` while preserving pitch (spectral algorithm).
    /// Returns nil on any failure — caller continues with the slower copy.
    static func applySpeedUp(audioURL: URL, factor: Double) async -> URL? {
        let asset = AVAsset(url: audioURL)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch { return nil }
        guard let sourceTrack = audioTracks.first else { return nil }

        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        do {
            try track.insertTimeRange(timeRange, of: sourceTrack, at: .zero)
        } catch {
            LogManager.shared.log("🤖 Speedup: ❌ insertTimeRange failed: \(error.localizedDescription)", type: .error)
            return nil
        }
        let scaledDuration = CMTimeMultiplyByFloat64(asset.duration, multiplier: 1.0 / factor)
        track.scaleTimeRange(timeRange, toDuration: scaledDuration)

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.audioTimePitchAlgorithm = .spectral
        await exportSession.export()

        if exportSession.status == .completed {
            return outputURL
        } else {
            LogManager.shared.log("🤖 Speedup: ❌ Export failed: \(exportSession.error?.localizedDescription ?? "unknown")", type: .error)
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    /// Extracts the audio track and re-encodes it as a tiny m4a (32 kbps mono 16 kHz) for
    /// transcription. Independent of the video's audio quality — the original audio in the
    /// recorded MP4 is untouched. 16 kHz mono is the format speech models expect; 32 kbps
    /// keeps even hour-long videos under Gemini's 20 MB inline-data limit.
    static func extractCompressedAudio(from videoURL: URL) async -> URL? {
        let asset = AVAsset(url: videoURL)

        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            LogManager.shared.log("🤖 Subtitles: ❌ Failed to load audio tracks: \(error.localizedDescription)", type: .error)
            return nil
        }
        guard let audioTrack = audioTracks.first else {
            LogManager.shared.log("🤖 Subtitles: ❌ Video has no audio track", type: .error)
            return nil
        }

        return await encodeSpeechAudio(from: asset, sourceTrack: audioTrack)
    }

    /// Encodes `asset`'s audio to a tiny m4a (32 kbps mono 16 kHz).
    ///
    /// Split out of `extractCompressedAudio` so chunk compositions reuse the EXACT same
    /// encoder settings. `AVAssetExportSession` with `AVAssetExportPresetAppleM4A` — the
    /// obvious alternative — does not preserve them, and the whole payload budget is derived
    /// from that 32 kbps figure, so pinning it here keeps the size math true by construction.
    ///
    /// `sourceTrack` must belong to `asset` (works for both a file-backed AVAsset and an
    /// AVMutableComposition).
    static func encodeSpeechAudio(from asset: AVAsset, sourceTrack: AVAssetTrack) async -> URL? {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .m4a)
        } catch {
            LogManager.shared.log("🤖 Subtitles: ❌ Could not create AVAssetWriter: \(error.localizedDescription)", type: .error)
            return nil
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            LogManager.shared.log("🤖 Subtitles: ❌ AVAssetWriter cannot accept input", type: .error)
            return nil
        }
        writer.add(writerInput)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            LogManager.shared.log("🤖 Subtitles: ❌ Could not create AVAssetReader: \(error.localizedDescription)", type: .error)
            return nil
        }

        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: readerOutputSettings)
        guard reader.canAdd(readerOutput) else {
            LogManager.shared.log("🤖 Subtitles: ❌ AVAssetReader cannot accept output", type: .error)
            return nil
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            LogManager.shared.log("🤖 Subtitles: ❌ AVAssetReader failed to start: \(reader.error?.localizedDescription ?? "unknown")", type: .error)
            return nil
        }
        guard writer.startWriting() else {
            LogManager.shared.log("🤖 Subtitles: ❌ AVAssetWriter failed to start: \(writer.error?.localizedDescription ?? "unknown")", type: .error)
            return nil
        }
        writer.startSession(atSourceTime: .zero)

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.nocorny.tracer.audio-export", qos: .userInitiated)
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        if !writerInput.append(buffer) {
                            LogManager.shared.log("🤖 Subtitles: ❌ AVAssetWriter append failed: \(writer.error?.localizedDescription ?? "unknown")", type: .error)
                            writerInput.markAsFinished()
                            writer.finishWriting {
                                continuation.resume(returning: nil)
                            }
                            return
                        }
                    } else {
                        // copyNextSampleBuffer returned nil. This is EITHER true EOF OR a mid-stream
                        // reader failure (e.g. a corrupt/truncated source). Treat a .failed reader as
                        // an error — finalizing here would write a SILENTLY TRUNCATED file and report
                        // success, so Gemini would transcribe a fragment. Only .reading / .completed /
                        // .cancelled count as a normal end-of-stream.
                        if reader.status == .failed {
                            LogManager.shared.log("🤖 Subtitles: ❌ Audio reader failed mid-stream: \(reader.error?.localizedDescription ?? "unknown") — discarding partial audio", type: .error)
                            writerInput.markAsFinished()
                            writer.cancelWriting()
                            try? FileManager.default.removeItem(at: outputURL)
                            continuation.resume(returning: nil)
                            return
                        }
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume(returning: outputURL)
                            } else {
                                LogManager.shared.log("🤖 Subtitles: ❌ Finalization failed: \(writer.error?.localizedDescription ?? "unknown") (status \(writer.status.rawValue))", type: .error)
                                continuation.resume(returning: nil)
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}
