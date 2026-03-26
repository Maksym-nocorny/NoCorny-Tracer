import Foundation
import AVFoundation
import AppKit
import CoreMedia

/// Uses Google Gemini (via Cloudflare proxy) to generate descriptive names for screen recordings
final class AINamingService {

    // MARK: - Configuration

    private let proxyClient = GeminiProxyClient()

    // MARK: - Name Generation

    /// Generates a descriptive name using evenly spaced frames and the subtitle transcript
    func generateName(for videoURL: URL, subtitles: String?) async -> String? {
        print("🤖 AI Naming: Starting for \(videoURL.lastPathComponent)")

        // Extract up to 10 frames from the video
        let frames = await extractFrames(from: videoURL, maxFrames: 10)
        guard !frames.isEmpty else {
            print("🤖 AI Naming: ❌ Failed to extract any frames")
            return nil
        }
        print("🤖 AI Naming: ✅ Extracted \(frames.count) frames")

        let prompt = """
        Review these screenshots taken from a screen recording. \
        \(subtitles != nil ? "Also, here is the spoken transcript for context:\n\n" + subtitles! : "")

        Generate a detailed, descriptive filename (5-10 words, no file extension) \
        that specifically describes the code, application, or topic shown. \
        Focus on the concrete details of what the user is actually doing. \
        Use title case. Examples: "Fixing Google Sign-In Crash in Swift", "Slack Team Discussion on Q1 Roadmap", "Analytics Dashboard Overview for Revenue". \
        Return ONLY the filename, nothing else.
        """

        // Retry with exponential backoff for quota errors
        let maxRetries = 3
        var delay: UInt64 = 5_000_000_000 // 5 seconds

        for attempt in 1...maxRetries {
            do {
                print("🤖 AI Naming: Calling Gemini proxy (attempt \(attempt)/\(maxRetries))...")
                let text = try await proxyClient.generateWithImages(prompt: prompt, images: frames)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                print("🤖 AI Naming: ✅ Raw response: \"\(text)\"")
                let cleaned = text
                    .replacingOccurrences(of: "\"", with: "")
                    .replacingOccurrences(of: ".mp4", with: "")
                    .replacingOccurrences(of: ".mov", with: "")
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                print("🤖 AI Naming: ✅ Cleaned name: \"\(cleaned)\"")
                return cleaned.isEmpty ? nil : cleaned

            } catch {
                let errorString = "\(error)"
                if errorString.contains("429") || errorString.contains("resourceExhausted") || errorString.contains("Quota exceeded") {
                    if attempt < maxRetries {
                        print("🤖 AI Naming: ⏳ Quota exceeded, retrying in \(delay / 1_000_000_000)s...")
                        try? await Task.sleep(nanoseconds: delay)
                        delay *= 2
                        continue
                    }
                }
                print("🤖 AI Naming: ❌ Error: \(error)")
                return nil
            }
        }

        return nil
    }

    // MARK: - Subtitle Generation

    /// Generates SRT subtitles by extracting the audio track and sending it to Gemini
    func generateSubtitles(for videoURL: URL) async -> String? {
        print("🤖 Subtitles: Extracting audio from video...")
        guard let audioURL = await extractAudio(from: videoURL) else {
            print("🤖 Subtitles: ❌ Failed to extract audio")
            return nil
        }

        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        guard let audioData = try? Data(contentsOf: audioURL) else {
            print("🤖 Subtitles: ❌ Failed to read extracted audio file")
            return nil
        }

        // Limit to ~20MB for Gemini inline data
        guard audioData.count < 20_000_000 else {
            print("🤖 Subtitles: ❌ Audio too large (\(audioData.count / 1_000_000)MB)")
            return nil
        }

        print("🤖 Subtitles: Sending \(audioData.count / 1024)KB audio to Gemini proxy for transcription...")

        let prompt = """
        Transcribe all spoken words in this audio. Output the transcription in SRT subtitle format. \
        Each subtitle should be 1-2 sentences, with accurate timestamps. \
        Use this exact format:
        
        1
        00:00:00,000 --> 00:00:03,000
        First subtitle text here.
        
        2
        00:00:03,000 --> 00:00:06,000
        Second subtitle text here.
        
        Return ONLY the SRT content, nothing else. If there is no speech, return "NO_SPEECH".
        """

        let maxRetries = 3
        var delay: UInt64 = 5_000_000_000

        for attempt in 1...maxRetries {
            do {
                print("🤖 Subtitles: Calling Gemini proxy (attempt \(attempt)/\(maxRetries))...")
                let text = try await proxyClient.generateWithAudio(prompt: prompt, audioData: audioData)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                print("🤖 Subtitles: ✅ Got response (\(text.count) chars)")
                if text == "NO_SPEECH" || text.isEmpty {
                    print("🤖 Subtitles: No speech detected")
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
                if errorString.contains("429") || errorString.contains("resourceExhausted") || errorString.contains("Quota exceeded") {
                    if attempt < maxRetries {
                        print("🤖 Subtitles: ⏳ Quota exceeded, retrying in \(delay / 1_000_000_000)s...")
                        try? await Task.sleep(nanoseconds: delay)
                        delay *= 2
                        continue
                    }
                }
                print("🤖 Subtitles: ❌ Error: \(error)")
                return nil
            }
        }

        return nil
    }

    // MARK: - Media Extraction Helpers

    /// Extracts the audio track from a video file into a temporary .m4a file
    private func extractAudio(from videoURL: URL) async -> URL? {
        let asset = AVAsset(url: videoURL)
        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a

        await exportSession.export()

        if exportSession.status == .completed {
            return outputURL
        } else {
            print("Audio export failed: \(exportSession.error?.localizedDescription ?? "unknown error")")
            return nil
        }
    }

    /// Extracts up to `maxFrames` evenly spaced thumbnails from the video
    private func extractFrames(from videoURL: URL, maxFrames: Int) async -> [Data] {
        let asset = AVAsset(url: videoURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)

        guard durationSeconds > 0 else { return [] }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 800, height: 800)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let count = min(maxFrames, Int(durationSeconds) + 1)
        let interval = durationSeconds / Double(count)

        var times: [NSValue] = []
        for i in 0..<count {
            let time = CMTime(seconds: interval * Double(i) + (interval / 2), preferredTimescale: 600)
            times.append(NSValue(time: time))
        }

        let timesCount = times.count
        return await withCheckedContinuation { continuation in
            var framesData: [Data] = []
            var processedCount = 0

            generator.generateCGImagesAsynchronously(forTimes: times) { requestedTime, image, actualTime, result, error in
                if result == .succeeded, let cgImage = image {
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    if let tiffData = nsImage.tiffRepresentation,
                       let bitmap = NSBitmapImageRep(data: tiffData),
                       let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) {
                        framesData.append(jpegData)
                    }
                }

                processedCount += 1
                if processedCount == timesCount {
                    continuation.resume(returning: framesData)
                }
            }
        }
    }
}
