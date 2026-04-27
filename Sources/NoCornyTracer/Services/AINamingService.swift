import Foundation
import AVFoundation
import AppKit
import CoreMedia
import ImageIO

/// Uses Google Gemini (via Cloudflare proxy) to generate descriptive names for screen recordings
final class AINamingService {

    // MARK: - Configuration

    private let proxyClient = GeminiProxyClient()

    // MARK: - Name Generation

    /// Generates a descriptive name using evenly spaced frames and the subtitle transcript
    func generateName(for videoURL: URL, subtitles: String?) async -> String? {
        LogManager.shared.log("🤖 AI Naming: Starting for \(videoURL.lastPathComponent)")

        // Extract paragraph-anchored frames (or evenly spaced if no transcript)
        let frames = await extractFrames(from: videoURL, subtitles: subtitles)
        guard !frames.isEmpty else {
            LogManager.shared.log("🤖 AI Naming: ❌ Failed to extract any frames", type: .error)
            return nil
        }
        LogManager.shared.log("🤖 AI Naming: ✅ Extracted \(frames.count) frames")

        let prompt = """
        Review these screenshots taken from a screen recording. \
        \(subtitles != nil ? "Also, here is the spoken transcript for context:\n\n" + subtitles! : "")

        Generate a detailed, descriptive filename (5-10 words, no file extension) \
        that specifically describes the code, application, or topic shown. \
        Focus on the concrete details of what the user is actually doing. \
        If the transcript contains stray phrases that don't fit the visual context (song lyrics, background TV dialogue, side conversations), ignore them and base the name on what is actually shown on screen. \
        Use title case. Examples: "Fixing Google Sign-In Crash in Swift", "Slack Team Discussion on Q1 Roadmap", "Analytics Dashboard Overview for Revenue". \
        Return ONLY the filename, nothing else.
        """

        // Retry with exponential backoff on ANY error (was: only quota errors)
        let maxRetries = 3
        var delay: UInt64 = 5_000_000_000 // 5 seconds

        for attempt in 1...maxRetries {
            do {
                LogManager.shared.log("🤖 AI Naming: Calling Gemini proxy (attempt \(attempt)/\(maxRetries))...")
                let text = try await proxyClient.generateWithImages(prompt: prompt, images: frames)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                LogManager.shared.log("🤖 AI Naming: ✅ Raw response: \"\(text)\"")
                let cleaned = text
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: ".mp4", with: "")
                    .replacingOccurrences(of: ".mov", with: "")
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                LogManager.shared.log("🤖 AI Naming: ✅ Cleaned name: \"\(cleaned)\"")
                return cleaned.isEmpty ? nil : cleaned

            } catch {
                let errorString = "\(error)"
                if attempt < maxRetries {
                    LogManager.shared.log("🤖 AI Naming: ⏳ Attempt \(attempt) failed (\(errorString)), retrying in \(delay / 1_000_000_000)s...", type: .error)
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                LogManager.shared.log("🤖 AI Naming: ❌ All \(maxRetries) attempts failed. Last error: \(errorString)", type: .error)
                return nil
            }
        }

        return nil
    }

    // MARK: - Subtitle Generation

