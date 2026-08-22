import Foundation

/// Producing a human-readable title for a recording.
///
/// Split from transcription because the two are independent choices: a transcript can
/// come from a local model with no network involved while the title still comes from
/// Gemini, and every engine added later reuses this unchanged. It holds its own proxy
/// client for exactly that reason -- naming is the Gemini call that survives when the
/// transcription engine is not Gemini.
///
/// Note this is NOT a text-only call: it sends video frames alongside the transcript,
/// and for a recording with no usable transcript the frames are all it has.
final class NamingService {

    private let proxyClient: GeminiProxyClient

    init(proxyClient: GeminiProxyClient) {
        self.proxyClient = proxyClient
    }

    /// False when no account is signed in. The transcript itself can still be produced
    /// -- the recording just keeps its timestamp placeholder for a name.
    var isReady: Bool { proxyClient.isReady }

    static let maxNamingTranscriptChars = 40_000

    /// Builds the transcript text for the naming call: plain cue text, no timestamps
    /// (~40% of SRT bytes and useless for naming). Over-long transcripts are sampled with an
    /// even stride so the title reflects the whole recording, not just the intro.
    func namingTranscriptText(_ segments: [SrtSegment]) -> String {
        let texts = segments.map(\.text).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return "" }

        let totalChars = texts.reduce(0) { $0 + $1.count + 1 }
        if totalChars <= Self.maxNamingTranscriptChars {
            return texts.joined(separator: " ")
        }

