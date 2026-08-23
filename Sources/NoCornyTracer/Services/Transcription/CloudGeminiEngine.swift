import Foundation
import AVFoundation

/// Transcription via Gemini, through tracer.nocorny.com.
///
/// Everything Gemini-shaped lives here: the combined transcribe-and-name call, the
/// chunked path that exists because a Vercel request body caps at 4.5 MB, the frames-first
/// glossary, the language-drift wave, and the prompts. None of it is shared with another
/// engine, which is the point -- a local model needs no chunking, no frames and no
/// glossary, and should not inherit machinery built for a transport limit it does not have.
///
/// It carries NamingService because on this path a title often comes back in the same
/// response as the transcript, and every failure route ends at the image-only fallback.
final class CloudGeminiEngine: TranscriptionEngine {

    let kind: TranscriptionEngineKind = .cloudGemini

    private let proxyClient: GeminiProxyClient
    private let namingService: NamingService

    init(proxyClient: GeminiProxyClient, namingService: NamingService) {
        self.proxyClient = proxyClient
        self.namingService = namingService
    }

    /// Requires a signed-in Tracer account: the proxy holds the API key, not the app.
    var isReady: Bool { proxyClient.isReady }

    func transcribe(videoURL: URL, multiSpeaker: Bool) async -> EngineResult {
        let r = await run(videoURL, multiSpeaker: multiSpeaker)
        return EngineResult(
            srt: r.srt, name: r.name, usage: r.usage, model: r.model,
            latencyMs: r.latencyMs, attempts: r.attempts, success: r.success,
            errorCode: r.errorCode, fatal: r.fatal,
            totalChunks: r.totalChunks, failedChunks: r.failedChunks
        )
    }