    /// Generates SRT subtitles by extracting the audio track and sending it to Gemini
    func generateSubtitles(for videoURL: URL) async -> String? {
        LogManager.shared.log("🤖 Subtitles: Extracting compressed audio from video...")
        guard let audioURL = await extractCompressedAudio(from: videoURL) else {
            LogManager.shared.log("🤖 Subtitles: ❌ Failed to extract audio", type: .error)
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        guard let audioData = try? Data(contentsOf: audioURL) else {
            LogManager.shared.log("🤖 Subtitles: ❌ Failed to read extracted audio file at \(audioURL.path)", type: .error)
            return nil
        }

        let sizeKB = audioData.count / 1024
        LogManager.shared.log("🤖 Subtitles: Compressed audio size: \(sizeKB)KB")

        // 20MB hard limit for Gemini inline data. With 32 kbps mono re-encoding,
        // this fits roughly 85 minutes of audio — long enough for almost any recording.
        guard audioData.count < 20_000_000 else {
            LogManager.shared.log("🤖 Subtitles: ❌ Audio too large (\(audioData.count / 1_000_000)MB > 20MB) — video likely exceeds 80 minutes", type: .error)
            return nil
        }

        LogManager.shared.log("🤖 Subtitles: Sending \(sizeKB)KB to Gemini proxy for transcription...")

        let prompt = """
        Transcribe ONLY the primary, foreground speaker — the person actively narrating this screen recording. Do NOT transcribe:
        - Background voices from TV, radio, podcasts, or videos playing nearby
        - Song lyrics or vocal music
        - Distant, muffled, or overlapping voices that aren't the main speaker
        - Side conversations from other people in the room

        If a span of audio has no clear primary speaker, skip it. If the entire audio has no clear primary speaker, return "NO_SPEECH".

        Output the transcription in SRT subtitle format. Each subtitle should be 1-2 sentences, with accurate timestamps. Use this exact format:

        1
        00:00:00,000 --> 00:00:03,000
        First subtitle text here.

        2
        00:00:03,000 --> 00:00:06,000
        Second subtitle text here.

        Return ONLY the SRT content, nothing else. If there is no qualifying speech, return "NO_SPEECH".
        """

        // Retry with exponential backoff on ANY error (was: only quota errors).
        // Network glitches, 5xx, transient proxy errors all benefit from retry.
        let maxRetries = 3
        var delay: UInt64 = 5_000_000_000

        for attempt in 1...maxRetries {
            do {
                LogManager.shared.log("🤖 Subtitles: Calling Gemini proxy (attempt \(attempt)/\(maxRetries))...")
                let text = try await proxyClient.generateWithAudio(prompt: prompt, audioData: audioData)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                LogManager.shared.log("🤖 Subtitles: ✅ Got response (\(text.count) chars)")
                if text == "NO_SPEECH" || text.isEmpty {
                    LogManager.shared.log("🤖 Subtitles: No speech detected")
                    return nil
                }
                let cleaned = text
                    .replacingOccurrences(of: "```srt\n", with: "")
                    .replacingOccurrences(of: "```srt", with: "")
                    .replacingOccurrences(of: "```\n", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned

            } catch {
                let errorString = "\(error)"
                if attempt < maxRetries {
                    LogManager.shared.log("🤖 Subtitles: ⏳ Attempt \(attempt) failed (\(errorString)), retrying in \(delay / 1_000_000_000)s...", type: .error)
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                LogManager.shared.log("🤖 Subtitles: ❌ All \(maxRetries) attempts failed. Last error: \(errorString)", type: .error)
                return nil
            }
        }

        return nil
    }

    // MARK: - Media Extraction Helpers

    /// Extracts the audio track and re-encodes it as a tiny m4a (32 kbps mono 16 kHz) for
    /// transcription. This is independent of the video's audio quality — the original audio
    /// in the recorded MP4 is untouched. 16 kHz mono is the format speech models expect
    /// internally; 32 kbps comfortably keeps even hour-long videos under Gemini's 20 MB
    /// inline-data limit.
    private func extractCompressedAudio(from videoURL: URL) async -> URL? {
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

        // Decode source to 16 kHz 16-bit mono PCM, then the writer re-encodes to AAC.
        let readerOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 16_000,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: readerOutputSettings)
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
                        // No more input samples → finalize.
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

    /// Extracts frames at smart timestamps: anchored to transcript paragraph starts when speech
    /// is present, otherwise evenly spaced. Near-duplicate frames are removed via perceptual hash.
    private func extractFrames(from videoURL: URL, subtitles: String?) async -> [Data] {
        let asset = AVAsset(url: videoURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)

        guard durationSeconds > 0 else { return [] }

        let timestamps = pickTimestamps(duration: durationSeconds, subtitles: subtitles)
        guard !timestamps.isEmpty else { return [] }
        LogManager.shared.log("🤖 AI Naming: Picked \(timestamps.count) timestamps: \(timestamps.map { String(format: "%.1f", $0) }.joined(separator: ", "))s")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1568, height: 1568)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let times: [NSValue] = timestamps.map { ts in
            NSValue(time: CMTime(seconds: ts, preferredTimescale: 600))
        }

        let timesCount = times.count
        let rendered: [(timestamp: Double, data: Data)] = await withCheckedContinuation { continuation in
            var results: [(Double, Data)] = []
            var processedCount = 0
            let lock = NSLock()

            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, image, actualTime, result, error in
                if result == .succeeded, let cgImage = image {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    if let tiffData = nsImage.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                        let ts = CMTimeGetSeconds(requestedTime)
                        lock.lock()
                        results.append((ts, jpegData))
                        lock.unlock()
                    }
                }

                lock.lock()
                processedCount += 1
                let done = processedCount == timesCount
                lock.unlock()

                if done {
                    let sorted = results.sorted { $0.0 < $1.0 }
                    continuation.resume(returning: sorted.map { (timestamp: $0.0, data: $0.1) })
                }
            }
        }

        let deduped = deduplicate(frames: rendered, hammingThreshold: 5)
        if deduped.count != rendered.count {
            LogManager.shared.log("🤖 AI Naming: Deduped \(rendered.count) → \(deduped.count) frames")
        }
        return deduped
    }