        let keep = max(1, texts.count * Self.maxNamingTranscriptChars / totalChars)
        let stride = Double(texts.count) / Double(keep)
        var picked: [String] = []
        var budget = Self.maxNamingTranscriptChars
        var cursor = 0.0
        while Int(cursor) < texts.count {
            let text = texts[Int(cursor)]
            if text.count + 1 > budget { break }
            picked.append(text)
            budget -= text.count + 1
            cursor += stride
        }
        LogManager.shared.log("🤖 Naming: transcript sampled \(picked.count)/\(texts.count) cues to fit \(Self.maxNamingTranscriptChars) chars")
        return picked.joined(separator: " ")
    }

    /// Returns an explicit language for the naming prompt ONLY when detection is confident
    /// and inside the confusable set this guard exists for.
    ///
    /// `LanguageDetection.dominantLanguage` reports ANY Latin-majority text as "English" by design, so naming
    /// the language unconditionally would command an English title for Polish/Spanish/etc
    /// narration — and the mismatch retry could never catch it, since it would be comparing
    /// two outputs of the same labeller. Ukrainian vs Russian is the case that genuinely
    /// needs naming: both are Cyrillic, so a script check alone cannot separate them.
    func namingLanguageHint(for transcript: String) -> String? {
        guard let language = LanguageDetection.dominantLanguage(transcript),
              language == "Ukrainian" || language == "Russian" else { return nil }

        var latin = 0
        var cyrillic = 0
        for u in transcript.unicodeScalars {
            let v = u.value
            if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
                latin += 1
            } else if (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F) {
                cyrillic += 1
            }
        }
        let total = latin + cyrillic
        guard total > 0, Double(cyrillic) / Double(total) >= 0.7 else { return nil }
        return language
    }

    func generateNameFromTranscript(
        transcript: String,
        frames: [Data],
        glossary: [String]
    ) async -> NamingCallResult {
        var result = NamingCallResult()

        // Ask this Mac first. On macOS 26 with Apple Intelligence on, the model is already
        // installed and costs nothing to run, so the cloud call is worth avoiding when the
        // transcript alone is enough to name the recording. Anything less than a usable
        // title -- older macOS, Apple Intelligence off, a refusal, a paragraph instead of a
        // title -- falls through to Gemini below rather than degrading what the user gets.
        if let onDevice = await OnDeviceNaming.title(fromTranscript: transcript) {
            result.name = cleanupName(onDevice) ?? onDevice
            result.model = "apple-on-device"
            result.attempts = 1
            return result
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": ["name": ["type": "string"]],
            "required": ["name"]
        ]
        let generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": schema,
            "temperature": 0
        ]

        let language = namingLanguageHint(for: transcript)
        let transcriptScript = LanguageDetection.dominantScript(transcript)
        let maxAttempts = 3
        var delay: Double = 4.0
        var hint = ""
        var languageRetryUsed = false

        for attempt in 1...maxAttempts {
            let prompt = namingPrompt(transcript: transcript, language: language, glossary: glossary) + hint
            do {
                let response = try await proxyClient.generateMultimodal(
                    prompt: prompt, images: frames, generationConfig: generationConfig
                )
                result.attempts += 1
                result.latencyMs += response.latencyMs
                result.usage.add(response.usage)
                result.model = response.model

                guard let rawName = TranscriptionSupport.parseJSONStringField(response.text, field: "name"),
                      let cleaned = cleanupName(rawName) else {
                    result.errorCode = "naming_parse_failed"
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the response was not strict JSON of the form {\"name\":\"...\"}. Return JSON only."
                        try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay)); delay *= 2
                        continue
                    }
                    return result
                }

                // Language check by SCRIPT, comparing the name against the transcript — two
                // independent signals. Comparing `LanguageDetection.dominantLanguage(name)` against the label we
                // injected into the prompt would be a tautology: if the label were wrong and
                // Gemini obeyed it, the check would pass every time.
                //
                // `.mixed` is NOT a mismatch. A Ukrainian title carrying Latin product names
                // ("Редизайн UI сайту у Figma") is correct, and `LanguageDetection.dominantScript` needs 85%
                // Cyrillic before it says `.cyrillic` — two or three Latin words in a short
                // title push it under that line. Only the opposite PURE script means Gemini
                // actually translated the title out of the spoken language.
                let nameScript = LanguageDetection.dominantScript(cleaned)
                let mismatch = transcriptScript != .undetermined && transcriptScript != .mixed
                    && nameScript != .undetermined && nameScript != .mixed
                    && nameScript != transcriptScript
                if mismatch && !languageRetryUsed && attempt < maxAttempts {
                    languageRetryUsed = true
                    result.errorCode = "naming_language_mismatch"
                    // Hold the rejected name instead of dropping it. If the retry never lands —
                    // a 504 from the proxy is routine on these ~1.5 MB multimodal calls — a
                    // wrong-language title still beats the "Recording · 20 Aug 2026 12:59"
                    // placeholder the caller falls back to when `name` comes back nil.
                    result.name = cleaned
                    LogManager.shared.log("🤖 Naming: ⚠️ name script \(nameScript) ≠ transcript script \(transcriptScript) - one retry with hint, holding the \(cleaned.count)-char title", type: .error)
                    let target = language ?? (transcriptScript == .cyrillic ? "the transcript's language" : "the transcript's language")
                    hint = "\n\nPRIOR ATTEMPT FAILED: the returned `name` was in the wrong language. Write the `name` in \(target), matching the transcript. Do NOT translate it into English or any other language."
                    try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay)); delay *= 2
                    continue
                }
                if mismatch {
                    LogManager.shared.log("🤖 Naming: ⚠️ language still mismatched - accepting the title rather than losing it", type: .error)
                }

                result.name = cleaned
                result.errorCode = nil
                return result

            } catch {
                result.attempts += 1
                result.errorCode = String("\(error)".prefix(200))
                if !isRetryableError(error) {
                    result.fatal = true
                    return result
                }
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay))
                    delay *= 2
                }
            }
        }
        return result
    }

    func generateNameImageOnly(for videoURL: URL) async -> ImageOnlyResult {
        var totalUsage = GeminiUsage.zero
        var totalLatencyMs = 0
        var totalAttempts = 0
        var observedModel = "gemini-2.5-flash-lite"
        var lastError: String? = nil

        let extracted = await FramePreparation.extractFrames(from: videoURL)
        // This is the fallback everything else lands on, so it MUST fit the budget on its own:
        // 10 text-heavy screenshots at full quality can exceed the whole request budget, which
        // would 413 the very path meant to rescue a failed run.
        let frames = FramePreparation.fitFramesToBudget(extracted, budget: TranscriptionTuning.maxInlineMediaBytes)
        guard !frames.isEmpty else {
            LogManager.shared.log("🤖 Naming (image-only): ❌ No frames", type: .error)
            return ImageOnlyResult(name: nil, usage: totalUsage, model: observedModel, latencyMs: 0, attempts: 0, errorCode: extracted.isEmpty ? "no_frames" : "frames_too_large")
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
                LogManager.shared.log("🤖 Naming (image-only): ✅ title \(cleaned?.count ?? 0) chars")
                return ImageOnlyResult(name: cleaned, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, errorCode: nil)
            } catch {
                totalAttempts += 1
                lastError = String("\(error)".prefix(200))
                guard isRetryableError(error) else {
                    LogManager.shared.log("🤖 Naming (image-only): ❌ Non-retryable failure (\(error)) — giving up", type: .error)
                    return ImageOnlyResult(name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, errorCode: lastError)
                }
                if attempt < maxRetries {
                    LogManager.shared.log("🤖 Naming (image-only): ⏳ retry in \(delay / 1_000_000_000)s (\(error))", type: .error)
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                }
            }
        }
        return ImageOnlyResult(name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, errorCode: lastError)
    }

    /// Naming prompt for the chunked path: the title is derived from the merged transcript
    /// plus screenshots, since no single call has heard the whole recording.
    ///
    /// `language` is injected only when local detection is confident (see `namingLanguageHint`).
    /// When it's nil we fall back to the original audio-derived wording — `LanguageDetection.dominantLanguage`
    /// reports ANY Latin-script text as "English", so naming a language on that basis would
    /// order an English title for e.g. Polish narration.
    func namingPrompt(transcript: String, language: String?, glossary: [String]) -> String {
        let languageRule: String
        if let language {
            languageRule = """
            LANGUAGE: write the `name` in \(language) — the language the narrator speaks. Screenshots may show English code, identifiers or interfaces even though the narrator speaks \(language); that is normal and does NOT change the name's language. Do NOT translate into English or any other language.
            """
        } else {
            languageRule = """
            LANGUAGE: write the `name` in the SAME language as the TRANSCRIPT below — NOT the language of code, UI text, or IDE shown in screenshots. Screenshots may show English code or interfaces even when the narrator speaks another language — that is normal. The transcript ALWAYS determines the name language.
            - If the transcript is empty → fall back to English.
            """
        }

        return """
        You receive the transcript of a screen recording plus 3-10 screenshots from it. Produce a single JSON object with one field: `name`.

        Generate a SHORT topic-style filename (4-8 words, no file extension, no trailing punctuation) that names the application or topic shown. It's a filename, not a sentence — write a noun phrase or topic header, NOT a full sentence with verbs and conjunctions.

        Base the topic on the TRANSCRIPT first; use the screenshots to identify the app, game, or tool by name.

        Style requirements:
        - Topic phrasing: "[App or Game]: [What's happening]" or "[Topic] in [Tool]" or just a noun phrase.
        - Grammar must be correct in the chosen language. Do NOT translate word-for-word from English — write naturally as a native speaker would title a video.
        - English: title case ("Fixing Google Sign-In Crash in Swift").
        - Ukrainian/Russian/Polish/etc: standard sentence case (only first word and proper nouns capitalized, the rest lowercase). These languages do NOT use English-style title case.
        - No file extension, no quotes, no trailing period/exclamation.

        \(languageRule)

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
        \(TranscriptionSupport.glossaryBlock(glossary))

        TRANSCRIPT:
        \(transcript)

        Return strict JSON of the form:
        {"name":"<filename>"}
        """
    }

    /// Maximum length of a cleaned name. The prompt targets a 4-8 word filename; 80 chars
    /// gives generous slack while keeping the user-visible title from ballooning if Gemini
    /// returns a whole sentence.
    static let maxNameLength = 80

    func cleanupName(_ raw: String) -> String? {
        // 1) Strip control characters (newlines, tabs, etc. become nothing here — runs are
        //    handled by the whitespace collapse below, but stray control chars are removed).
        var s = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        // 2) Collapse all whitespace runs (including any remaining tabs/newlines) to one space.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // 3) Drop quotes and remap path-hostile characters.
        s = s
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // 4) Strip a real trailing .mp4/.mov extension only (anchored, case-insensitive) —
        //    never a mid-string ".mov" that is part of a legitimate name.
        s = s.replacingOccurrences(of: #"(?i)\.(mp4|mov)$"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 5) Enforce the length cap, truncating at the last word boundary ≤ maxNameLength.
        //    Falls back to a hard cut if there is no boundary (e.g. one very long token).
        if s.count > Self.maxNameLength {
            let cap = s.index(s.startIndex, offsetBy: Self.maxNameLength)
            let head = s[..<cap]
            if let lastSpace = head.lastIndex(of: " ") {
                let truncated = head[..<lastSpace].trimmingCharacters(in: .whitespaces)
                s = truncated.isEmpty ? String(head) : truncated
            } else {
                s = String(head)
            }
        }
        return s.isEmpty ? nil : s
    }
}