    /// Generates SRT subtitles and a descriptive filename in a single Gemini call.
    /// Audio may be trimmed of silence (and optionally sped up) before sending to reduce
    /// per-second costs. The returned SRT timestamps are mapped back onto the original
    /// recording timeline so they sync perfectly with the unmodified video.
    private func run(_ videoURL: URL, multiSpeaker: Bool) async -> NamingResult {
        LogManager.shared.log("🤖 Combined: Starting for \(videoURL.lastPathComponent)")

        // AI naming runs through tracer.nocorny.com with a per-user token. Without
        // a Tracer account we have nothing to authenticate with, so skip the whole
        // pipeline (audio extraction, frame capture, network) and let the caller
        // fall back to a timestamp filename.
        guard proxyClient.isReady else {
            LogManager.shared.log("🤖 Combined: ⏭️  Skipping AI naming — not signed in to Tracer")
            return NamingResult(
                srt: nil, name: nil,
                usage: .zero, model: "n/a",
                latencyMs: 0, attempts: 0,
                success: false, errorCode: "not_signed_in",
                fatal: true
            )
        }

        var totalUsage = GeminiUsage.zero
        var totalLatencyMs = 0
        var totalAttempts = 0
        var observedModel = "gemini-2.5-flash-lite"

        // Step 1: extract a tiny m4a (32 kbps mono 16 kHz). Independent of original audio quality.
        guard let audioURL = await AudioPreparation.extractCompressedAudio(from: videoURL) else {
            LogManager.shared.log("🤖 Combined: ❌ Failed to extract audio — falling back to image-only naming", type: .error)
            let fb = await namingService.generateNameImageOnly(for: videoURL)
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
        let analysis = await AudioPreparation.analyzeSpeech(audioURL: audioURL)
        LogManager.shared.log("🤖 Combined: VAD — duration=\(String(format: "%.1f", analysis.totalDuration))s, speech=\(String(format: "%.1f", analysis.totalSpeechDuration))s, segments=\(analysis.segments.count), silenceCoverage=\(String(format: "%.2f", analysis.silenceCoverage))")

        if analysis.shouldSkipTranscription {
            LogManager.shared.log("🤖 Combined: 🤫 Skipping transcription (no clear speech detected)")
            let fb = await namingService.generateNameImageOnly(for: videoURL)
            return NamingResult(
                srt: nil, name: fb.name,
                usage: fb.usage, model: fb.model,
                latencyMs: fb.latencyMs, attempts: fb.attempts,
                success: fb.name != nil,
                errorCode: fb.errorCode
            )
        }

        // Step 2.5: long recordings go down the chunked path.
        //
        // The single-call path cannot serve them at any quality setting: at 32 kbps, base64
        // encoding alone puts ~12 minutes of audio over Vercel's 4.5 MB request-body limit,
        // which is enforced before our proxy handler ever runs. Short recordings keep the
        // original, well-tested single-call path unchanged.
        //
        // The threshold is measured against the audio we would actually SEND, not wall-clock
        // duration — `ChunkPlanner.chunkKeptRanges` applies the same trim decision the single-call path
        // makes below, so a mostly-silent 10-minute recording with 2 minutes of speech stays
        // on the cheaper single-call path instead of paying for a separate naming call.
        let totalSamples = Int(analysis.totalDuration * 16000)
        let keptRanges = ChunkPlanner.chunkKeptRanges(analysis: analysis, totalSamples: totalSamples)
        let audioSecondsToSend = Double(keptRanges.reduce(0) { $0 + $1.length }) / 16000.0
        if audioSecondsToSend > ChunkPlanner.effectiveSingleCallThresholdSeconds {
            LogManager.shared.log(
                "🤖 Combined: \(String(format: "%.0f", audioSecondsToSend))s of audio to send exceeds the \(String(format: "%.0f", ChunkPlanner.effectiveSingleCallThresholdSeconds))s single-call threshold — using the chunked path"
            )
            return await generateChunked(
                videoURL: videoURL, audioURL: audioURL,
                analysis: analysis, keptRanges: keptRanges,
                multiSpeaker: multiSpeaker
            )
        }

        // Step 3: prepare audio (trim + optional speedup). Always falls back to original on failure.
        var audioForGemini = audioURL
        var mapping: [TimestampMapping] = []
        var speedupFactor: Double = 1.0
        var stitchedURL: URL? = nil
        var spedUpURL: URL? = nil

        if TranscriptionTuning.enableTrimSilence {
            if let stitched = await AudioPreparation.stitchSpeechAudio(audioURL: audioURL, segments: analysis.segments, originalDuration: analysis.totalDuration) {
                stitchedURL = stitched.url
                mapping = stitched.mapping
                audioForGemini = stitched.url
                LogManager.shared.log("🤖 Combined: Trimmed audio — \(stitched.mapping.count) segments, stitched=\(String(format: "%.1f", Double(stitched.mapping.last?.stitchedEndSamples ?? 0) / 16000.0))s")

                if TranscriptionTuning.enableSpeedUp,
                   let sped = await AudioPreparation.applySpeedUp(audioURL: stitched.url, factor: TranscriptionTuning.speedUpFactor) {
                    spedUpURL = sped
                    audioForGemini = sped
                    speedupFactor = TranscriptionTuning.speedUpFactor
                    LogManager.shared.log("🤖 Combined: Applied \(TranscriptionTuning.speedUpFactor)× speedup")
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
            let fb = await namingService.generateNameImageOnly(for: videoURL)
            return NamingResult(srt: nil, name: fb.name, usage: fb.usage, model: fb.model, latencyMs: fb.latencyMs, attempts: fb.attempts, success: fb.name != nil, errorCode: fb.errorCode ?? "audio_read_failed")
        }
        let sizeKB = audioData.count / 1024
        LogManager.shared.log("🤖 Combined: Audio for Gemini: \(sizeKB)KB (mapping segments: \(mapping.count), speedup: \(speedupFactor)×)")

        // Step 5: extract frames (no transcript yet — equispaced).
        var frames = await FramePreparation.extractFrames(from: videoURL)
        if frames.isEmpty {
            LogManager.shared.log("🤖 Combined: ⚠️ No frames extracted — proceeding with audio only", type: .error)
        } else {
            LogManager.shared.log("🤖 Combined: Extracted \(frames.count) frames")
        }

        // Step 5.5: budget the ENCODED inline media. The authoritative guard is the exact
        // serialized-body check in GeminiProxyClient; this pre-emptive budget exists so we can
        // degrade gracefully instead of hitting it. Frames shrink first — on a long recording
        // the transcript is the valuable half, so audio is the last thing we give up.
        let audioBase64Bytes = FramePreparation.base64Size(audioData.count)
        let framesBudget = TranscriptionTuning.maxInlineMediaBytes - audioBase64Bytes
        LogManager.shared.log("🤖 Combined: Payload budget — audio b64=\(audioBase64Bytes / 1024)KB, frames b64=\(FramePreparation.encodedSize(frames) / 1024)KB, budget=\(TranscriptionTuning.maxInlineMediaBytes / 1024)KB")

        if framesBudget <= 0 {
            // Audio alone blows the budget, so there is nothing left to shrink. Reaching this
            // on the single-call path means the audio was under `ChunkPlanner.singleCallMaxAudioSeconds`
            // yet still too big — unusual, but bail to image-only rather than send a doomed request.
            LogManager.shared.log("🤖 Combined: ❌ Audio alone (\(audioBase64Bytes / 1024)KB b64) exceeds the media budget — falling back to image-only naming", type: .error)
            let fb = await namingService.generateNameImageOnly(for: videoURL)
            return NamingResult(srt: nil, name: fb.name, usage: fb.usage, model: fb.model, latencyMs: fb.latencyMs, attempts: fb.attempts, success: fb.name != nil, errorCode: fb.errorCode ?? "audio_too_large")
        }
        frames = FramePreparation.fitFramesToBudget(frames, budget: framesBudget)

        // Step 6: combined Gemini call.
        let prompt = combinedPrompt(multiSpeaker: multiSpeaker)
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

        // Best acceptable result seen so far. A later retry that throws (network drop,
        // proxy error) must NOT discard a perfectly good earlier attempt — we fall back to
        // this instead of returning nil. The latest acceptable attempt overwrites the
        // previous one. SrtCodec.restoreSrtTimestamps is computed once at store time and reused.
        var bestName: String? = nil
        var bestRestoredSrt: String? = nil
        var haveAcceptable = false

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
                    LogManager.shared.log("🤖 Combined: ⚠️ Could not parse JSON response (\(raw.count) chars, starts with \(raw.prefix(1).map { $0.isLetter || $0.isNumber ? "text" : String($0) }.joined()))", type: .error)
                    lastError = "parse_failed"
                    if attempt < maxRetries {
                        try? await Task.sleep(nanoseconds: delay)
                        delay *= 2
                        continue
                    }
                    if haveAcceptable {
                        return NamingResult(srt: bestRestoredSrt, name: bestName, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: true, errorCode: lastError)
                    }
                    return NamingResult(srt: nil, name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: false, errorCode: lastError)
                }

                let cleanedName = namingService.cleanupName(parsed.name)
                // Length only. This used to log the first 120 characters of the transcript,
                // which is the user's own speech -- and the diagnostic log is something we
                // now ask people to send us.
                LogManager.shared.log("🤖 Combined: Raw SRT (\(parsed.srt.count) chars)")

                // Restore the SRT timestamps once for this attempt so it can be stored as the
                // best result (and reused at the success return) without recomputing.
                let restoredSrt = SrtCodec.restoreSrtTimestamps(parsed.srt, mapping: mapping, speedupFactor: speedupFactor, originalDuration: analysis.totalDuration)

                // Keep this attempt as the best acceptable result if it carries a usable name
                // or a real (non-NO_SPEECH) SRT. Overwrite so the latest acceptable wins. This
                // is what the catch/parse-fail fallbacks return when a later retry throws,
                // rather than throwing away a perfectly good earlier attempt.
                if cleanedName != nil || restoredSrt != nil {
                    bestName = cleanedName
                    bestRestoredSrt = restoredSrt
                    haveAcceptable = true
                }

                // Sparseness guard: Gemini occasionally returns one tiny segment for a multi-minute
                // recording even when audio clearly has speech throughout. Detect this and retry —
                // the retry usually fixes it because Gemini is non-deterministic at temperature>0.
                // We only flag as sparse when speech was detected (analysis.totalSpeechDuration)
                // so a genuinely silent recording with NO_SPEECH won't loop.
                let isExplicitNoSpeech = parsed.srt.uppercased().contains("NO_SPEECH")
                let lastEndSec = SrtCodec.lastSrtEndSeconds(parsed.srt) ?? 0
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

                // Language post-check: even with the explicit "write the name in the
                // SAME language as the spoken audio" instruction in the prompt, Gemini
                // sometimes returns the name in the wrong language. Two failure modes
                // we see in production:
                //   1. Russian/Ukrainian narration → English name (visual code in
                //      screenshots biases it toward Latin script).
                //   2. Russian narration → Ukrainian name (or vice versa) — within
                //      the same Cyrillic script, so a script-only check misses it.
                // Retry with an explicit per-language hint when the name's language
                // doesn't match the SRT's.
                // A NO_SPEECH transcript carries no spoken language, so the name is
                // unconstrained-by-audio (English fallback or whatever the visuals warrant) —
                // never trigger the language-mismatch retry for it. LanguageDetection.dominantLanguage would
                // otherwise classify the literal "NO_SPEECH" sentinel as English and force a
                // wasteful extra network round-trip.
                let srtLanguage = isExplicitNoSpeech ? nil : LanguageDetection.dominantLanguage(parsed.srt)
                let nameLanguage = LanguageDetection.dominantLanguage(cleanedName ?? parsed.name)
                let languageMismatch = !isExplicitNoSpeech && srtLanguage != nil && nameLanguage != nil && srtLanguage != nameLanguage
                if languageMismatch && attempt < maxRetries {
                    let lang = srtLanguage!
                    LogManager.shared.log("🤖 Combined: ⚠️ Language mismatch - SRT is \(lang), name is \(nameLanguage ?? "unknown"). Retrying with \(lang) hint.", type: .error)
                    lastError = "language_mismatch"
                    languageHint = "\n\nPRIOR ATTEMPT FAILED: the returned `name` was in the wrong language. The transcript is in \(lang). The `name` MUST be written in \(lang). Do NOT translate to English, Russian, Ukrainian, or any other language — write it in \(lang) only."
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                if languageMismatch {
                    LogManager.shared.log("🤖 Combined: ⚠️ Language still mismatched after \(maxRetries) attempts — accepting result rather than losing the title", type: .error)
                }

                // restoredSrt was already computed above (and stored as the best result).
                // Length only: the title is a one-line summary of the meeting, so logging it
                // gives away what the transcript we deliberately never log was about.
                LogManager.shared.log("🤖 Combined: ✅ Name (\(cleanedName?.count ?? 0) chars), restored SRT length: \(restoredSrt?.count ?? 0)")
                return NamingResult(srt: restoredSrt, name: cleanedName, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: true, errorCode: nil)

            } catch {
                let errorString = "\(error)"
                // An account-level refusal keeps its exact code: it is the orchestrator's
                // only signal to try a different engine, and a stringified error matches
                // nothing in the set it checks.
                lastError = Self.failureCode(for: error)
                totalAttempts += 1
                // A deterministic failure (oversized body, bad request, signed out) returns the
                // same result no matter how many times we ask. Bail immediately and mark the
                // run fatal so the caller skips its outer second pass too.
                if !isRetryableError(error) {
                    LogManager.shared.log("🤖 Combined: ❌ Non-retryable failure (\(errorString)) — giving up without retries", type: .error)
                    if haveAcceptable {
                        return NamingResult(srt: bestRestoredSrt, name: bestName, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: true, errorCode: lastError)
                    }
                    return NamingResult(srt: nil, name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: false, errorCode: lastError, fatal: true)
                }
                if attempt < maxRetries {
                    LogManager.shared.log("🤖 Combined: ⏳ Attempt \(attempt) failed (\(errorString)), retrying in \(delay / 1_000_000_000)s...", type: .error)
                    try? await Task.sleep(nanoseconds: delay)
                    delay *= 2
                    continue
                }
                // A later attempt threw, but if an earlier attempt produced an acceptable
                // result, return it rather than discarding good work. Mark success:true but
                // keep errorCode = lastError so telemetry still records that retries failed.
                if haveAcceptable {
                    LogManager.shared.log("🤖 Combined: ⚠️ Attempt \(attempt) failed (\(errorString)) - returning best earlier result (name \(bestName?.count ?? 0) chars)", type: .error)
                    return NamingResult(srt: bestRestoredSrt, name: bestName, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: true, errorCode: lastError)
                }
                LogManager.shared.log("🤖 Combined: ❌ All \(maxRetries) attempts failed. Last error: \(errorString)", type: .error)
                return NamingResult(srt: nil, name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: false, errorCode: lastError)
            }
        }

        if haveAcceptable {
            return NamingResult(srt: bestRestoredSrt, name: bestName, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: true, errorCode: lastError)
        }
        return NamingResult(srt: nil, name: nil, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: false, errorCode: lastError)
    }

    // MARK: - Failure mapping

    /// What goes into `errorCode` for a thrown failure.
    ///
    /// An account-level refusal keeps its exact machine code, because that is the only thing
    /// the orchestrator matches on when deciding to try a different engine. Everything else
    /// keeps a truncated description, which is for humans reading telemetry.
    static func failureCode(for error: Error) -> String {
        accountRefusalCode(error) ?? String("\(error)".prefix(200))
    }

    /// The refusal that explains every chunk at once, if there was one.
    ///
    /// Folding this into a generic "chunks_all_failed" is what left a free user holding a
    /// downloaded 1.5 GB model and no transcript: the orchestrator could not tell "this
    /// account may not" from "this did not work", and only the first is worth re-asking
    /// someone else about.
    static func refusalAmong(_ results: [ChunkResult]) -> String? {
        let codes = results.compactMap(\.errorCode)
        // Deterministic beats switchable: a plan refusal repeats for every cloud engine,
        // while a disabled or unconfigured engine says nothing about the others.
        if codes.contains(ProxyTranscriptionError.premiumRequired.code) {
            return ProxyTranscriptionError.premiumRequired.code
        }
        return codes.first { AINamingService.refusalCodes.contains($0) }
    }

    func transcribeChunk(
        _ chunk: AudioChunk,
        totalChunks: Int,
        originalDuration: Double,
        glossary: [String],
        extraInstruction: String = "",
        multiSpeaker: Bool = false
    ) async -> ChunkResult {
        var result = ChunkResult(index: chunk.index, status: .failed)

        guard let audioData = try? Data(contentsOf: chunk.url) else {
            result.errorCode = "chunk_audio_read_failed"
            result.fatal = true
            return result
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": ["srt": ["type": "string"]],
            "required": ["srt"]
        ]
        let generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": schema,
            "temperature": 0
        ]
        let clipLabel = String(format: "%.0f", chunk.localDuration)

        let maxAttempts = 3
        var delay: Double = 4.0
        // Retries MUST differ from the attempt that failed: at temperature 0 an identical
        // request reproduces an identical response, so a bare re-send is a wasted call.
        var hint = ""

        for attempt in 1...maxAttempts {
            let prompt = chunkTranscriptionPrompt(
                part: chunk.index + 1, of: totalChunks,
                clipSeconds: chunk.localDuration, glossary: glossary,
                multiSpeaker: multiSpeaker
            ) + extraInstruction + hint

            do {
                let response = try await proxyClient.generateMultimodal(
                    prompt: prompt,
                    audioData: audioData,
                    audioMimeType: "audio/mp4",
                    generationConfig: generationConfig
                )
                result.attempts += 1
                result.latencyMs += response.latencyMs
                result.usage.add(response.usage)
                result.model = response.model

                guard let rawSrt = TranscriptionSupport.parseJSONStringField(response.text, field: "srt") else {
                    result.errorCode = "chunk_parse_failed"
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the response was not strict JSON of the form {\"srt\":\"...\"}. Return JSON only, with no prose around it."
                        try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay)); delay *= 2
                        continue
                    }
                    return result
                }

                if rawSrt.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("NO_SPEECH") {
                    result.status = .noSpeech
                    result.errorCode = nil
                    return result
                }

                let localSegments = SrtCodec.parseAndRepairSrt(rawSrt)
                guard !localSegments.isEmpty else {
                    result.errorCode = "chunk_unparseable_srt"
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the SRT could not be parsed. Follow the exact format shown, with a blank line between entries."
                        try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay)); delay *= 2
                        continue
                    }
                    return result
                }

                // Blind-chunk detection. Cues past the clip's end are dropped below; without
                // this check a chunk that answered in WHOLE-RECORDING time would lose every
                // cue and nothing would notice — it counts as a success, contributes nothing,
                // and leaves a silent hole. The sparse check cannot catch it either, because
                // overshooting timestamps INFLATE coverage instead of shrinking it.
                let limit = chunk.localDuration + 0.5
                let inRange = localSegments.filter { $0.start < limit }
                let droppedCount = localSegments.count - inRange.count
                let rawLastEnd = localSegments.map(\.end).max() ?? 0
                if droppedCount > inRange.count || rawLastEnd > chunk.localDuration * 1.5 {
                    result.errorCode = "chunk_timestamps_not_clip_local"
                    LogManager.shared.log(
                        "🤖 Chunk \(chunk.index): ⚠️ timestamps not clip-local (dropped \(droppedCount)/\(localSegments.count), lastEnd=\(String(format: "%.1f", rawLastEnd))s vs clip \(clipLabel)s)",
                        type: .error
                    )
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the timestamps were NOT relative to this clip. This clip is \(clipLabel) seconds long and its first moment is 00:00:00,000. Every timestamp MUST fall between 00:00:00,000 and \(clipLabel) seconds."
                        try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay)); delay *= 2
                        continue
                    }
                    return result
                }

                let clamped = inRange.map {
                    SrtSegment(start: $0.start, end: min($0.end, chunk.localDuration), text: $0.text)
                }
                let lastEnd = clamped.map(\.end).max() ?? 0

                // Per-chunk sparse check. Strictly better than the global one it replaces: a
                // sparse region inside a 10-minute recording never moved the global ratio, so
                // it went undetected; here it is caught and only that chunk is re-run.
                let coverage = chunk.speechSeconds > 0 ? lastEnd / chunk.speechSeconds : 1.0
                if chunk.speechSeconds >= 10, coverage < 0.3 || lastEnd < 5.0, attempt < maxAttempts {
                    result.errorCode = "chunk_sparse_srt"
                    LogManager.shared.log(
                        "🤖 Chunk \(chunk.index): ⚠️ sparse — covered \(String(format: "%.1f", lastEnd))s of ~\(String(format: "%.1f", chunk.speechSeconds))s of speech",
                        type: .error
                    )
                    hint = "\n\nPRIOR ATTEMPT FAILED: it covered only \(String(format: "%.0f", lastEnd)) seconds of roughly \(String(format: "%.0f", chunk.speechSeconds)) seconds of speech in this clip. Transcribe the ENTIRE clip from beginning to end."
                    try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay)); delay *= 2
                    continue
                }

                let (mapped, oob) = SrtCodec.mapSegments(
                    clamped, mapping: chunk.mapping,
                    speedupFactor: chunk.speedupFactor, originalDuration: originalDuration
                )

                // Two-tier out-of-bounds policy, tier 1: judge this chunk on its own. A single
                // global ratio would let one corrupted chunk discard every other chunk's work.
                if !clamped.isEmpty && oob > clamped.count / 2 {
                    result.errorCode = "chunk_timestamps_out_of_bounds"
                    LogManager.shared.log("🤖 Chunk \(chunk.index): ⚠️ \(oob)/\(clamped.count) cues out of bounds", type: .error)
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the timestamps were inconsistent (end before start, or outside the clip). Emit strictly increasing timestamps within 00:00:00,000 to \(clipLabel) seconds."
                        try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay)); delay *= 2
                        continue
                    }
                    return result
                }

                result.status = .transcribed
                result.segments = mapped
                result.text = clamped.map(\.text).joined(separator: " ")
                result.errorCode = nil
                return result

            } catch {
                result.attempts += 1
                let refusal = accountRefusalCode(error)
                result.errorCode = Self.failureCode(for: error)
                if let refusal {
                    // Asking again changes nothing: the plan and the server-side switch are
                    // the same a second later. Fatal stops THIS chunk retrying; the wave
                    // above stops the unsent ones being paid for at all.
                    result.fatal = true
                    LogManager.shared.log("🤖 Chunk \(chunk.index): 🚫 refused (\(refusal))", type: .error)
                    return result
                }
                if !isRetryableError(error) {
                    result.fatal = true
                    LogManager.shared.log("🤖 Chunk \(chunk.index): ❌ Non-retryable (\(error))", type: .error)
                    return result
                }
                if attempt < maxAttempts {
                    LogManager.shared.log("🤖 Chunk \(chunk.index): ⏳ attempt \(attempt) failed (\(error)), retrying...", type: .error)
                    try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay))
                    delay *= 2
                }
            }
        }
        return result
    }

    /// Merges per-chunk segments (already on the original timeline) into one ordered list.
    func mergeChunkSegments(_ results: [ChunkResult]) -> [SrtSegment] {
        var all = results.filter { $0.status == .transcribed }.flatMap(\.segments)
        guard !all.isEmpty else { return [] }
        all.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        var kept: [SrtSegment] = []
        for seg in all {
            guard let prev = kept.last else { kept.append(seg); continue }
            // Duplicate from an overlap window — only forced mid-speech cuts create these.
            if seg.start < prev.end - 0.2, SrtCodec.normalizedForDedupe(seg.text) == SrtCodec.normalizedForDedupe(prev.text) {
                continue
            }
            // Enforce monotonicity so the merged file never has overlapping cues.
            let start = max(seg.start, prev.end)
            if seg.end > start {
                kept.append(SrtSegment(start: start, end: seg.end, text: seg.text))
            }
        }
        return kept
    }

    /// Injectable so a test can watch what the wave asks of each chunk, without an encoder or
    /// a network. nil in production.
    ///
    /// Worth the surface: the wave hands every chunk a speaker scope, and speech that was
    /// transcribed under the wrong one is not recoverable later - diarization can only label
    /// words that came back. This is the one place that decision is made for a whole run.
    var chunkRunnerForTests: (@Sendable (PlannedChunk, Bool) async -> ChunkResult)?

    /// Runs a set of chunk plans through build + transcribe with a sliding-window task group.
    ///
    /// Chunk audio is built lazily inside each task so at most `concurrency` AAC encodes run
    /// at once — building all of them up front would spike CPU and disk for an hour-long file.
    func runChunkWave(
        plans: [PlannedChunk],
        totalChunks: Int,
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        glossary: [String],
        concurrency: Int,
        scratchKey: String,
        extraInstruction: String = "",
        multiSpeaker: Bool = false
    ) async -> [Int: ChunkResult] {
        var outcomes: [Int: ChunkResult] = [:]
        guard !plans.isEmpty else { return outcomes }

        // Shared with Groq on purpose: an account refusal or an admin switch explains every
        // chunk at once, so hearing it on chunk 1 of 12 must not cost eleven more encodes and
        // eleven more uploads to be told the same thing eleven more times.
        let verdict = RunVerdict()

        // ONE description of how a chunk is run, used by both the seeding loop and the refill
        // loop. They used to spell it out separately, three lines apart, and the seeding one
        // omitted `multiSpeaker` - so the first `concurrency` chunks of every chunked run were
        // transcribed with the narrator-only prompt while the rest heard everyone. On a call
        // under about fifteen minutes that was the entire transcript. The helper does not
        // capture the task group, which is what made a shared helper impossible before.
        @Sendable func run(_ plan: PlannedChunk) async -> ChunkResult {
            if let stub = chunkRunnerForTests { return await stub(plan, multiSpeaker) }
            return await runOneChunk(plan: plan, totalChunks: totalChunks, sourceAsset: sourceAsset,
                              sourceTrack: sourceTrack, originalDuration: originalDuration,
                              glossary: glossary, extraInstruction: extraInstruction,
                              multiSpeaker: multiSpeaker)
        }

        await withTaskGroup(of: ChunkResult.self) { group in
            var next = 0

            while next < min(concurrency, plans.count) {
                let plan = plans[next]
                next += 1
                group.addTask { await run(plan) }
            }

            while let outcome = await group.next() {
                outcomes[outcome.index] = outcome
                persistChunkScratch(key: scratchKey, result: outcome)
                await verdict.record(code: outcome.errorCode)
                // Drain what is already in flight, but schedule nothing further.
                if await verdict.current() != nil { continue }
                if next < plans.count {
                    let plan = plans[next]
                    next += 1
                    group.addTask { await run(plan) }
                }
            }
        }

        // Record the chunks that were never scheduled, rather than leaving them absent. The
        // retry wave filters on "missing, or failed but recoverable" - and missing would send
        // every skipped chunk straight back through the encode this just avoided.
        if let stopCode = await verdict.current() {
            let skipped = plans.filter { outcomes[$0.index] == nil }
            for plan in skipped {
                var result = ChunkResult(index: plan.index, status: .failed)
                result.errorCode = stopCode
                result.fatal = true
                outcomes[plan.index] = result
            }
            if !skipped.isEmpty {
                LogManager.shared.log("🤖 Chunked: 🚫 \(stopCode) — skipped \(skipped.count) of \(plans.count) chunks unsent")
            }
        }
        return outcomes
    }

    func runOneChunk(
        plan: PlannedChunk,
        totalChunks: Int,
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        glossary: [String],
        extraInstruction: String,
        /// No default on purpose. This defaulted to false, and the seeding loop three lines
        /// above the refill loop omitted it - so the first `concurrency` chunks of every
        /// chunked run were transcribed with the "only the primary speaker" prompt while the
        /// rest heard everyone. On a call under ~15 minutes that is the whole transcript, and
        /// speech that was never transcribed cannot be recovered by re-labelling.
        multiSpeaker: Bool
    ) async -> ChunkResult {
        guard let chunk = await AudioPreparation.buildChunkAudio(sourceAsset: sourceAsset, sourceTrack: sourceTrack, plan: plan) else {
            var failed = ChunkResult(index: plan.index, status: .failed)
            failed.errorCode = "chunk_build_failed"
            failed.fatal = true
            return failed
        }
        defer { try? FileManager.default.removeItem(at: chunk.url) }

        // Below a second of speech there is nothing to transcribe — skip the network entirely.
        if chunk.speechSeconds < 1.0 {
            return ChunkResult(index: plan.index, status: .noSpeech)
        }

        return await transcribeChunk(
            chunk, totalChunks: totalChunks, originalDuration: originalDuration,
            glossary: glossary, extraInstruction: extraInstruction, multiSpeaker: multiSpeaker
        )
    }

    /// Persists a chunk's mapped segments as it completes.
    ///
    /// Chunk results otherwise live only in memory, so a crash at chunk 11 of 12 discards
    /// nearly an hour of already-paid transcription with no trace. Cheap insurance, and the
    /// seed for a future resume.
    func persistChunkScratch(key: String, result: ChunkResult) {
        guard result.status == .transcribed, let srt = SrtCodec.serializeSrt(result.segments) else { return }
        let dir = chunkScratchDirectory(key: key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(format: "chunk-%03d.srt", result.index))
        try? srt.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Drops the scratch directory once the merged transcript exists — it is only useful
    /// while a run is in flight or after one died partway.
    func clearChunkScratch(key: String) {
        try? FileManager.default.removeItem(at: chunkScratchDirectory(key: key))
    }

    func chunkScratchDirectory(key: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nct-chunks", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// Asks Gemini for proper nouns visible ON SCREEN, once, before the chunk fan-out.
    ///
    /// This is the mitigation for the chunked path's one real quality regression: chunk 7
    /// never heard the app/product/person names introduced in chunk 1, so spellings drift —
    /// especially English tech terms inside Ukrainian or Russian narration. Screenshots are
    /// ground truth for those spellings (the name is literally written on screen), unlike a
    /// primer taken from chunk 0's own transcript, which would propagate chunk 0's mishearing
    /// to every other chunk. The 10 equispaced frames also span the WHOLE recording, whereas
    /// chunk-0 priming only sees the opening minutes.
    ///
    /// Fail-open and all-or-nothing: one attempt, hard timeout, and any failure returns [] so
    /// every chunk runs byte-identically to the unmitigated path. Never worse than baseline.
    func buildFrameGlossary(frames: [Data]) async -> GlossaryResult {
        guard !frames.isEmpty, !UserDefaults.standard.bool(forKey: "NCTGlossaryDisable") else {
            return GlossaryResult()
        }

        let prompt = """
        These screenshots are all from ONE screen recording. List the proper nouns that are VISIBLE AS TEXT on screen and that a narrator might say aloud: application names, product or brand names, website names, file or project names, person names, and distinctive technical terms.

        Copy the EXACT spelling as displayed on screen. Do not infer or invent names that are not literally visible. Do not include generic UI words ("File", "Save", "Settings") or common English words.

        Return strict JSON of the form: {"terms":["Name One","Name Two"]}
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "terms": ["type": "array", "items": ["type": "string"], "maxItems": Self.glossaryMaxTerms]
            ],
            "required": ["terms"]
        ]
        let generationConfig: [String: Any] = [
            "responseMimeType": "application/json",
            "responseSchema": schema,
            "temperature": 0
        ]

        let client = proxyClient
        let raced: GlossaryResult? = await withTaskGroup(of: GlossaryResult?.self) { group in
            group.addTask {
                do {
                    let response = try await client.generateMultimodal(
                        prompt: prompt, images: frames, generationConfig: generationConfig
                    )
                    var out = GlossaryResult()
                    out.usage.add(response.usage)
                    out.latencyMs = response.latencyMs
                    out.attempts = 1
                    out.model = response.model
                    out.terms = Self.parseGlossaryTerms(response.text)
                    return out
                } catch {
                    LogManager.shared.log("🤖 Glossary: ⚠️ call failed (\(error)) — continuing without a glossary", type: .error)
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: Self.glossaryTimeoutNanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let result = raced, !result.terms.isEmpty else {
            LogManager.shared.log("🤖 Glossary: none (timeout, failure, or nothing found) — chunks run unprimed")
            return raced ?? GlossaryResult()
        }
        // The terms are proper nouns lifted off the recording's own frames - names of people
        // and companies. The count is the diagnostic; the list is content.
        LogManager.shared.log("🤖 Glossary: \(result.terms.count) terms")
        return result
    }

    /// Removes glossary terms from text before language classification.
    ///
    /// `LanguageDetection.dominantLanguage` is a raw Latin-vs-Cyrillic character count, so correctly-spelled
    /// Latin tech terms — the glossary's SUCCESS case — inflate the Latin side and can
    /// misclassify a jargon-heavy Ukrainian chunk as English, firing a pointless drift retry
    /// whose re-transcription may well be worse than what it replaced.
    func strippingGlossaryTerms(_ text: String, glossary: [String]) -> String {
        guard !glossary.isEmpty else { return text }
        var out = text
        for term in glossary {
            out = out.replacingOccurrences(of: term, with: " ", options: [.caseInsensitive])
        }
        return out
    }

    /// Transcribes a long recording as parallel chunks, then names it from the merged
    /// transcript plus screenshots.
    ///
    /// Chunking exists because the proxy runs on Vercel, whose 4.5 MB request-body limit is
    /// enforced at the edge before the handler runs. A one-hour recording cannot be sent in a
    /// single call at any quality setting, and no server-side change can make it possible.
    func generateChunked(
        videoURL: URL,
        audioURL: URL,
        analysis: SpeechAnalysis,
        keptRanges: [SampleRange],
        multiSpeaker: Bool = false
    ) async -> NamingResult {
        // Chunk audio is always built at 1.0×. Enabling `TranscriptionTuning.enableSpeedUp` requires threading the
        // factor through AudioPreparation.buildChunkAudio AND the merge — a mismatch yields uniformly
        // compressed, in-bounds timestamps that no bounds check can detect.
        assert(!TranscriptionTuning.enableSpeedUp, "Chunked path assumes speedupFactor 1.0")

        var usage = GeminiUsage.zero
        var latencyMs = 0
        var attempts = 0
        var model = "gemini-2.5-flash-lite"
        let scratchKey = videoURL.deletingPathExtension().lastPathComponent

        func imageOnlyFallback(_ code: String, totalChunks: Int = 1, failedChunks: Int = 0) async -> NamingResult {
            let fb = await namingService.generateNameImageOnly(for: videoURL)
            usage.add(fb.usage)
            return NamingResult(
                srt: nil, name: fb.name, usage: usage, model: fb.model,
                latencyMs: latencyMs + fb.latencyMs, attempts: attempts + fb.attempts,
                success: fb.name != nil, errorCode: fb.errorCode ?? code, fatal: true,
                totalChunks: totalChunks, failedChunks: failedChunks
            )
        }

        let tuning = ChunkPlanner.ChunkTuning.current
        let plans = ChunkPlanner.planChunks(
            keptRanges: keptRanges,
            targetSamples: tuning.targetSamples,
            maxSamples: tuning.maxSamples,
            minSliverSamples: tuning.minSliverSamples,
            overlapSamples: tuning.overlapSamples,
            maxChunks: tuning.maxChunks
        )
        guard !plans.isEmpty else {
            LogManager.shared.log("🤖 Chunked: ❌ No chunks planned — falling back to image-only naming", type: .error)
            return await imageOnlyFallback("chunk_plan_empty")
        }

        let sourceAsset = AVAsset(url: audioURL)
        // Spelled out rather than chained: `try? await ….loadTracks(…).first` in one
        // expression crashes the 6.3.3 type-checker inside this function (SIGTRAP while
        // type-checking the target). Explicit types keep inference off that path.
        let sourceTracks: [AVAssetTrack]? = try? await sourceAsset.loadTracks(withMediaType: .audio)
        guard let sourceTrack: AVAssetTrack = sourceTracks?.first else {
            LogManager.shared.log("🤖 Chunked: ❌ Could not load the extracted audio track", type: .error)
            return await imageOnlyFallback("chunk_source_track_missing")
        }

        LogManager.shared.log(
            "🤖 Chunked: \(plans.count) chunks (target \(tuning.targetSamples / 16000)s, max \(tuning.maxSamples / 16000)s), concurrency \(tuning.maxConcurrent)"
        )

        // Frames feed both the glossary call and the naming call.
        let frames = FramePreparation.fitFramesToBudget(await FramePreparation.extractFrames(from: videoURL), budget: TranscriptionTuning.maxInlineMediaBytes)

        // Glossary must resolve before the fan-out — every chunk prompt embeds it.
        let glossaryResult = await buildFrameGlossary(frames: frames)
        usage.add(glossaryResult.usage)
        latencyMs += glossaryResult.latencyMs
        attempts += glossaryResult.attempts
        if let m = glossaryResult.model { model = m }
        let glossary = glossaryResult.terms

        // Wave 1 — all chunks.
        var outcomes = await runChunkWave(
            plans: plans, totalChunks: plans.count,
            sourceAsset: sourceAsset, sourceTrack: sourceTrack,
            originalDuration: analysis.totalDuration,
            glossary: glossary, concurrency: tuning.maxConcurrent, scratchKey: scratchKey,
            multiSpeaker: multiSpeaker
        )

        // Wave 2 — targeted retry of ONLY the chunks that failed recoverably. This replaces
        // the caller's outer second pass for this path: re-running everything would re-encode
        // and re-send all N chunks to fix a few, and the caller's gate could never fire on a
        // partial success anyway (it requires both srt and name to be nil).
        let retryable = plans.filter { plan in
            guard let outcome = outcomes[plan.index] else { return true }
            return outcome.status == .failed && !outcome.fatal
        }
        if !retryable.isEmpty {
            LogManager.shared.log("🤖 Chunked: retrying \(retryable.count)/\(plans.count) failed chunks")
            let retried = await runChunkWave(
                plans: retryable, totalChunks: plans.count,
                sourceAsset: sourceAsset, sourceTrack: sourceTrack,
                originalDuration: analysis.totalDuration,
                glossary: glossary, concurrency: tuning.maxConcurrent, scratchKey: scratchKey,
                multiSpeaker: multiSpeaker
            )
            for (index, result) in retried {
                // Keep the retry only if it actually improved on the first attempt.
                if result.status != .failed || outcomes[index] == nil {
                    if let previous = outcomes[index] {
                        var merged = result
                        merged.usage.add(previous.usage)
                        merged.latencyMs += previous.latencyMs
                        merged.attempts += previous.attempts
                        outcomes[index] = merged
                    } else {
                        outcomes[index] = result
                    }
                } else if var previous = outcomes[index] {
                    previous.usage.add(result.usage)
                    previous.latencyMs += result.latencyMs
                    previous.attempts += result.attempts
                    outcomes[index] = previous
                }
            }
        }

        // Cross-chunk language drift.
        await resolveLanguageDrift(
            outcomes: &outcomes, plans: plans,
            sourceAsset: sourceAsset, sourceTrack: sourceTrack,
            originalDuration: analysis.totalDuration,
            glossary: glossary, concurrency: tuning.maxConcurrent, scratchKey: scratchKey,
            multiSpeaker: multiSpeaker
        )

        var results = outcomes.values.sorted { $0.index < $1.index }
        for r in results {
            usage.add(r.usage)
            latencyMs += r.latencyMs
            attempts += r.attempts
            if let m = r.model { model = m }
        }

        let failedChunks = results.filter { $0.status == .failed }.count
        // Coverage counts NO_SPEECH as handled, not lost: a chunk Gemini reports as silent is
        // a legitimate outcome, not a failure, and must not drag `success` down.
        let handledSpeech = plans
            .filter { outcomes[$0.index].map { $0.status != .failed } ?? false }
            .reduce(0.0) { $0 + $1.speechSeconds }
        let totalSpeech = plans.reduce(0.0) { $0 + $1.speechSeconds }
        let speechCoverage = totalSpeech > 0 ? handledSpeech / totalSpeech : 0

        LogManager.shared.log(
            "🤖 Chunked: \(plans.count - failedChunks)/\(plans.count) chunks OK, speech coverage \(String(format: "%.0f%%", speechCoverage * 100))"
        )

        let merged = mergeChunkSegments(results)
        let mergedSrt = merged.isEmpty ? nil : SrtCodec.serializeSrt(merged)

        // Tier 2 of the out-of-bounds policy: a transcript survives as long as ANY chunk
        // produced usable cues. Per-chunk judgement already dropped the corrupted ones, so
        // there is no global ratio that can discard healthy chunks' work.
        guard let srt = mergedSrt, !merged.isEmpty else {
            let allNoSpeech = results.allSatisfy { $0.status == .noSpeech } && !results.isEmpty
            if allNoSpeech {
                // Mirrors today's NO_SPEECH behaviour exactly: no transcript, name from frames.
                // Routed here rather than through the transcript+frames naming call because an
                // empty transcript gives `LanguageDetection.dominantLanguage` nothing to work with.
                LogManager.shared.log("🤖 Chunked: 🤫 every chunk reported NO_SPEECH — image-only naming")
                return await imageOnlyFallback("no_speech", totalChunks: plans.count, failedChunks: failedChunks)
            }
            // An account-level refusal explains every chunk at once, and unlike a generic
            // failure it tells the orchestrator that ANOTHER engine may well succeed. Losing
            // it inside "chunks_all_failed" is what left a free user with the local model
            // downloaded and no transcript.
            if let refusal = Self.refusalAmong(results) {
                LogManager.shared.log("🤖 Chunked: 🚫 refused (\(refusal)) — no transcript from this engine", type: .error)
                return await imageOnlyFallback(refusal, totalChunks: plans.count, failedChunks: failedChunks)
            }
            LogManager.shared.log("🤖 Chunked: ❌ No usable transcript from any chunk", type: .error)
            return await imageOnlyFallback("chunks_all_failed", totalChunks: plans.count, failedChunks: failedChunks)
        }
        clearChunkScratch(key: scratchKey)

        // Naming from the merged transcript + frames.
        let transcriptText = namingService.namingTranscriptText(merged)
        let namingCall = await namingService.generateNameFromTranscript(
            transcript: transcriptText, frames: frames, glossary: glossary
        )
        usage.add(namingCall.usage)
        latencyMs += namingCall.latencyMs
        attempts += namingCall.attempts
        if let m = namingCall.model { model = m }

        // errorCode precedence: the most user-visible loss wins.
        var errorCode: String? = nil
        if failedChunks > 0 {
            errorCode = "partial_chunks_failed_\(failedChunks)_of_\(plans.count)"
        } else if namingCall.name == nil {
            errorCode = namingCall.errorCode ?? "naming_failed"
        }

        // success is telemetry, not a gate on storing data: a holey transcript is still saved
        // and still generates a description. It reports false when we lost most of the speech.
        let success = (speechCoverage >= 0.5) || namingCall.name != nil

        LogManager.shared.log(
            "🤖 Chunked: ✅ named (\(namingCall.name?.count ?? 0) chars), srt \(srt.count) chars from \(merged.count) cues"
        )

        return NamingResult(
            srt: srt, name: namingCall.name, usage: usage, model: model,
            latencyMs: latencyMs, attempts: attempts,
            success: success, errorCode: errorCode,
            // The internal retry wave already did everything the caller's second pass would,
            // so never ask for a full re-run of an hour-long recording.
            fatal: true,
            totalChunks: plans.count, failedChunks: failedChunks
        )
    }

    /// Re-runs chunks whose transcription language disagrees with a strict majority.
    ///
    /// Deliberately conservative, because the naive version of this actively corrupts
    /// bilingual recordings: a hint naming the majority language, sent to a chunk where the
    /// speaker genuinely switched languages, is an instruction to TRANSLATE. So the hint never
    /// names a language, the check only runs when a strict majority exists (a 50/50 two-chunk
    /// split is exactly the ambiguous case), and a retry is kept only if it actually resolves
    /// the disagreement — otherwise the original verbatim transcript stands.
    func resolveLanguageDrift(
        outcomes: inout [Int: ChunkResult],
        plans: [PlannedChunk],
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        glossary: [String],
        concurrency: Int,
        scratchKey: String,
        multiSpeaker: Bool = false
    ) async {
        var weights: [String: Double] = [:]
        var languageByIndex: [Int: String] = [:]

        for plan in plans {
            guard let outcome = outcomes[plan.index], outcome.status == .transcribed else { continue }
            // Strip glossary terms first: correctly-spelled Latin tech terms are the
            // glossary's success case, and they would otherwise tip the Latin/Cyrillic count.
            let text = strippingGlossaryTerms(outcome.text, glossary: glossary)
            guard let language = LanguageDetection.dominantLanguage(text) else { continue }
            languageByIndex[plan.index] = language
            weights[language, default: 0] += plan.speechSeconds
        }

        let classified = weights.values.reduce(0, +)
        guard classified > 0,
              let (majority, majorityWeight) = weights.max(by: { $0.value < $1.value }),
              majorityWeight / classified >= 0.65 else {
            if !weights.isEmpty {
                LogManager.shared.log("🤖 Chunked: language split \(weights.mapValues { Int($0) }) — no strict majority, skipping drift check")
            }
            return
        }

        let outliers = plans.filter { plan in
            guard let language = languageByIndex[plan.index], language != majority else { return false }
            return plan.speechSeconds >= 10
        }
        guard !outliers.isEmpty else { return }

        LogManager.shared.log("🤖 Chunked: ⚠️ \(outliers.count) chunk(s) drifted from majority language \(majority) — one verbatim retry")

        let retried = await runChunkWave(
            plans: outliers, totalChunks: plans.count,
            sourceAsset: sourceAsset, sourceTrack: sourceTrack,
            originalDuration: originalDuration,
            glossary: glossary, concurrency: concurrency, scratchKey: scratchKey,
            extraInstruction: "\n\nIMPORTANT: transcribe EXACTLY the language actually spoken in this clip. NEVER translate or transliterate into another language.",
            multiSpeaker: multiSpeaker
        )

        for (index, result) in retried {
            guard result.status == .transcribed else { continue }
            let text = strippingGlossaryTerms(result.text, glossary: glossary)
            // Accept only if the retry actually resolved the disagreement. A retry that
            // "succeeded" by translating real speech into the majority language would be a
            // silent corruption of a correct transcript, so anything else keeps the original.
            guard LanguageDetection.dominantLanguage(text) == majority else {
                LogManager.shared.log("🤖 Chunked: chunk \(index) drift retry did not match majority — keeping the original transcript")
                if var previous = outcomes[index] {
                    previous.usage.add(result.usage)
                    previous.latencyMs += result.latencyMs
                    previous.attempts += result.attempts
                    outcomes[index] = previous
                }
                continue
            }
            var merged = result
            if let previous = outcomes[index] {
                merged.usage.add(previous.usage)
                merged.latencyMs += previous.latencyMs
                merged.attempts += previous.attempts
            }
            outcomes[index] = merged
        }
    }

    /// Who Gemini is meant to write down.
    ///
    /// The narrator-only default is not a style choice: a screen recording usually has one
    /// person talking over whatever the Mac is playing, and without this the model dutifully
    /// transcribes the YouTube video in the background. Speaker separation flips it, because
    /// a transcript with the far end of the call stripped out has nobody left to separate.
    /// The exclusions stay either way - a podcast playing in the room is still not a
    /// participant, however many people are.
    static func speakerScopeRules(multiSpeaker: Bool) -> String {
        if multiSpeaker {
            return """
        Transcribe EVERY clearly audible person taking part in this recording - the narrator and anyone they are talking to, including voices coming through the Mac's own audio on a call. Do NOT transcribe:
        - Background voices from TV, radio, podcasts, or videos playing nearby
        - Song lyrics or vocal music
        - Distant, muffled voices that are not taking part in the conversation
        - Side conversations from other people in the room
        """
        }
        return """
        Transcribe ONLY the primary, foreground speaker - the person actively narrating this screen recording. Do NOT transcribe:
        - Background voices from TV, radio, podcasts, or videos playing nearby
        - Song lyrics or vocal music
        - Distant, muffled, or overlapping voices that aren't the main speaker
        - Side conversations from other people in the room
        """
    }

    /// The NO_SPEECH sentinel, phrased for whichever scope is in force. Under multi-speaker
    /// the "no clear PRIMARY speaker" wording would quietly reinstate the narrator-only rule
    /// on every quiet stretch, which is where the far end usually is.
    static func noSpeechRule(multiSpeaker: Bool, unit: String) -> String {
        if multiSpeaker {
            return "If a span of audio has no clearly audible participant, skip it. If the entire \(unit) has none, set `srt` to exactly the string \"NO_SPEECH\"."
        }
        return "If a span of audio has no clear primary speaker, skip it. If the entire \(unit) has no clear primary speaker, set `srt` to exactly the string \"NO_SPEECH\"."
    }

    func combinedPrompt(multiSpeaker: Bool) -> String {
        return """
        You receive an audio track and 3-10 screenshots from a screen recording. Produce a single JSON object with two fields: `srt` and `name`.

        ### `srt` — SRT subtitles
        \(Self.speakerScopeRules(multiSpeaker: multiSpeaker))

        Transcribe VERBATIM in the language actually spoken. Do NOT translate, do NOT transliterate, do NOT summarize, do NOT add commentary. Ukrainian speech stays Ukrainian, Russian speech stays Russian — never convert one into the other, and never render Cyrillic-language speech in Latin script.

        \(Self.noSpeechRule(multiSpeaker: multiSpeaker, unit: "audio"))

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

    /// Transcription-only prompt for one audio chunk of a longer recording.
    ///
    /// Keeps the primary-speaker rules, NO_SPEECH sentinel and formatting block from the
    /// combined prompt verbatim; the `name` half moves to `namingService.namingPrompt`. The clip-relative
    /// timestamp rules are new and critical: the model is told it is part k of n, which is
    /// exactly the framing that can tempt it to emit whole-recording timestamps.
    func chunkTranscriptionPrompt(part: Int, of total: Int, clipSeconds: Double, glossary: [String], multiSpeaker: Bool) -> String {
        let d = String(format: "%.0f", clipSeconds)
        return """
        You receive ONE AUDIO CLIP taken from a longer screen recording (part \(part) of \(total)). Transcribe it as SRT subtitles.

        \(Self.speakerScopeRules(multiSpeaker: multiSpeaker))

        Transcribe VERBATIM in the language actually spoken. Do NOT translate, do NOT transliterate, do NOT summarize, do NOT add commentary. The clip may begin or end mid-sentence — that is expected; transcribe what you hear and do not try to complete or explain it.

        \(Self.noSpeechRule(multiSpeaker: multiSpeaker, unit: "clip"))

        CRITICAL FORMATTING REQUIREMENTS for the `srt` value:
        1. Each subtitle entry MUST be 1-2 sentences only. Maximum 10 seconds per entry.
        2. Entries MUST be separated by a blank line (two consecutive newlines).
        3. Do NOT collapse the entire transcript into a single entry. A 90-second clip should have 8-15 entries, not 1.
        4. Use real newline characters inside the JSON string (encoded as \\n). The decoded SRT must be parseable by standard SRT readers.
        5. Timestamps `HH:MM:SS,mmm --> HH:MM:SS,mmm` are relative to the START OF THIS CLIP — the first moment of audio you receive is 00:00:00,000. Never use timestamps from the wider recording.
        6. This clip is \(d) seconds long. No timestamp may exceed \(d) seconds.

        Exact format (the JSON value of `srt` must look like this when decoded):

        1
        00:00:00,000 --> 00:00:03,200
        First sentence goes here.

        2
        00:00:03,200 --> 00:00:07,800
        Second sentence goes here.
        \(TranscriptionSupport.glossaryBlock(glossary))

        Return strict JSON of the form:
        {"srt":"<srt text or NO_SPEECH>"}
        """
    }

    func parseCombinedResponse(_ raw: String) -> CombinedResponse? {
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

    static let glossaryMaxTerms = 15

    static let glossaryTimeoutNanos: UInt64 = 10_000_000_000

    /// Sanitizes the model's term list: strips fences, drops multi-line or absurdly long
    /// entries, dedupes case-insensitively, and caps the count. Keeps a hallucinated or
    /// malformed response from bloating every chunk prompt.
    static func parseGlossaryTerms(_ raw: String) -> [String] {
        let stripped = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = json["terms"] as? [String] else { return [] }

        var seen = Set<String>()
        var out: [String] = []
        for term in terms {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= 40, !t.contains("\n") else { continue }
            guard seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count >= glossaryMaxTerms { break }
        }
        return out
    }
}