    // MARK: - Timestamp Selection

    private struct SrtSegment {
        let start: Double
        let end: Double
        let text: String
    }

    /// Picks frame timestamps based on duration and optional transcript.
    /// - Returns: ascending array of seconds.
    private func pickTimestamps(duration: Double, subtitles: String?) -> [Double] {
        guard duration > 0 else { return [] }

        // Very short clips → single frame
        if duration < 1 {
            return [duration / 2]
        }

        // Target: min 3, max 10, ~1 per 10 seconds
        let n = max(3, min(10, Int(ceil(duration / 10.0))))

        // Equispaced fallback timestamps (midpoints of equal slices)
        let interval = duration / Double(n)
        var equispaced = (0..<n).map { interval * Double($0) + (interval / 2) }
        // Force first frame near the start so the model sees the opening context
        if !equispaced.isEmpty {
            equispaced[0] = min(equispaced[0], 0.5)
        }

        // No subtitles → equispaced
        guard let srt = subtitles, !srt.isEmpty else {
            return equispaced
        }

        let segments = parseSrt(srt)
        let paragraphStarts = paragraphStartTimes(from: segments)

        // Not enough paragraphs to anchor every target → equispaced
        guard paragraphStarts.count >= n else {
            return equispaced
        }

        // Snap each equispaced target to the nearest unused paragraph start within ±8s
        let snapWindow = 8.0
        var picked: [Double] = []
        var usedParagraphIdx: Set<Int> = []

        for target in equispaced {
            var bestIdx: Int?
            var bestDist = snapWindow + 0.001
            for (idx, pStart) in paragraphStarts.enumerated() where !usedParagraphIdx.contains(idx) {
                let dist = abs(pStart - target)
                if dist <= snapWindow && dist < bestDist {
                    bestDist = dist
                    bestIdx = idx
                }
            }
            if let idx = bestIdx {
                picked.append(paragraphStarts[idx])
                usedParagraphIdx.insert(idx)
            } else {
                picked.append(target)
            }
        }

        return picked.sorted()
    }

    // MARK: - SRT Parsing

