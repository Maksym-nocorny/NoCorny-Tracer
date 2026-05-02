import Foundation
import AVFoundation
import AppKit
import CoreMedia
import ImageIO

/// Result of a naming + subtitles run, including accumulated cost-tracking metadata.
struct NamingResult {
    var srt: String?
    var name: String?
    var usage: GeminiUsage
    var model: String
    var latencyMs: Int
    var attempts: Int
    var success: Bool
    var errorCode: String?
}

/// Uses Google Gemini (via Cloudflare proxy) to generate descriptive names + subtitles for screen recordings.
final class AINamingService {

    // MARK: - Feature Flags

    /// Trim long silences before sending audio to Gemini. Phase A — enabled.
    static let enableTrimSilence: Bool = true
    /// Apply 1.25× speedup to trimmed audio. Phase B — disabled until validated on real ukr/rus recordings.
    static let enableSpeedUp: Bool = false
    static let speedUpFactor: Double = 1.25

    /// Audio chunks at or below this RMS in dBFS are silence for trim purposes.
    static let trimSilenceThresholdDBFS: Float = -45
    /// Hard cutoff for skip-if-silent: only fire when the file is essentially mute.
    static let skipSilenceThresholdDBFS: Float = -50
    /// If ≥95% of the audio is below skipSilenceThresholdDBFS, skip transcription entirely.
    static let skipSilenceCoverage: Float = 0.95

    // MARK: - Configuration

    private let proxyClient = GeminiProxyClient()

    // MARK: - Combined Subtitles + Name Generation