    private func parseSrt(_ srt: String) -> [SrtSegment] {
        let normalized = srt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let blocks = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var segments: [SrtSegment] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2 else { continue }

            let timeLineIdx = lines[0].contains("-->") ? 0 : 1
            guard timeLineIdx < lines.count else { continue }
            let timeLine = lines[timeLineIdx]

            let pattern = #"([\d:,.]+)\s*-->\s*([\d:,.]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: timeLine, range: NSRange(timeLine.startIndex..., in: timeLine)),
                  let startRange = Range(match.range(at: 1), in: timeLine),
                  let endRange = Range(match.range(at: 2), in: timeLine) else {
                continue
            }

            let start = parseSrtTimestamp(String(timeLine[startRange]))
            let end = parseSrtTimestamp(String(timeLine[endRange]))

            let text = lines.dropFirst(timeLineIdx + 1)
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            segments.append(SrtSegment(start: start, end: end, text: text))
        }
        return segments
    }

    private func parseSrtTimestamp(_ ts: String) -> Double {
        let trimmed = ts.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d+):(\d+):(\d+)[,.](\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return 0
        }
        func capture(_ idx: Int) -> String {
            guard let r = Range(match.range(at: idx), in: trimmed) else { return "0" }
            return String(trimmed[r])
        }
        let h = Double(capture(1)) ?? 0
        let m = Double(capture(2)) ?? 0
        let s = Double(capture(3)) ?? 0
        var msStr = capture(4)
        while msStr.count < 3 { msStr += "0" }
        msStr = String(msStr.prefix(3))
        let ms = Double(msStr) ?? 0
        return h * 3600 + m * 60 + s + ms / 1000
    }

    /// Group SRT segments into paragraphs (port of web `groupIntoParagraphs`):
    /// boundary = gap > 1.5s OR previous segment ends with sentence punctuation.
    private func paragraphStartTimes(from segments: [SrtSegment]) -> [Double] {
        guard !segments.isEmpty else { return [] }
        let gapThreshold = 1.5
        let sentenceTerminators: Set<Character> = [".", "!", "?"]

        var starts: [Double] = [segments[0].start]
        for i in 1..<segments.count {
            let prev = segments[i - 1]
            let curr = segments[i]
            let gap = curr.start - prev.end
            let endsSentence: Bool = {
                let trimmed = prev.text.trimmingCharacters(in: .whitespaces)
                guard let last = trimmed.last else { return false }
                return sentenceTerminators.contains(last)
            }()
            if gap > gapThreshold || endsSentence {
                starts.append(curr.start)
            }
        }
        return starts
    }

    // MARK: - Perceptual Hash Dedup

    /// Returns frame data sorted by timestamp, with near-duplicates removed.
    /// Guarantees at least `min(3, input.count)` frames in the output.
    private func deduplicate(frames: [(timestamp: Double, data: Data)], hammingThreshold: Int) -> [Data] {
        guard !frames.isEmpty else { return [] }

        var accepted: [(timestamp: Double, data: Data, hash: UInt64?)] = []
        var rejected: [(timestamp: Double, data: Data)] = []

        for frame in frames {
            let hash = dHash(frame.data)
            let isDup = accepted.contains { existing in
                guard let h1 = hash, let h2 = existing.hash else { return false }
                return hammingDistance(h1, h2) < hammingThreshold
            }
            if isDup {
                rejected.append((frame.timestamp, frame.data))
            } else {
                accepted.append((frame.timestamp, frame.data, hash))
            }
        }

        // Ensure minimum frame count: restore rejected frames if we went too aggressive
        let minFrames = min(3, frames.count)
        while accepted.count < minFrames && !rejected.isEmpty {
            let restored = rejected.removeFirst()
            accepted.append((restored.timestamp, restored.data, nil))
        }

        return accepted.sorted { $0.timestamp < $1.timestamp }.map { $0.data }
    }

    /// 8×9 difference hash → 64 bits. Compares horizontally adjacent grayscale pixels.
    private func dHash(_ jpegData: Data) -> UInt64? {
        guard let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let width = 9
        let height = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixels = context.data else { return nil }
        let buffer = pixels.bindMemory(to: UInt8.self, capacity: width * height)

        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            for x in 0..<(width - 1) {
                let left = buffer[y * width + x]
                let right = buffer[y * width + x + 1]
                if left > right {
                    hash |= (UInt64(1) << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    private func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }
}