    /// Generates SRT subtitles and a descriptive filename in a single Gemini call.
    /// Audio may be trimmed of silence (and optionally sped up) before sending to reduce
    /// per-second costs. The returned SRT timestamps are mapped back onto the original
    /// recording timeline so they sync perfectly with the unmodified video.
    func generateSubtitlesAndName(for videoURL: URL) async -> NamingResult {
        LogManager.shared.log("🤖 Combined: Starting for \(videoURL.lastPathComponent)")

        var totalUsage = GeminiUsage.zero
        var totalLatencyMs = 0
        var totalAttempts = 0
        var observedModel = "gemini-2.5-flash-lite"

        // Step 1: extract a tiny m4a (32 kbps mono 16 kHz). Independent of original audio quality.
        guard let audioURL = await extractCompressedAudio(from: videoURL) else {
            LogManager.shared.log("🤖 Combined: ❌ Failed to extract audio — falling back to image-only naming", type: .error)
            let fb = await generateNameImageOnly(for: videoURL)
            return NamingResult(
                srt: nil, name: fb.name,
                usage: fb.usage, model: fb.model,
                latencyMs: fb.latencyMs, attempts: fb.attempts,
                success: fb.name != nil,
                errorCode: fb.errorCode ?? "audio_extraction_failed"
            )
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        // Step 2: VAD pre-check.
        let analysis = await analyzeSpeech(audioURL: audioURL)
        LogManager.shared.log("🤖 Combined: VAD — duration=\(String(format: "%.1f", analysis.totalDuration))s, speech=\(String(format: "%.1f", analysis.totalSpeechDuration))s, segments=\(analysis.segments.count), silenceCoverage=\(String(format: "%.2f", analysis.silenceCoverage))")

        if analysis.shouldSkipTranscription {
            LogManager.shared.log("🤖 Combined: 🤫 Skipping transcription (no clear speech detected)")
            let fb = await generateNameImageOnly(for: videoURL)
            return NamingResult(
                srt: nil, name: fb.name,
                usage: fb.usage, model: fb.model,
                latencyMs: fb.latencyMs, attempts: fb.attempts,
                success: fb.name != nil,
                errorCode: fb.errorCode
            )
        }

        // Step 3: prepare audio (trim + optional speedup). Always falls back to original on failure.
        var audioForGemini = audioURL
        var mapping: [TimestampMapping] = []
        var speedupFactor: Double = 1.0
        var stitchedURL: URL? = nil
        var spedUpURL: URL? = nil

        if Self.enableTrimSilence {
            if let stitched = await stitchSpeechAudio(audioURL: audioURL, segments: analysis.segments, originalDuration: analysis.totalDuration) {
                stitchedURL = stitched.url
                mapping = stitched.mapping
                audioForGemini = stitched.url
                LogManager.shared.log("🤖 Combined: Trimmed audio — \(stitched.mapping.count) segments, stitched=\(String(format: "%.1f", Double(stitched.mapping.last?.stitchedEndSamples ?? 0) / 16000.0))s")

                if Self.enableSpeedUp,
                   let sped = await applySpeedUp(audioURL: stitched.url, factor: Self.speedUpFactor) {
                    spedUpURL = sped
                    audioForGemini = sped
                    speedupFactor = Self.speedUpFactor
                    LogManager.shared.log("🤖 Combined: Applied \(Self.speedUpFactor)× speedup")
                }
            } else {
                LogManager.shared.log("🤖 Combined: Trim skipped — using original audio")
            }
        }
        defer {
            if let url = stitchedURL { try? FileManager.default.removeItem(at: url) }
            if let url = spedUpURL { try? FileManager.default.removeItem(at: url) }
        }

        // Step 4: read audio bytes and check size.
        guard let audioData = try? Data(contentsOf: audioForGemini) else {
            LogManager.shared.log("🤖 Combined: ❌ Failed to read audio at \(audioForGemini.path)", type: .error)
            let fb = await generateNameImageOnly(for: videoURL)
            return NamingResult(srt: nil, name: fb.name, usage: fb.usage, model: fb.model, latencyMs: fb.latencyMs, attempts: fb.attempts, success: fb.name != nil, errorCode: fb.errorCode ?? "audio_read_failed")
        }
        let sizeKB = audioData.count / 1024
        LogManager.shared.log("🤖 Combined: Audio for Gemini: \(sizeKB)KB (mapping segments: \(mapping.count), speedup: \(speedupFactor)×)")
        guard audioData.count < 20_000_000 else {
            LogManager.shared.log("🤖 Combined: ❌ Audio too large (\(audioData.count / 1_000_000)MB > 20MB)", type: .error)
            let fb = await generateNameImageOnly(for: videoURL)
            return NamingResult(srt: nil, name: fb.name, usage: fb.usage, model: fb.model, latencyMs: fb.latencyMs, attempts: fb.attempts, success: fb.name != nil, errorCode: fb.errorCode ?? "audio_too_large")
        }

        // Step 5: extract frames (no transcript yet — equispaced).
        let frames = await extractFrames(from: videoURL, subtitles: nil)
        if frames.isEmpty {
            LogManager.shared.log("🤖 Combined: ⚠️ No frames extracted — proceeding with audio only", type: .error)
        } else {
            LogManager.shared.log("🤖 Combined: Extracted \(frames.count) frames")
        }

        // Step 6: combined Gemini call.
        let prompt = combinedPrompt()
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "srt": ["type": "string"],
                "name": ["type": "string"]
            ],
            "required": ["srt", "name"]
        ]
        // temperature=0 makes the combined call deterministic. Eliminates most of the
        // sporadic failures we see (sparse SRT, language drift on the name) without
        // measurably hurting transcription quality on the recordings we've tested.
        let generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": schema,
            "temperature": 0
        ]

        let maxRetries = 3
        var delay: UInt64 = 5_000_000_000
        var lastError: String? = nil
        // Appended to the prompt on retry only when the previous attempt's name script
        // didn't match the SRT script — empty string for the first attempt.
        var languageHint: String = ""

        for attempt in 1...maxRetries {
            do {
                LogManager.shared.log("🤖 Combined: Calling Gemini proxy (attempt \(attempt)/\(maxRetries))...")
                let result = try await proxyClient.generateMultimodal(
                    prompt: prompt + languageHint,
                    audioData: audioData,
                    audioMimeType: "audio/mp4",
                    images: frames,
                    generationConfig: generationConfig
                )
                totalAttempts += 1
                totalLatencyMs += result.latencyMs
                totalUsage.add(result.usage)
                observedModel = result.model
                let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                LogManager.shared.log("🤖 Combined: ✅ Got response (\(raw.count) chars, prompt=\(result.usage.promptTokens), out=\(result.usage.outputTokens))")

                guard let parsed = parseCombinedResponse(raw) else {
                    LogManager.shared.log("🤖 Combined: ⚠️ Could not parse JSON response: \(raw.prefix(200))", type: .error)
                    lastError = "parse_failed"
                    if attempt < maxRetries {
                        try? await Task.sleep(nanoseconds: delay)
                        delay *= 2
                        continue
                    }
                    return NamingResult(srt: nil, name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: false, errorCode: lastError)
                }

                let cleanedName = cleanupName(parsed.name)
                let srtPreview = parsed.srt.prefix(120).replacingOccurrences(of: "\n", with: "⏎")
                LogManager.shared.log("🤖 Combined: Raw SRT (\(parsed.srt.count) chars) preview: \(srtPreview)")

                // Sparseness guard: Gemini occasionally returns one tiny segment for a multi-minute
                // recording even when audio clearly has speech throughout. Detect this and retry —
                // the retry usually fixes it because Gemini is non-deterministic at temperature>0.
                // We only flag as sparse when speech was detected (analysis.totalSpeechDuration)
                // so a genuinely silent recording with NO_SPEECH won't loop.
                let isExplicitNoSpeech = parsed.srt.uppercased().contains("NO_SPEECH")
                let lastEndSec = lastSrtEndSeconds(parsed.srt) ?? 0
                let speechSec = analysis.totalSpeechDuration
                let coverageRatio = speechSec > 0 ? lastEndSec / speechSec : 1.0
                let sparseEnoughToRetry =
                    !isExplicitNoSpeech &&
                    speechSec >= 10.0 &&
                    (coverageRatio < 0.3 || lastEndSec < 5.0)

                if sparseEnoughToRetry && attempt < maxRetries {
                    LogManager.shared.log("🤖 Combined: ⚠️ SRT covers only \(String(format: "%.1f", lastEndSec))s of \(String(format: "%.1f", speechSec))s of speech (ratio \(String(format: "%.2f", coverageRatio))) — retrying", type: .error)
                    lastError = "sparse_srt"
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                if sparseEnoughToRetry {
                    LogManager.shared.log("🤖 Combined: ⚠️ SRT still sparse after \(maxRetries) attempts — accepting partial result", type: .error)
                }

                // Language-script post-check: even with the explicit "write the name in the
                // SAME language as the spoken audio" instruction in the prompt, Gemini
                // occasionally returns an English name for a Cyrillic-narrated recording
                // (the visual code/UI in the screenshots biases it). Retry once with an
                // explicit script hint if the name's script doesn't match the SRT's.
                let srtScript = dominantScript(parsed.srt)
                let nameScript = dominantScript(cleanedName ?? parsed.name)
                let scriptMismatch = (srtScript == .cyrillic && nameScript == .latin) ||
                                     (srtScript == .latin && nameScript == .cyrillic)
                if scriptMismatch && attempt < maxRetries {
                    let scriptName = srtScript == .cyrillic ? "Cyrillic" : "Latin"
                    let exampleLang = srtScript == .cyrillic ? "Russian or Ukrainian" : "English"
                    LogManager.shared.log("🤖 Combined: ⚠️ Language mismatch — SRT is \(srtScript.rawValue), name \"\(cleanedName ?? "nil")\" is \(nameScript.rawValue). Retrying with \(scriptName) hint.", type: .error)
                    lastError = "language_mismatch"
                    languageHint = "\n\nPRIOR ATTEMPT FAILED: the returned `name` was in the wrong script. The transcript is in \(scriptName) script (\(exampleLang)). The `name` MUST be written in \(scriptName) script. Do NOT translate to English."
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                if scriptMismatch {
                    LogManager.shared.log("🤖 Combined: ⚠️ Language still mismatched after \(maxRetries) attempts — accepting result rather than losing the title", type: .error)
                }

                let restoredSrt = restoreSrtTimestamps(parsed.srt, mapping: mapping, speedupFactor: speedupFactor, originalDuration: analysis.totalDuration)

                LogManager.shared.log("🤖 Combined: ✅ Name: \"\(cleanedName ?? "nil")\", restored SRT length: \(restoredSrt?.count ?? 0)")
                return NamingResult(srt: restoredSrt, name: cleanedName, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: true, errorCode: nil)

            } catch {
                let errorString = "\(error)"
                lastError = String(errorString.prefix(200))
                totalAttempts += 1
                if attempt < maxRetries {
                    LogManager.shared.log("🤖 Combined: ⏳ Attempt \(attempt) failed (\(errorString)), retrying in \(delay / 1_000_000_000)s...", type: .error)
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                LogManager.shared.log("🤖 Combined: ❌ All \(maxRetries) attempts failed. Last error: \(errorString)", type: .error)
                return NamingResult(srt: nil, name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: false, errorCode: lastError)
            }
        }

        return NamingResult(srt: nil, name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: false, errorCode: lastError)
    }

    // MARK: - Image-only Naming Fallback

    private struct ImageOnlyResult {
        var name: String?
        var usage: GeminiUsage
        var model: String
        var latencyMs: Int
        var attempts: Int
        var errorCode: String?
    }

    private func generateNameImageOnly(for videoURL: URL) async -> ImageOnlyResult {
        var totalUsage = GeminiUsage.zero
        var totalLatencyMs = 0
        var totalAttempts = 0
        var observedModel = "gemini-2.5-flash-lite"
        var lastError: String? = nil

        let frames = await extractFrames(from: videoURL, subtitles: nil)
        guard !frames.isEmpty else {
            LogManager.shared.log("🤖 Naming (image-only): ❌ No frames", type: .error)
            return ImageOnlyResult(name: nil, usage: totalUsage, model: observedModel, latencyMs: 0, attempts: 0, errorCode: "no_frames")
        }
        LogManager.shared.log("🤖 Naming (image-only): \(frames.count) frames")

        let prompt = """
        Review these screenshots taken from a screen recording. \
        Generate a detailed, descriptive filename (5-10 words, no file extension) \
        that specifically describes the code, application, or topic shown. \
        Focus on the concrete details of what the user is actually doing. \
        Use title case. Examples: "Fixing Google Sign-In Crash in Swift", "Analytics Dashboard Overview for Revenue". \
        Return ONLY the filename, nothing else.
        """

        let maxRetries = 3
        var delay: UInt64 = 5_000_000_000
        for attempt in 1...maxRetries {
            do {
                LogManager.shared.log("🤖 Naming (image-only): Gemini call (attempt \(attempt)/\(maxRetries))...")
                let result = try await proxyClient.generateWithImages(prompt: prompt, images: frames)
                totalAttempts += 1
                totalLatencyMs += result.latencyMs
                totalUsage.add(result.usage)
                observedModel = result.model
                let cleaned = cleanupName(result.text.trimmingCharacters(in: .whitespacesAndNewlines))
                LogManager.shared.log("🤖 Naming (image-only): ✅ \"\(cleaned ?? "nil")\"")
                return ImageOnlyResult(name: cleaned, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, errorCode: nil)
            } catch {
                totalAttempts += 1
                lastError = String("\(error)".prefix(200))
                if attempt < maxRetries {
                    LogManager.shared.log("🤖 Naming (image-only): ⏳ retry in \(delay / 1_000_000_000)s (\(error))", type: .error)
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                }
            }
        }
        return ImageOnlyResult(name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, errorCode: lastError)
    }

    // MARK: - Prompts and Cleanup

    private func combinedPrompt() -> String {
        return """
        You receive an audio track and 3-10 screenshots from a screen recording. Produce a single JSON object with two fields: `srt` and `name`.

        ### `srt` — SRT subtitles
        Transcribe ONLY the primary, foreground speaker — the person actively narrating this screen recording. Do NOT transcribe:
        - Background voices from TV, radio, podcasts, or videos playing nearby
        - Song lyrics or vocal music
        - Distant, muffled, or overlapping voices that aren't the main speaker
        - Side conversations from other people in the room

        If a span of audio has no clear primary speaker, skip it. If the entire audio has no clear primary speaker, set `srt` to exactly the string "NO_SPEECH".

        CRITICAL FORMATTING REQUIREMENTS for the `srt` value:
        1. Each subtitle entry MUST be 1-2 sentences only. Maximum 10 seconds per entry.
        2. Entries MUST be separated by a blank line (two consecutive newlines).
        3. Do NOT collapse the entire transcript into a single entry. A 90-second recording should have 8-15 entries, not 1.
        4. Use real newline characters inside the JSON string (encoded as \\n). The decoded SRT must be parseable by standard SRT readers.
        5. Timestamps `HH:MM:SS,mmm --> HH:MM:SS,mmm` are relative to the START of the audio you receive.

        Exact format (the JSON value of `srt` must look like this when decoded):

        1
        00:00:00,000 --> 00:00:03,200
        First sentence goes here.

        2
        00:00:03,200 --> 00:00:07,800
        Second sentence goes here.

        3
        00:00:07,800 --> 00:00:12,400
        Third sentence goes here.

        ### `name` — descriptive filename
        Generate a SHORT topic-style filename (4-8 words, no file extension, no trailing punctuation) that names the application or topic shown in the screenshots. It's a filename, not a sentence — write a noun phrase or topic header, NOT a full sentence with verbs and conjunctions.

        Style requirements:
        - Topic phrasing: "[App or Game]: [What's happening]" or "[Topic] in [Tool]" or just a noun phrase.
        - Grammar must be correct in the chosen language. Do NOT translate word-for-word from English — write naturally as a native speaker would title a video.
        - English: title case ("Fixing Google Sign-In Crash in Swift").
        - Ukrainian/Russian/Polish/etc: standard sentence case (only first word and proper nouns capitalized, the rest lowercase). These languages do NOT use English-style title case.
        - No file extension, no quotes, no trailing period/exclamation.

        LANGUAGE: write the `name` in the SAME language as the SPOKEN AUDIO/TRANSCRIPT — NOT the language of code, UI text, or IDE shown in screenshots. Screenshots may show English code or interfaces even when the narrator speaks Russian or Ukrainian — that is normal. The narrator's voice ALWAYS determines the name language.
        - Russian narration → Russian name, even if screenshots show English Swift code.
        - Ukrainian narration → Ukrainian name, even if screenshots show an English website.
        - Mixed/unclear → use the dominant spoken language.
        - If audio has NO speech (NO_SPEECH) → fall back to English.

        Good examples:
        - English narration about Swift bug → "Fixing Google Sign-In Crash in Swift"
        - Russian narration about Swift bug (narrator speaks Russian) → "Отладка ошибки входа в Swift" (Russian, not English, even though code is English)
        - Russian narration playing RimWorld with caravan → "RimWorld: караван возвращается в колонию"
        - Ukrainian narration debugging API → "Налагодження помилки 500 у API замовлень"
        - English silent UI demo → "Slack Team Discussion on Q1 Roadmap"

        Bad examples (do NOT do this):
        - Russian narrator, English code → "Optimize token usage for video processing" (WRONG: English name for Russian narrator)
        - "RimWorld игра караван приближается к дому и требуется ремонт кондиционеры" (full sentence, grammar error in last word)
        - "fixing google signin in swift" (English without title case)
        - "Виправлення Помилки Авторизації У Swift" (Ukrainian with English-style title case — wrong)

        Return strict JSON of the form:
        {"srt":"<srt text or NO_SPEECH>","name":"<filename>"}
        """
    }

    private func cleanupName(_ raw: String) -> String? {
        let cleaned = raw
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: ".mp4", with: "")
            .replacingOccurrences(of: ".mov", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Language Detection

    /// Coarse script classification used to verify the AI title is in the same script as
    /// the transcript. We don't need true language identification — script is enough to
    /// catch the failure mode we see in production: Russian/Ukrainian narration getting
    /// an English title.
    enum NameScript: String {
        case cyrillic, latin, mixed, undetermined
    }

    /// Returns whichever of {Cyrillic, Latin} dominates the alphabetic characters in `s`.
    /// `mixed` if both are present in roughly equal share, `undetermined` if there are no
    /// alphabetic characters at all.
    func dominantScript(_ s: String) -> NameScript {
        var latin = 0
        var cyrillic = 0
        for u in s.unicodeScalars {
            let v = u.value
            if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
                latin += 1
            } else if v >= 0x00C0 && v <= 0x024F && u.properties.isAlphabetic {
                latin += 1
            } else if (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F) {
                cyrillic += 1
            }
        }
        let total = latin + cyrillic
        guard total > 0 else { return .undetermined }
        let latinRatio = Double(latin) / Double(total)
        let cyrillicRatio = Double(cyrillic) / Double(total)
        if latinRatio >= 0.85 { return .latin }
        if cyrillicRatio >= 0.85 { return .cyrillic }
        return .mixed
    }

    private struct CombinedResponse {
        let srt: String
        let name: String
    }

    /// Parses an SRT body and returns the largest end-timestamp it contains (in seconds).
    /// Used to detect "sparse" outputs where Gemini transcribed only the first phrase.
    private func lastSrtEndSeconds(_ srt: String) -> Double? {
        // Match every "HH:MM:SS,mmm --> HH:MM:SS,mmm" line and take the max end time.
        // Tolerates ',' or '.' as the millisecond separator (Gemini sometimes confuses them).
        let pattern = #"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsrange = NSRange(srt.startIndex..., in: srt)
        var maxEnd: Double = 0
        var found = false
        re.enumerateMatches(in: srt, range: nsrange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 9 else { return }
            func g(_ i: Int) -> Int {
                guard let r = Range(m.range(at: i), in: srt), let v = Int(srt[r]) else { return 0 }
                return v
            }
            let h = g(5), mm = g(6), s = g(7), ms = g(8)
            let end = Double(h * 3600 + mm * 60 + s) + Double(ms) / 1000.0
            if end > maxEnd { maxEnd = end }
            found = true
        }
        return found ? maxEnd : nil
    }

    private func parseCombinedResponse(_ raw: String) -> CombinedResponse? {
        let stripped = raw
            .replacingOccurrences(of: "```json\n", with: "")
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```\n", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let srt = json["srt"] as? String,
              let name = json["name"] as? String else {
            return nil
        }
        return CombinedResponse(srt: srt, name: name)
    }

    // MARK: - VAD Analysis

    private struct SpeechSegment {
        let startSamples: Int
        let endSamples: Int
        var startSeconds: Double { Double(startSamples) / 16000.0 }
        var endSeconds: Double { Double(endSamples) / 16000.0 }
    }

    private struct SpeechAnalysis {
        let totalDuration: Double
        let totalSpeechDuration: Double
        let segments: [SpeechSegment]
        let silenceCoverage: Float
        let shouldSkipTranscription: Bool
    }

    private struct TimestampMapping {
        let stitchedStartSamples: Int
        let stitchedEndSamples: Int
        let originalStartSamples: Int
        var stitchedStartSeconds: Double { Double(stitchedStartSamples) / 16000.0 }
        var stitchedEndSeconds: Double { Double(stitchedEndSamples) / 16000.0 }
        var originalStartSeconds: Double { Double(originalStartSamples) / 16000.0 }
    }

    /// Reads the compressed m4a as PCM, computes per-100ms RMS, and groups active chunks
    /// into speech segments. All bookkeeping is in integer sample counts to avoid float drift.
    private func analyzeSpeech(audioURL: URL) async -> SpeechAnalysis {
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
            let silentChunks = rmsByChunk.filter { $0 < AINamingService.skipSilenceThresholdDBFS }.count
            let silenceCoverage = rmsByChunk.isEmpty ? 1.0 : Float(silentChunks) / Float(rmsByChunk.count)
            let skipDueToSilence = silenceCoverage >= AINamingService.skipSilenceCoverage

            // Group consecutive active chunks into raw segments.
            let activeMask = rmsByChunk.map { $0 > AINamingService.trimSilenceThresholdDBFS }
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

    // MARK: - Stitch and Speedup

    private struct StitchResult {
        let url: URL
        let mapping: [TimestampMapping]
    }

    /// Builds an AVMutableComposition that contains only the speech segments and exports
    /// it as m4a. Returns nil (caller falls back to original) when trimming wouldn't help
    /// or any AV step fails.
    private func stitchSpeechAudio(audioURL: URL, segments: [SpeechSegment], originalDuration: Double) async -> StitchResult? {
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
    private func applySpeedUp(audioURL: URL, factor: Double) async -> URL? {
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

    // MARK: - SRT Timestamp Restoration

    /// Maps SRT timestamps from Gemini's stitched-and-sped-up timeline back onto the
    /// original recording timeline AND always re-formats the SRT so the web's `parseSrt`
    /// gets a clean, multi-segment file (Gemini in JSON-mode sometimes collapses everything
    /// into one giant entry — we split that back into per-sentence chunks here).
    /// Returns nil for empty / NO_SPEECH responses, or when too many entries fall out of bounds.
    private func restoreSrtTimestamps(_ srt: String, mapping: [TimestampMapping], speedupFactor: Double, originalDuration: Double) -> String? {
        let trimmed = srt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "NO_SPEECH" {
            return nil
        }

        let stripped = trimmed
            .replacingOccurrences(of: "```srt\n", with: "")
            .replacingOccurrences(of: "```srt", with: "")
            .replacingOccurrences(of: "```\n", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize single-newline-between-entries to the standard blank-line separator.
        // Gemini in JSON-mode sometimes drops the blank line, especially for Cyrillic /
        // non-Latin content, which collapses the entire SRT into one block under standard
        // parsers. Insert the missing blank line before every "number\ntimestamp -->" run.
        let normalized = stripped.replacingOccurrences(
            of: #"(?<!\n)\n(\d+\n\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->)"#,
            with: "\n\n$1",
            options: .regularExpression
        )

        var segments = parseSrt(normalized)

        // Recovery: if the Gemini response wasn't parseable (no real newlines, exotic format),
        // try a regex sweep over the raw text to find timestamp pairs.
        if segments.isEmpty {
            segments = recoverSrtFromInline(stripped)
            if !segments.isEmpty {
                LogManager.shared.log("🤖 SRT: ⚠️ Standard parse failed, recovered \(segments.count) segments via regex fallback")
            }
        }

        guard !segments.isEmpty else {
            LogManager.shared.log("🤖 SRT: ❌ Could not parse any segments from response. First 200 chars: \(stripped.prefix(200))", type: .error)
            return nil
        }

        // Recovery #1.5: Gemini occasionally collapses several adjacent cues into one block
        // where the inner timestamps remain inline as plain text inside the cue body
        // (e.g. "первая фраза 00:00:03,375 --> 00:00:05,335 вторая фраза"). The standard
        // parseSrt() preserves that text verbatim, so the timestamps would render in the
        // transcript UI. Split such segments using the embedded timestamps as breakpoints,
        // then strip any leftover patterns as a safety net.
        let splitByInline = splitSegmentsByInlineTimestamps(segments)
        if splitByInline.count != segments.count {
            LogManager.shared.log("🤖 SRT: Split inline-collapsed segment(s): \(segments.count) → \(splitByInline.count)")
        }
        segments = splitByInline.map { sanitizeInlineTimestamps($0) }

        // Recovery #2: if Gemini collapsed everything into a single very long entry, split
        // it into sentence-sized chunks so the player and the description-generator on the
        // web see a properly segmented transcript.
        var splitSegments: [SrtSegment] = []
        for seg in segments {
            let dur = seg.end - seg.start
            if dur > 15 && seg.text.count > 80 {
                splitSegments.append(contentsOf: splitLongSegmentBySentences(seg))
            } else {
                splitSegments.append(seg)
            }
        }
        if splitSegments.count != segments.count {
            LogManager.shared.log("🤖 SRT: Split \(segments.count) → \(splitSegments.count) segments (Gemini gave overly-long entries)")
        }
        segments = splitSegments

        var rebuiltLines: [String] = []
        var idx = 1
        var outOfBoundsCount = 0
        for seg in segments {
            let mappedStart = mapTimestamp(seg.start, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration)
            let mappedEnd = mapTimestamp(seg.end, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration)

            if mappedEnd <= mappedStart { outOfBoundsCount += 1; continue }
            if mappedStart < 0 || mappedEnd > originalDuration + 0.5 { outOfBoundsCount += 1 }

            let clampedStart = max(0, mappedStart)
            let clampedEnd = min(originalDuration, mappedEnd)
            if clampedEnd <= clampedStart { continue }

            rebuiltLines.append("\(idx)")
            rebuiltLines.append("\(formatSrtTimestamp(clampedStart)) --> \(formatSrtTimestamp(clampedEnd))")
            rebuiltLines.append(seg.text)
            rebuiltLines.append("")
            idx += 1
        }

        if outOfBoundsCount > segments.count / 5 {
            LogManager.shared.log("🤖 Trim: ⚠️ \(outOfBoundsCount)/\(segments.count) timestamps out of bounds — discarding SRT", type: .error)
            return nil
        }

        let result = rebuiltLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Last-resort recovery: regex-scan the raw text for timestamp pairs and slice text
    /// between them. Used when the response contains no real newlines (`\\n` literals or
    /// an exotic single-line format).
    private func recoverSrtFromInline(_ raw: String) -> [SrtSegment] {
        let pattern = #"(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nstext = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nstext.length))
        guard !matches.isEmpty else { return [] }

        var segments: [SrtSegment] = []
        for (i, m) in matches.enumerated() {
            let start = parseSrtTimestamp(nstext.substring(with: m.range(at: 1)))
            let end = parseSrtTimestamp(nstext.substring(with: m.range(at: 2)))
            // Text lives between the end of this timestamp pair and the start of the next.
            let textStart = m.range.location + m.range.length
            let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nstext.length
            guard textEnd > textStart else { continue }
            var text = nstext.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            // Strip leading numeric index if the next entry starts with one.
            text = text.replacingOccurrences(of: #"^\s*\d+\s*$"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*\d+\s*$"#, with: "", options: .regularExpression)
            text = text
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(SrtSegment(start: start, end: end, text: text))
            }
        }
        return segments
    }

    /// Inline-timestamp pattern used to detect Gemini's "collapsed cue" failure mode.
    /// Matches `HH:MM:SS,mmm --> HH:MM:SS,mmm` (also tolerates `.` as the ms separator).
    private static let inlineTimestampPattern = #"(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})"#

    /// Splits any segment whose text body contains inline `HH:MM:SS,mmm --> HH:MM:SS,mmm`
    /// patterns into multiple segments, using the embedded timestamps as breakpoints.
    /// Timestamps stay on the same (stitched/sped-up) timeline that Gemini returned, so
    /// `mapTimestamp()` later translates them back to the original recording timeline along
    /// with every other segment.
    private func splitSegmentsByInlineTimestamps(_ segments: [SrtSegment]) -> [SrtSegment] {
        guard let regex = try? NSRegularExpression(pattern: Self.inlineTimestampPattern, options: []) else {
            return segments
        }
        var result: [SrtSegment] = []
        for seg in segments {
            let nstext = seg.text as NSString
            let matches = regex.matches(in: seg.text, range: NSRange(location: 0, length: nstext.length))
            if matches.isEmpty {
                result.append(seg)
                continue
            }

            // Pre-chunk: text before the first embedded timestamp keeps the segment's start
            // and ends where the first embedded cue begins.
            let firstMatchLoc = matches[0].range.location
            let firstEmbeddedStart = parseSrtTimestamp(nstext.substring(with: matches[0].range(at: 1)))
            if firstMatchLoc > 0 {
                let preText = nstext.substring(with: NSRange(location: 0, length: firstMatchLoc))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preText.isEmpty {
                    let preEnd = max(seg.start, min(seg.end, firstEmbeddedStart))
                    if preEnd > seg.start {
                        result.append(SrtSegment(start: seg.start, end: preEnd, text: preText))
                    }
                }
            }

            // Per-match chunks: text between this match's end and the next match's start
            // (or seg.end for the last match). Use the embedded pair for the chunk's timing.
            for (i, m) in matches.enumerated() {
                let embeddedStart = parseSrtTimestamp(nstext.substring(with: m.range(at: 1)))
                let embeddedEnd = parseSrtTimestamp(nstext.substring(with: m.range(at: 2)))
                let textStart = m.range.location + m.range.length
                let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nstext.length
                guard textEnd > textStart else { continue }
                let text = nstext.substring(with: NSRange(location: textStart, length: textEnd - textStart))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let chunkStart = max(seg.start, min(seg.end, embeddedStart))
                let chunkEnd = max(chunkStart, min(seg.end, embeddedEnd))
                if chunkEnd > chunkStart {
                    result.append(SrtSegment(start: chunkStart, end: chunkEnd, text: text))
                }
            }
        }
        return result
    }

    /// Final safety net: strip any remaining inline `HH:MM:SS,mmm --> HH:MM:SS,mmm` patterns
    /// from cue text. The splitter above handles well-formed inline timestamps, but malformed
    /// values (e.g. impossible end < start) might fall through — this guarantees the UI never
    /// renders a raw timestamp pair.
    private func sanitizeInlineTimestamps(_ seg: SrtSegment) -> SrtSegment {
        let cleaned = seg.text
            .replacingOccurrences(of: Self.inlineTimestampPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != seg.text else { return seg }
        return SrtSegment(start: seg.start, end: seg.end, text: cleaned)
    }

    /// Splits one long segment into sentence-sized sub-segments, distributing time
    /// proportionally to character count.
    private func splitLongSegmentBySentences(_ seg: SrtSegment) -> [SrtSegment] {
        let pattern = #"[^.!?]+[.!?]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [seg] }
        let nstext = seg.text as NSString
        let matches = regex.matches(in: seg.text, range: NSRange(location: 0, length: nstext.length))
        guard matches.count >= 2 else { return [seg] }

        var sentences: [String] = []
        var totalChars = 0
        for m in matches {
            let s = nstext.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                sentences.append(s)
                totalChars += s.count
            }
        }
        guard sentences.count >= 2, totalChars > 0 else { return [seg] }

        let totalDuration = seg.end - seg.start
        var result: [SrtSegment] = []
        var cursor = seg.start
        for (i, s) in sentences.enumerated() {
            let proportion = Double(s.count) / Double(totalChars)
            let dur = totalDuration * proportion
            let isLast = i == sentences.count - 1
            let end = isLast ? seg.end : min(seg.end, cursor + dur)
            result.append(SrtSegment(start: cursor, end: end, text: s))
            cursor = end
        }
        return result
    }

    private func mapTimestamp(_ aiTime: Double, mapping: [TimestampMapping], speedupFactor: Double, originalDuration: Double) -> Double {
        let stitchedTime = aiTime * speedupFactor
        if mapping.isEmpty { return stitchedTime }
        for seg in mapping {
            if stitchedTime >= seg.stitchedStartSeconds && stitchedTime < seg.stitchedEndSeconds {
                return seg.originalStartSeconds + (stitchedTime - seg.stitchedStartSeconds)
            }
        }
        // Out of range → clamp to last segment's original end.
        if let last = mapping.last {
            let lastOriginalEnd = last.originalStartSeconds + (last.stitchedEndSeconds - last.stitchedStartSeconds)
            return min(originalDuration, lastOriginalEnd)
        }
        return stitchedTime
    }

    private func formatSrtTimestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total / 3600)
        let m = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let s = Int(total.truncatingRemainder(dividingBy: 60))
        let ms = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - Compressed Audio Extraction

    /// Extracts the audio track and re-encodes it as a tiny m4a (32 kbps mono 16 kHz) for
    /// transcription. Independent of the video's audio quality — the original audio in the
    /// recorded MP4 is untouched. 16 kHz mono is the format speech models expect; 32 kbps
    /// keeps even hour-long videos under Gemini's 20 MB inline-data limit.
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

    // MARK: - Frame Extraction

    /// Extracts frames at evenly spaced timestamps. 1024×1024 max resolution: still readable
    /// for code/UI screenshots, ~55% fewer image tokens than 1568.
    private func extractFrames(from videoURL: URL, subtitles: String?) async -> [Data] {
        let asset = AVAsset(url: videoURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)

        guard durationSeconds > 0 else { return [] }

        let timestamps = pickTimestamps(duration: durationSeconds, subtitles: subtitles)
        guard !timestamps.isEmpty else { return [] }
        LogManager.shared.log("🤖 AI Naming: Picked \(timestamps.count) timestamps: \(timestamps.map { String(format: "%.1f", $0) }.joined(separator: ", "))s")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1024, height: 1024)
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

    private func pickTimestamps(duration: Double, subtitles: String?) -> [Double] {
        guard duration > 0 else { return [] }

        if duration < 1 {
            return [duration / 2]
        }

        let n = max(3, min(10, Int(ceil(duration / 10.0))))
        let interval = duration / Double(n)
        var equispaced = (0..<n).map { interval * Double($0) + (interval / 2) }
        if !equispaced.isEmpty {
            equispaced[0] = min(equispaced[0], 0.5)
        }

        guard let srt = subtitles, !srt.isEmpty else {
            return equispaced
        }

        let segments = parseSrt(srt)
        let paragraphStarts = paragraphStartTimes(from: segments)

        guard paragraphStarts.count >= n else {
            return equispaced
        }

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

        let minFrames = min(3, frames.count)
        while accepted.count < minFrames && !rejected.isEmpty {
            let restored = rejected.removeFirst()
            accepted.append((restored.timestamp, restored.data, nil))
        }

        return accepted.sorted { $0.timestamp < $1.timestamp }.map { $0.data }
    }

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
