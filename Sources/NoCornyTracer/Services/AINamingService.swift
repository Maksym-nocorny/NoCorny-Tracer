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
    /// True when retrying the whole run cannot help: the failure was deterministic (oversized
    /// payload, not signed in, bad request), or the chunked path already ran its own internal
    /// retry wave. The caller uses this to skip its outer second pass instead of burning a
    /// full re-run — for an hour-long recording that re-run means re-encoding every chunk.
    var fatal: Bool = false
    /// Chunk accounting for the chunked path (1/0 for the single-call path). Surfaced so a
    /// partial transcript is visible in telemetry rather than silently shipping as complete.
    var totalChunks: Int = 1
    var failedChunks: Int = 0
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

    /// Budget for the base64-ENCODED inline media (audio + frames) in one Gemini request.
    ///
    /// This was 18 MB, sized against Gemini's ~20 MB inline-data cap — but the request never
    /// reaches Gemini. It goes through our Vercel-hosted proxy, whose serverless request-body
    /// limit is 4.5 MB, enforced at the edge before the handler runs. An 18 MB budget meant
    /// the guard could not fire: a 10-minute recording built a ~6.2 MB body and died with
    /// `413 FUNCTION_PAYLOAD_TOO_LARGE`, six times over, producing no title and no transcript.
    ///
    /// Kept slightly under `GeminiProxyClient.maxRequestBodyBytes` so the prompt and JSON
    /// scaffolding fit alongside the media; that client-side check on the exact serialized
    /// body is the real guard, this one is the pre-emptive budget used to degrade gracefully.
    static let maxInlineMediaBytes = 3_800_000

    /// Audio longer than this goes down the chunked path instead of one combined call.
    /// Derived from the real per-call ceilings — the 4.5 MB body limit (~12 min of 32 kbps
    /// audio once base64-encoded) and the 120s client timeout (~20 min at the observed
    /// ~5.4s of processing per minute of audio) — with generous margin. Smaller chunks also
    /// buy better timestamp accuracy, cheaper retries and finer sparse-SRT granularity.
    static let singleCallMaxAudioSeconds: Double = 300

    /// Hard ceiling on the audio in ANY single chunk, whatever else the planner wants.
    ///
    /// At 32 kbps, 600s of audio is ~3.2 MB once base64-encoded — comfortably inside
    /// `maxInlineMediaBytes` with room for the prompt — and ~54s of processing at the observed
    /// ~5.4s per minute, well under both the 120s client timeout and the 300s server limit.
    /// Nothing may raise a chunk past this, including the `maxChunks` runaway guard.
    static let absoluteMaxChunkSeconds: Double = 600

    // MARK: - Configuration

    private let proxyClient: GeminiProxyClient

    init(proxyClient: GeminiProxyClient) {
        self.proxyClient = proxyClient
    }

    /// True when the underlying proxy is ready to make calls (i.e. the user is
    /// signed in to Tracer and a bearer token is available). Surfaced so callers
    /// can skip the whole AI pipeline up front and avoid pointless retries.
    var isReady: Bool { proxyClient.isReady }

    // MARK: - Combined Subtitles + Name Generation

    /// Generates SRT subtitles and a descriptive filename in a single Gemini call.
    /// Audio may be trimmed of silence (and optionally sped up) before sending to reduce
    /// per-second costs. The returned SRT timestamps are mapped back onto the original
    /// recording timeline so they sync perfectly with the unmodified video.
    func generateSubtitlesAndName(for videoURL: URL) async -> NamingResult {
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

        // Step 2.5: long recordings go down the chunked path.
        //
        // The single-call path cannot serve them at any quality setting: at 32 kbps, base64
        // encoding alone puts ~12 minutes of audio over Vercel's 4.5 MB request-body limit,
        // which is enforced before our proxy handler ever runs. Short recordings keep the
        // original, well-tested single-call path unchanged.
        //
        // The threshold is measured against the audio we would actually SEND, not wall-clock
        // duration — `chunkKeptRanges` applies the same trim decision the single-call path
        // makes below, so a mostly-silent 10-minute recording with 2 minutes of speech stays
        // on the cheaper single-call path instead of paying for a separate naming call.
        let totalSamples = Int(analysis.totalDuration * 16000)
        let keptRanges = chunkKeptRanges(analysis: analysis, totalSamples: totalSamples)
        let audioSecondsToSend = Double(keptRanges.reduce(0) { $0 + $1.length }) / 16000.0
        if audioSecondsToSend > Self.effectiveSingleCallThresholdSeconds {
            LogManager.shared.log(
                "🤖 Combined: \(String(format: "%.0f", audioSecondsToSend))s of audio to send exceeds the \(String(format: "%.0f", Self.effectiveSingleCallThresholdSeconds))s single-call threshold — using the chunked path"
            )
            return await generateChunked(
                videoURL: videoURL, audioURL: audioURL,
                analysis: analysis, keptRanges: keptRanges
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

        // Step 5: extract frames (no transcript yet — equispaced).
        var frames = await extractFrames(from: videoURL)
        if frames.isEmpty {
            LogManager.shared.log("🤖 Combined: ⚠️ No frames extracted — proceeding with audio only", type: .error)
        } else {
            LogManager.shared.log("🤖 Combined: Extracted \(frames.count) frames")
        }

        // Step 5.5: budget the ENCODED inline media. The authoritative guard is the exact
        // serialized-body check in GeminiProxyClient; this pre-emptive budget exists so we can
        // degrade gracefully instead of hitting it. Frames shrink first — on a long recording
        // the transcript is the valuable half, so audio is the last thing we give up.
        let audioBase64Bytes = base64Size(audioData.count)
        let framesBudget = Self.maxInlineMediaBytes - audioBase64Bytes
        LogManager.shared.log("🤖 Combined: Payload budget — audio b64=\(audioBase64Bytes / 1024)KB, frames b64=\(encodedSize(frames) / 1024)KB, budget=\(Self.maxInlineMediaBytes / 1024)KB")

        if framesBudget <= 0 {
            // Audio alone blows the budget, so there is nothing left to shrink. Reaching this
            // on the single-call path means the audio was under `singleCallMaxAudioSeconds`
            // yet still too big — unusual, but bail to image-only rather than send a doomed request.
            LogManager.shared.log("🤖 Combined: ❌ Audio alone (\(audioBase64Bytes / 1024)KB b64) exceeds the media budget — falling back to image-only naming", type: .error)
            let fb = await generateNameImageOnly(for: videoURL)
            return NamingResult(srt: nil, name: fb.name, usage: fb.usage, model: fb.model, latencyMs: fb.latencyMs, attempts: fb.attempts, success: fb.name != nil, errorCode: fb.errorCode ?? "audio_too_large")
        }
        frames = fitFramesToBudget(frames, budget: framesBudget)

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

        // Best acceptable result seen so far. A later retry that throws (network drop,
        // proxy error) must NOT discard a perfectly good earlier attempt — we fall back to
        // this instead of returning nil. The latest acceptable attempt overwrites the
        // previous one. restoreSrtTimestamps is computed once at store time and reused.
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
                    LogManager.shared.log("🤖 Combined: ⚠️ Could not parse JSON response: \(raw.prefix(200))", type: .error)
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

                let cleanedName = cleanupName(parsed.name)
                let srtPreview = parsed.srt.prefix(120).replacingOccurrences(of: "\n", with: "⏎")
                LogManager.shared.log("🤖 Combined: Raw SRT (\(parsed.srt.count) chars) preview: \(srtPreview)")

                // Restore the SRT timestamps once for this attempt so it can be stored as the
                // best result (and reused at the success return) without recomputing.
                let restoredSrt = restoreSrtTimestamps(parsed.srt, mapping: mapping, speedupFactor: speedupFactor, originalDuration: analysis.totalDuration)

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
                // never trigger the language-mismatch retry for it. dominantLanguage would
                // otherwise classify the literal "NO_SPEECH" sentinel as English and force a
                // wasteful extra network round-trip.
                let srtLanguage = isExplicitNoSpeech ? nil : dominantLanguage(parsed.srt)
                let nameLanguage = dominantLanguage(cleanedName ?? parsed.name)
                let languageMismatch = !isExplicitNoSpeech && srtLanguage != nil && nameLanguage != nil && srtLanguage != nameLanguage
                if languageMismatch && attempt < maxRetries {
                    let lang = srtLanguage!
                    LogManager.shared.log("🤖 Combined: ⚠️ Language mismatch — SRT is \(lang), name \"\(cleanedName ?? "nil")\" is \(nameLanguage ?? "unknown"). Retrying with \(lang) hint.", type: .error)
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
                LogManager.shared.log("🤖 Combined: ✅ Name: \"\(cleanedName ?? "nil")\", restored SRT length: \(restoredSrt?.count ?? 0)")
                return NamingResult(srt: restoredSrt, name: cleanedName, usage: totalUsage, model: observedModel, latencyMs: totalLatencyMs, attempts: totalAttempts, success: true, errorCode: nil)

            } catch {
                let errorString = "\(error)"
                lastError = String(errorString.prefix(200))
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
                    LogManager.shared.log("🤖 Combined: ⚠️ Attempt \(attempt) failed (\(errorString)) — returning best earlier result \"\(bestName ?? "nil")\"", type: .error)
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

    // MARK: - Chunked Transcription (long recordings)

    /// Internal (not private) so `planChunks` — a pure, deterministic function that is the
    /// single most test-worthy piece of the chunked path — stays reachable from tests.
    struct SampleRange {
        var start: Int
        var end: Int
        var length: Int { end - start }
    }

    struct PlannedChunk {
        let index: Int
        let ranges: [SampleRange]
        var speechSamples: Int { ranges.reduce(0) { $0 + $1.length } }
        var speechSeconds: Double { Double(speechSamples) / 16000.0 }
    }

    private struct ChunkTuning {
        let targetSamples: Int
        let maxSamples: Int
        let minSliverSamples: Int
        let overlapSamples: Int
        let maxChunks: Int
        let maxConcurrent: Int

        static var current: ChunkTuning {
            let target = effectiveChunkTargetSeconds
            return ChunkTuning(
                targetSamples: Int(target * 16000),
                maxSamples: Int(target * 1.4 * 16000),
                minSliverSamples: Int(min(20, target * 0.1) * 16000),
                overlapSamples: Int(1.5 * 16000),
                maxChunks: 60,
                // Three concurrent calls keeps an hour-long recording at ~4 waves while
                // limiting exposure to Gemini's 503 "high demand" responses, which we see
                // in production. More parallelism buys little and multiplies that risk.
                maxConcurrent: 3
            )
        }
    }

    /// Debug override lets a 3-minute recording exercise the full chunked path in ~60s
    /// instead of needing a real hour-long asset.
    static var effectiveChunkTargetSeconds: Double {
        let override = UserDefaults.standard.double(forKey: "NCTChunkTargetSecondsOverride")
        return override > 0 ? override : singleCallMaxAudioSeconds
    }

    static var effectiveSingleCallThresholdSeconds: Double {
        let override = UserDefaults.standard.double(forKey: "NCTChunkTargetSecondsOverride")
        return override > 0 ? override * 0.67 : singleCallMaxAudioSeconds
    }

    /// Splits speech ranges into chunks, preferring cuts at VAD pauses.
    ///
    /// Cutting at a range boundary is always safe: `analyzeSpeech` pads every segment with
    /// 200ms of silence on both sides and merges gaps under 800ms, so at least 400ms of real
    /// silence separates adjacent ranges. A chunk therefore ends in silence and the next
    /// begins in silence — no overlap needed. Overlap is introduced ONLY when a single range
    /// is longer than one chunk and must be cut mid-speech.
    ///
    /// Pure and deterministic so it can be unit-tested without any AV or network work.
    func planChunks(
        keptRanges: [SampleRange],
        targetSamples: Int,
        maxSamples: Int,
        minSliverSamples: Int,
        overlapSamples: Int,
        maxChunks: Int
    ) -> [PlannedChunk] {
        var queue = keptRanges.filter { $0.length > 0 }
        guard !queue.isEmpty, targetSamples > 0, maxSamples > 0 else { return [] }

        let total = queue.reduce(0) { $0 + $1.length }

        // Cap the chunk count by RAISING the target, never by dropping the tail — but the
        // payload ceiling wins over the chunk-count cap. `maxChunks` is a runaway guard, not a
        // product limit: exceeding it costs extra requests, whereas exceeding the request-body
        // limit costs the whole transcript (a 413 the server never even sees). An 8-hour
        // recording would otherwise be pushed to ~11-minute chunks that sit right against the
        // budget, so clamp hard and let the chunk count grow instead.
        let hardMaxSamples = Int(Self.absoluteMaxChunkSeconds * 16000)
        var target = min(targetSamples, hardMaxSamples)
        var maxPer = min(maxSamples, hardMaxSamples)
        if maxChunks > 0 {
            let projected = Int(ceil(Double(total) / Double(target)))
            if projected > maxChunks {
                target = min(hardMaxSamples, Int(ceil(Double(total) / Double(maxChunks))))
                maxPer = min(hardMaxSamples, max(maxPer, Int(Double(target) * 1.4)))
                let stillProjected = Int(ceil(Double(total) / Double(target)))
                if stillProjected > maxChunks {
                    LogManager.shared.log(
                        "🤖 Chunks: ⚠️ \(total / 16000)s of speech needs \(stillProjected) chunks, over the \(maxChunks) cap — proceeding anyway; the payload ceiling (\(Int(Self.absoluteMaxChunkSeconds))s/chunk) takes precedence over the cap",
                        type: .error
                    )
                } else {
                    LogManager.shared.log(
                        "🤖 Chunks: ⚠️ \(projected) chunks would exceed the \(maxChunks) cap — raising target to \(target / 16000)s/chunk",
                        type: .error
                    )
                }
            }
        }
        guard target > 0, maxPer > 0 else { return [] }

        var chunks: [PlannedChunk] = []
        var current: [SampleRange] = []
        var acc = 0
        var remaining = total

        // Recomputed after every cut so overlap re-queues don't let the target drift.
        func evenTarget() -> Int {
            guard remaining > 0 else { return target }
            let n = max(1, Int(ceil(Double(remaining) / Double(target))))
            return max(1, Int(ceil(Double(remaining) / Double(n))))
        }

        func closeChunk() {
            guard !current.isEmpty else { return }
            chunks.append(PlannedChunk(index: chunks.count, ranges: current))
            remaining -= acc
            current = []
            acc = 0
        }

        var i = 0
        while i < queue.count {
            let r = queue[i]
            if r.length <= 0 { i += 1; continue }

            if acc + r.length <= maxPer {
                current.append(r)
                acc += r.length
                i += 1
                if acc >= evenTarget() { closeChunk() }
                continue
            }

            let capacity = maxPer - acc
            // Not enough room left for a worthwhile slice — close and retry in a fresh chunk.
            // Guarded on acc > 0 so a fresh chunk always makes progress (no infinite loop).
            if acc > 0 && capacity < minSliverSamples {
                closeChunk()
                continue
            }

            // Forced mid-speech cut: the only place overlap is introduced.
            let cut = r.start + capacity
            current.append(SampleRange(start: r.start, end: cut))
            acc += capacity
            closeChunk()
            queue[i] = SampleRange(start: max(r.start, cut - overlapSamples), end: r.end)
        }
        closeChunk()

        return chunks
    }

    /// Chooses which sample ranges the chunked path transcribes, preserving today's trim
    /// semantics exactly: VAD speech segments when trimming would apply, otherwise the whole
    /// timeline. Note the >0.95 bail means a continuously-narrated recording — the profile of
    /// both production failures — takes the whole-timeline branch.
    private func chunkKeptRanges(analysis: SpeechAnalysis, totalSamples: Int) -> [SampleRange] {
        let speechSeconds = analysis.totalSpeechDuration
        let fraction = analysis.totalDuration > 0 ? speechSeconds / analysis.totalDuration : 1.0

        if Self.enableTrimSilence, !analysis.segments.isEmpty,
           fraction <= 0.95, fraction >= 0.05, speechSeconds >= 5.0 {
            return analysis.segments.map { SampleRange(start: $0.startSamples, end: $0.endSamples) }
        }
        return wholeTimelineRanges(segments: analysis.segments, totalSamples: totalSamples)
    }

    /// Covers the whole timeline with contiguous ranges whose boundaries sit in the middle of
    /// each silence gap. `planChunks` only cuts at range boundaries, so this hands it natural
    /// pause positions to prefer WITHOUT dropping any audio — the union is still [0, total].
    private func wholeTimelineRanges(segments: [SpeechSegment], totalSamples: Int) -> [SampleRange] {
        guard totalSamples > 0 else { return [] }
        guard segments.count > 1 else { return [SampleRange(start: 0, end: totalSamples)] }

        var ranges: [SampleRange] = []
        var cursor = 0
        for i in 0..<(segments.count - 1) {
            let gapStart = segments[i].endSamples
            let gapEnd = segments[i + 1].startSamples
            guard gapEnd > gapStart else { continue }
            let boundary = min(totalSamples, (gapStart + gapEnd) / 2)
            if boundary > cursor {
                ranges.append(SampleRange(start: cursor, end: boundary))
                cursor = boundary
            }
        }
        if cursor < totalSamples {
            ranges.append(SampleRange(start: cursor, end: totalSamples))
        }
        return ranges
    }

    private struct AudioChunk {
        let index: Int
        let url: URL
        /// Chunk-LOCAL mapping: `stitchedStart` begins at 0, so `mapSegments` lands cues
        /// directly on the original timeline with no offset arithmetic anywhere.
        let mapping: [TimestampMapping]
        let localDuration: Double
        let speechSeconds: Double
        /// Always 1.0 today. Carried explicitly rather than hardcoded at the merge so that
        /// enabling `enableSpeedUp` later cannot silently desync timestamps — a factor
        /// mismatch produces uniformly compressed, in-bounds cues that no bounds check catches.
        let speedupFactor: Double
    }

    /// Builds one chunk's audio as a composition over the original extracted track, encoded
    /// with the same 32 kbps/16 kHz/mono settings as the full-file path.
    private func buildChunkAudio(sourceAsset: AVAsset, sourceTrack: AVAssetTrack, plan: PlannedChunk) async -> AudioChunk? {
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

    private struct ChunkResult {
        enum Status { case transcribed, noSpeech, failed }
        let index: Int
        var status: Status
        /// Segments already mapped onto the ORIGINAL recording timeline.
        var segments: [SrtSegment] = []
        /// Plain cue text, used for per-chunk language detection.
        var text: String = ""
        var usage = GeminiUsage.zero
        var latencyMs = 0
        var attempts = 0
        var model: String? = nil
        var errorCode: String? = nil
        /// Failure that retrying cannot fix — excluded from the targeted retry wave.
        var fatal = false
    }

    /// Exponential backoff with jitter. Concurrent chunks that all catch a Gemini 503 would
    /// otherwise retry in lockstep and hit it again at exactly the same instant.
    private func jitteredDelayNanos(_ seconds: Double) -> UInt64 {
        UInt64(max(0.1, seconds * Double.random(in: 0.75...1.25)) * 1_000_000_000)
    }

    /// Strips markdown fences and pulls one string field out of a JSON response.
    private func parseJSONStringField(_ raw: String, field: String) -> String? {
        let stripped = raw
            .replacingOccurrences(of: "```json\n", with: "")
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```\n", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[field] as? String else { return nil }
        return value
    }

    private func transcribeChunk(
        _ chunk: AudioChunk,
        totalChunks: Int,
        originalDuration: Double,
        glossary: [String],
        extraInstruction: String = ""
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
                clipSeconds: chunk.localDuration, glossary: glossary
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

                guard let rawSrt = parseJSONStringField(response.text, field: "srt") else {
                    result.errorCode = "chunk_parse_failed"
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the response was not strict JSON of the form {\"srt\":\"...\"}. Return JSON only, with no prose around it."
                        try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay)); delay *= 2
                        continue
                    }
                    return result
                }

                if rawSrt.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("NO_SPEECH") {
                    result.status = .noSpeech
                    result.errorCode = nil
                    return result
                }

                let localSegments = parseAndRepairSrt(rawSrt)
                guard !localSegments.isEmpty else {
                    result.errorCode = "chunk_unparseable_srt"
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the SRT could not be parsed. Follow the exact format shown, with a blank line between entries."
                        try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay)); delay *= 2
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
                        try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay)); delay *= 2
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
                    try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay)); delay *= 2
                    continue
                }

                let (mapped, oob) = mapSegments(
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
                        try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay)); delay *= 2
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
                result.errorCode = String("\(error)".prefix(200))
                if !isRetryableError(error) {
                    result.fatal = true
                    LogManager.shared.log("🤖 Chunk \(chunk.index): ❌ Non-retryable (\(error))", type: .error)
                    return result
                }
                if attempt < maxAttempts {
                    LogManager.shared.log("🤖 Chunk \(chunk.index): ⏳ attempt \(attempt) failed (\(error)), retrying...", type: .error)
                    try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay))
                    delay *= 2
                }
            }
        }
        return result
    }

    /// Merges per-chunk segments (already on the original timeline) into one ordered list.
    private func mergeChunkSegments(_ results: [ChunkResult]) -> [SrtSegment] {
        var all = results.filter { $0.status == .transcribed }.flatMap(\.segments)
        guard !all.isEmpty else { return [] }
        all.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        var kept: [SrtSegment] = []
        for seg in all {
            guard let prev = kept.last else { kept.append(seg); continue }
            // Duplicate from an overlap window — only forced mid-speech cuts create these.
            if seg.start < prev.end - 0.2, normalizedForDedupe(seg.text) == normalizedForDedupe(prev.text) {
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

    private func normalizedForDedupe(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Runs a set of chunk plans through build + transcribe with a sliding-window task group.
    ///
    /// Chunk audio is built lazily inside each task so at most `concurrency` AAC encodes run
    /// at once — building all of them up front would spike CPU and disk for an hour-long file.
    private func runChunkWave(
        plans: [PlannedChunk],
        totalChunks: Int,
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        glossary: [String],
        concurrency: Int,
        scratchKey: String,
        extraInstruction: String = ""
    ) async -> [Int: ChunkResult] {
        var outcomes: [Int: ChunkResult] = [:]
        guard !plans.isEmpty else { return outcomes }

        await withTaskGroup(of: ChunkResult.self) { group in
            var next = 0

            // Both loops are inlined deliberately: a nested helper capturing the `inout`
            // TaskGroup does not compile.
            while next < min(concurrency, plans.count) {
                let plan = plans[next]
                next += 1
                group.addTask { [self] in
                    await runOneChunk(plan: plan, totalChunks: totalChunks, sourceAsset: sourceAsset,
                                      sourceTrack: sourceTrack, originalDuration: originalDuration,
                                      glossary: glossary, extraInstruction: extraInstruction)
                }
            }

            while let outcome = await group.next() {
                outcomes[outcome.index] = outcome
                persistChunkScratch(key: scratchKey, result: outcome)
                if next < plans.count {
                    let plan = plans[next]
                    next += 1
                    group.addTask { [self] in
                        await runOneChunk(plan: plan, totalChunks: totalChunks, sourceAsset: sourceAsset,
                                          sourceTrack: sourceTrack, originalDuration: originalDuration,
                                          glossary: glossary, extraInstruction: extraInstruction)
                    }
                }
            }
        }
        return outcomes
    }

    private func runOneChunk(
        plan: PlannedChunk,
        totalChunks: Int,
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        glossary: [String],
        extraInstruction: String
    ) async -> ChunkResult {
        guard let chunk = await buildChunkAudio(sourceAsset: sourceAsset, sourceTrack: sourceTrack, plan: plan) else {
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
            glossary: glossary, extraInstruction: extraInstruction
        )
    }

    /// Persists a chunk's mapped segments as it completes.
    ///
    /// Chunk results otherwise live only in memory, so a crash at chunk 11 of 12 discards
    /// nearly an hour of already-paid transcription with no trace. Cheap insurance, and the
    /// seed for a future resume.
    private func persistChunkScratch(key: String, result: ChunkResult) {
        guard result.status == .transcribed, let srt = serializeSrt(result.segments) else { return }
        let dir = chunkScratchDirectory(key: key)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(String(format: "chunk-%03d.srt", result.index))
        try? srt.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Drops the scratch directory once the merged transcript exists — it is only useful
    /// while a run is in flight or after one died partway.
    private func clearChunkScratch(key: String) {
        try? FileManager.default.removeItem(at: chunkScratchDirectory(key: key))
    }

    private func chunkScratchDirectory(key: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nct-chunks", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    // MARK: - Frames-first Glossary (cross-chunk context)

    private struct GlossaryResult {
        var terms: [String] = []
        var usage = GeminiUsage.zero
        var latencyMs = 0
        var attempts = 0
        var model: String? = nil
    }

    private static let glossaryMaxTerms = 15
    private static let glossaryTimeoutNanos: UInt64 = 10_000_000_000

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
    private func buildFrameGlossary(frames: [Data]) async -> GlossaryResult {
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
        LogManager.shared.log("🤖 Glossary: \(result.terms.count) terms — \(result.terms.joined(separator: ", "))")
        return result
    }

    /// Sanitizes the model's term list: strips fences, drops multi-line or absurdly long
    /// entries, dedupes case-insensitively, and caps the count. Keeps a hallucinated or
    /// malformed response from bloating every chunk prompt.
    private static func parseGlossaryTerms(_ raw: String) -> [String] {
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

    /// Removes glossary terms from text before language classification.
    ///
    /// `dominantLanguage` is a raw Latin-vs-Cyrillic character count, so correctly-spelled
    /// Latin tech terms — the glossary's SUCCESS case — inflate the Latin side and can
    /// misclassify a jargon-heavy Ukrainian chunk as English, firing a pointless drift retry
    /// whose re-transcription may well be worse than what it replaced.
    private func strippingGlossaryTerms(_ text: String, glossary: [String]) -> String {
        guard !glossary.isEmpty else { return text }
        var out = text
        for term in glossary {
            out = out.replacingOccurrences(of: term, with: " ", options: [.caseInsensitive])
        }
        return out
    }

    // MARK: - Naming from Transcript

    private struct NamingCallResult {
        var name: String?
        var usage = GeminiUsage.zero
        var latencyMs = 0
        var attempts = 0
        var model: String? = nil
        var errorCode: String? = nil
        var fatal = false
    }

    private static let maxNamingTranscriptChars = 40_000

    /// Builds the transcript text for the naming call: plain cue text, no timestamps
    /// (~40% of SRT bytes and useless for naming). Over-long transcripts are sampled with an
    /// even stride so the title reflects the whole recording, not just the intro.
    private func namingTranscriptText(_ segments: [SrtSegment]) -> String {
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
    /// `dominantLanguage` reports ANY Latin-majority text as "English" by design, so naming
    /// the language unconditionally would command an English title for Polish/Spanish/etc
    /// narration — and the mismatch retry could never catch it, since it would be comparing
    /// two outputs of the same labeller. Ukrainian vs Russian is the case that genuinely
    /// needs naming: both are Cyrillic, so a script check alone cannot separate them.
    private func namingLanguageHint(for transcript: String) -> String? {
        guard let language = dominantLanguage(transcript),
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

    private func generateNameFromTranscript(
        transcript: String,
        frames: [Data],
        glossary: [String]
    ) async -> NamingCallResult {
        var result = NamingCallResult()

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
        let transcriptScript = dominantScript(transcript)
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

                guard let rawName = parseJSONStringField(response.text, field: "name"),
                      let cleaned = cleanupName(rawName) else {
                    result.errorCode = "naming_parse_failed"
                    if attempt < maxAttempts {
                        hint = "\n\nPRIOR ATTEMPT FAILED: the response was not strict JSON of the form {\"name\":\"...\"}. Return JSON only."
                        try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay)); delay *= 2
                        continue
                    }
                    return result
                }

                // Language check by SCRIPT, comparing the name against the transcript — two
                // independent signals. Comparing `dominantLanguage(name)` against the label we
                // injected into the prompt would be a tautology: if the label were wrong and
                // Gemini obeyed it, the check would pass every time.
                //
                // `.mixed` is NOT a mismatch. A Ukrainian title carrying Latin product names
                // ("Редизайн UI сайту у Figma") is correct, and `dominantScript` needs 85%
                // Cyrillic before it says `.cyrillic` — two or three Latin words in a short
                // title push it under that line. Only the opposite PURE script means Gemini
                // actually translated the title out of the spoken language.
                let nameScript = dominantScript(cleaned)
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
                    LogManager.shared.log("🤖 Naming: ⚠️ name script \(nameScript) ≠ transcript script \(transcriptScript) — one retry with hint, holding \"\(cleaned)\"", type: .error)
                    let target = language ?? (transcriptScript == .cyrillic ? "the transcript's language" : "the transcript's language")
                    hint = "\n\nPRIOR ATTEMPT FAILED: the returned `name` was in the wrong language. Write the `name` in \(target), matching the transcript. Do NOT translate it into English or any other language."
                    try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay)); delay *= 2
                    continue
                }
                if mismatch {
                    LogManager.shared.log("🤖 Naming: ⚠️ language still mismatched — accepting \"\(cleaned)\" rather than losing the title", type: .error)
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
                    try? await Task.sleep(nanoseconds: jitteredDelayNanos(delay))
                    delay *= 2
                }
            }
        }
        return result
    }

    // MARK: - Chunked Orchestration

    /// Transcribes a long recording as parallel chunks, then names it from the merged
    /// transcript plus screenshots.
    ///
    /// Chunking exists because the proxy runs on Vercel, whose 4.5 MB request-body limit is
    /// enforced at the edge before the handler runs. A one-hour recording cannot be sent in a
    /// single call at any quality setting, and no server-side change can make it possible.
    private func generateChunked(
        videoURL: URL,
        audioURL: URL,
        analysis: SpeechAnalysis,
        keptRanges: [SampleRange]
    ) async -> NamingResult {
        // Chunk audio is always built at 1.0×. Enabling `enableSpeedUp` requires threading the
        // factor through buildChunkAudio AND the merge — a mismatch yields uniformly
        // compressed, in-bounds timestamps that no bounds check can detect.
        assert(!Self.enableSpeedUp, "Chunked path assumes speedupFactor 1.0")

        var usage = GeminiUsage.zero
        var latencyMs = 0
        var attempts = 0
        var model = "gemini-2.5-flash-lite"
        let scratchKey = videoURL.deletingPathExtension().lastPathComponent

        func imageOnlyFallback(_ code: String, totalChunks: Int = 1, failedChunks: Int = 0) async -> NamingResult {
            let fb = await generateNameImageOnly(for: videoURL)
            usage.add(fb.usage)
            return NamingResult(
                srt: nil, name: fb.name, usage: usage, model: fb.model,
                latencyMs: latencyMs + fb.latencyMs, attempts: attempts + fb.attempts,
                success: fb.name != nil, errorCode: fb.errorCode ?? code, fatal: true,
                totalChunks: totalChunks, failedChunks: failedChunks
            )
        }

        let tuning = ChunkTuning.current
        let plans = planChunks(
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
        guard let sourceTrack = try? await sourceAsset.loadTracks(withMediaType: .audio).first else {
            LogManager.shared.log("🤖 Chunked: ❌ Could not load the extracted audio track", type: .error)
            return await imageOnlyFallback("chunk_source_track_missing")
        }

        LogManager.shared.log(
            "🤖 Chunked: \(plans.count) chunks (target \(tuning.targetSamples / 16000)s, max \(tuning.maxSamples / 16000)s), concurrency \(tuning.maxConcurrent)"
        )

        // Frames feed both the glossary call and the naming call.
        let frames = fitFramesToBudget(await extractFrames(from: videoURL), budget: Self.maxInlineMediaBytes)

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
            glossary: glossary, concurrency: tuning.maxConcurrent, scratchKey: scratchKey
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
                glossary: glossary, concurrency: tuning.maxConcurrent, scratchKey: scratchKey
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
            glossary: glossary, concurrency: tuning.maxConcurrent, scratchKey: scratchKey
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
        let mergedSrt = merged.isEmpty ? nil : serializeSrt(merged)

        // Tier 2 of the out-of-bounds policy: a transcript survives as long as ANY chunk
        // produced usable cues. Per-chunk judgement already dropped the corrupted ones, so
        // there is no global ratio that can discard healthy chunks' work.
        guard let srt = mergedSrt, !merged.isEmpty else {
            let allNoSpeech = results.allSatisfy { $0.status == .noSpeech } && !results.isEmpty
            if allNoSpeech {
                // Mirrors today's NO_SPEECH behaviour exactly: no transcript, name from frames.
                // Routed here rather than through the transcript+frames naming call because an
                // empty transcript gives `dominantLanguage` nothing to work with.
                LogManager.shared.log("🤖 Chunked: 🤫 every chunk reported NO_SPEECH — image-only naming")
                return await imageOnlyFallback("no_speech", totalChunks: plans.count, failedChunks: failedChunks)
            }
            LogManager.shared.log("🤖 Chunked: ❌ No usable transcript from any chunk", type: .error)
            return await imageOnlyFallback("chunks_all_failed", totalChunks: plans.count, failedChunks: failedChunks)
        }
        clearChunkScratch(key: scratchKey)

        // Naming from the merged transcript + frames.
        let transcriptText = namingTranscriptText(merged)
        let naming = await generateNameFromTranscript(
            transcript: transcriptText, frames: frames, glossary: glossary
        )
        usage.add(naming.usage)
        latencyMs += naming.latencyMs
        attempts += naming.attempts
        if let m = naming.model { model = m }

        // errorCode precedence: the most user-visible loss wins.
        var errorCode: String? = nil
        if failedChunks > 0 {
            errorCode = "partial_chunks_failed_\(failedChunks)_of_\(plans.count)"
        } else if naming.name == nil {
            errorCode = naming.errorCode ?? "naming_failed"
        }

        // success is telemetry, not a gate on storing data: a holey transcript is still saved
        // and still generates a description. It reports false when we lost most of the speech.
        let success = (speechCoverage >= 0.5) || naming.name != nil

        LogManager.shared.log(
            "🤖 Chunked: ✅ name=\"\(naming.name ?? "nil")\", srt \(srt.count) chars from \(merged.count) cues"
        )

        return NamingResult(
            srt: srt, name: naming.name, usage: usage, model: model,
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
    private func resolveLanguageDrift(
        outcomes: inout [Int: ChunkResult],
        plans: [PlannedChunk],
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        glossary: [String],
        concurrency: Int,
        scratchKey: String
    ) async {
        var weights: [String: Double] = [:]
        var languageByIndex: [Int: String] = [:]

        for plan in plans {
            guard let outcome = outcomes[plan.index], outcome.status == .transcribed else { continue }
            // Strip glossary terms first: correctly-spelled Latin tech terms are the
            // glossary's success case, and they would otherwise tip the Latin/Cyrillic count.
            let text = strippingGlossaryTerms(outcome.text, glossary: glossary)
            guard let language = dominantLanguage(text) else { continue }
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
            extraInstruction: "\n\nIMPORTANT: transcribe EXACTLY the language actually spoken in this clip. NEVER translate or transliterate into another language."
        )

        for (index, result) in retried {
            guard result.status == .transcribed else { continue }
            let text = strippingGlossaryTerms(result.text, glossary: glossary)
            // Accept only if the retry actually resolved the disagreement. A retry that
            // "succeeded" by translating real speech into the majority language would be a
            // silent corruption of a correct transcript, so anything else keeps the original.
            guard dominantLanguage(text) == majority else {
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

        let extracted = await extractFrames(from: videoURL)
        // This is the fallback everything else lands on, so it MUST fit the budget on its own:
        // 10 text-heavy screenshots at full quality can exceed the whole request budget, which
        // would 413 the very path meant to rescue a failed run.
        let frames = fitFramesToBudget(extracted, budget: Self.maxInlineMediaBytes)
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
                LogManager.shared.log("🤖 Naming (image-only): ✅ \"\(cleaned ?? "nil")\"")
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

        Transcribe VERBATIM in the language actually spoken. Do NOT translate, do NOT transliterate, do NOT summarize, do NOT add commentary. Ukrainian speech stays Ukrainian, Russian speech stays Russian — never convert one into the other, and never render Cyrillic-language speech in Latin script.

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

    /// Renders the shared spelling-reference block injected into chunk and naming prompts.
    ///
    /// The last two sentences are load-bearing guards, not politeness: without "never insert",
    /// a glossary term can be force-matched onto acoustically similar speech; without the
    /// language disclaimer, a Latin-heavy term list biases Gemini into transcribing Cyrillic
    /// narration as English — the exact failure the web's description prompt already hit.
    private func glossaryBlock(_ terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        return """


        SPELLING REFERENCE — names visible on screen in this recording: \(terms.joined(separator: ", ")).
        If the speaker SAYS one of these names, spell it exactly as listed (keep Latin spellings even inside Cyrillic sentences).
        NEVER insert a listed word that is not actually spoken; transcribe unclear speech as heard.
        This list does NOT indicate the audio language — use the language actually spoken.
        """
    }

    /// Transcription-only prompt for one audio chunk of a longer recording.
    ///
    /// Keeps the primary-speaker rules, NO_SPEECH sentinel and formatting block from the
    /// combined prompt verbatim; the `name` half moves to `namingPrompt`. The clip-relative
    /// timestamp rules are new and critical: the model is told it is part k of n, which is
    /// exactly the framing that can tempt it to emit whole-recording timestamps.
    private func chunkTranscriptionPrompt(part: Int, of total: Int, clipSeconds: Double, glossary: [String]) -> String {
        let d = String(format: "%.0f", clipSeconds)
        return """
        You receive ONE AUDIO CLIP taken from a longer screen recording (part \(part) of \(total)). Transcribe it as SRT subtitles.

        Transcribe ONLY the primary, foreground speaker — the person actively narrating this screen recording. Do NOT transcribe:
        - Background voices from TV, radio, podcasts, or videos playing nearby
        - Song lyrics or vocal music
        - Distant, muffled, or overlapping voices that aren't the main speaker
        - Side conversations from other people in the room

        Transcribe VERBATIM in the language actually spoken. Do NOT translate, do NOT transliterate, do NOT summarize, do NOT add commentary. The clip may begin or end mid-sentence — that is expected; transcribe what you hear and do not try to complete or explain it.

        If a span of audio has no clear primary speaker, skip it. If the entire clip has no clear primary speaker, set `srt` to exactly the string "NO_SPEECH".

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
        \(glossaryBlock(glossary))

        Return strict JSON of the form:
        {"srt":"<srt text or NO_SPEECH>"}
        """
    }

    /// Naming prompt for the chunked path: the title is derived from the merged transcript
    /// plus screenshots, since no single call has heard the whole recording.
    ///
    /// `language` is injected only when local detection is confident (see `namingLanguageHint`).
    /// When it's nil we fall back to the original audio-derived wording — `dominantLanguage`
    /// reports ANY Latin-script text as "English", so naming a language on that basis would
    /// order an English title for e.g. Polish narration.
    private func namingPrompt(transcript: String, language: String?, glossary: [String]) -> String {
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
        \(glossaryBlock(glossary))

        TRANSCRIPT:
        \(transcript)

        Return strict JSON of the form:
        {"name":"<filename>"}
        """
    }

    /// Maximum length of a cleaned name. The prompt targets a 4-8 word filename; 80 chars
    /// gives generous slack while keeping the user-visible title from ballooning if Gemini
    /// returns a whole sentence.
    private static let maxNameLength = 80

    private func cleanupName(_ raw: String) -> String? {
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

    /// Best-effort dominant-language detection — finer-grained than `dominantScript`.
    /// Within Cyrillic, distinguishes Russian vs Ukrainian by language-specific letter
    /// markers (ї/є/ґ → Ukrainian; ы/э/ъ/ё → Russian); otherwise defaults to Russian
    /// for unmarked Cyrillic. Latin always returns "English" — we don't try to tell
    /// English apart from Spanish/French/etc.
    ///
    /// Returns nil for too-short or unclassifiable input. Used to detect cases like
    /// Russian narration getting a Ukrainian title (both Cyrillic — `dominantScript`
    /// flags them as a match even though the language is wrong).
    func dominantLanguage(_ s: String) -> String? {
        var latin = 0
        var cyrillic = 0
        var hasUkrainianMarker = false
        var hasRussianMarker = false
        for u in s.unicodeScalars {
            let v = u.value
            if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
                latin += 1
            } else if (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F) {
                cyrillic += 1
                // Ukrainian-only letters: і І ї Ї є Є ґ Ґ
                if v == 0x0456 || v == 0x0406 || v == 0x0457 || v == 0x0407
                    || v == 0x0454 || v == 0x0404 || v == 0x0491 || v == 0x0490 {
                    hasUkrainianMarker = true
                }
                // Russian-only letters: ы Ы э Э ъ Ъ ё Ё
                if v == 0x044B || v == 0x042B || v == 0x044D || v == 0x042D
                    || v == 0x044A || v == 0x042A || v == 0x0451 || v == 0x0401 {
                    hasRussianMarker = true
                }
            }
        }
        let total = latin + cyrillic
        guard total >= 5 else { return nil }
        if cyrillic > latin {
            if hasUkrainianMarker && !hasRussianMarker { return "Ukrainian" }
            if hasRussianMarker && !hasUkrainianMarker { return "Russian" }
            if hasUkrainianMarker { return "Ukrainian" }
            // Cyrillic but no language-specific markers — default to Russian
            // (more common globally; safer fallback than mis-tagging as Ukrainian).
            return "Russian"
        }
        return "English"
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
        let segments = parseAndRepairSrt(srt)
        guard !segments.isEmpty else { return nil }

        let (mapped, outOfBoundsCount) = mapSegments(
            segments, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration
        )

        if outOfBoundsCount > segments.count / 5 {
            LogManager.shared.log("🤖 Trim: ⚠️ \(outOfBoundsCount)/\(segments.count) timestamps out of bounds — discarding SRT", type: .error)
            return nil
        }

        return serializeSrt(mapped)
    }

    /// Parses a raw Gemini SRT payload into segments, applying the whole recovery ladder:
    /// blank-line normalization, regex recovery for unparseable output, inline-timestamp
    /// splitting, and sentence-splitting of over-long entries. Returns [] for empty /
    /// NO_SPEECH / unrecoverable input.
    ///
    /// Split out of `restoreSrtTimestamps` so the chunked path can parse each chunk on its
    /// own before mapping — the repairs are per-response and must run before any merge.
    private func parseAndRepairSrt(_ srt: String) -> [SrtSegment] {
        let trimmed = srt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "NO_SPEECH" {
            return []
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
            return []
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
        return splitSegments
    }

    /// Maps segments from the AI's timeline onto the original recording timeline, returning
    /// the mapped segments plus a count of entries whose timestamps landed out of bounds.
    ///
    /// The caller decides what to do with `outOfBounds` — the single-call path discards the
    /// whole SRT past a threshold, while the chunked path judges each chunk separately so one
    /// bad chunk cannot destroy the others' work.
    private func mapSegments(
        _ segments: [SrtSegment],
        mapping: [TimestampMapping],
        speedupFactor: Double,
        originalDuration: Double
    ) -> (segments: [SrtSegment], outOfBounds: Int) {
        var mapped: [SrtSegment] = []
        var outOfBoundsCount = 0

        for seg in segments {
            let mappedStart = mapTimestamp(seg.start, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration)
            let mappedEnd = mapTimestamp(seg.end, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration)

            if mappedEnd <= mappedStart { outOfBoundsCount += 1; continue }
            if mappedStart < 0 || mappedEnd > originalDuration + 0.5 { outOfBoundsCount += 1 }

            let clampedStart = max(0, mappedStart)
            let clampedEnd = min(originalDuration, mappedEnd)
            if clampedEnd <= clampedStart { continue }

            mapped.append(SrtSegment(start: clampedStart, end: clampedEnd, text: seg.text))
        }

        return (mapped, outOfBoundsCount)
    }

    /// Renders segments as a standard SRT file, numbering entries from 1. Any index values
    /// from the source are irrelevant — both our parser and the web's ignore them — so the
    /// chunked path can concatenate segments freely and let this assign final numbering.
    private func serializeSrt(_ segments: [SrtSegment]) -> String? {
        var lines: [String] = []
        var idx = 1
        for seg in segments {
            lines.append("\(idx)")
            lines.append("\(formatSrtTimestamp(seg.start)) --> \(formatSrtTimestamp(seg.end))")
            lines.append(seg.text)
            lines.append("")
            idx += 1
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Strip the trailing entry-index that belongs to the NEXT cue — but only when
            // there actually IS a next cue, and only a digit run that stands alone after
            // whitespace (or is the entire slice). This preserves meaningful trailing digits
            // like "port 8080" or "error code 500" — especially in the final cue, which has
            // no following index to remove.
            if i + 1 < matches.count {
                text = text.replacingOccurrences(of: #"(?:^|\s)\d{1,4}\s*$"#, with: "", options: .regularExpression)
            }
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

        // Capture any residual text after the last terminal-punctuation match — a trailing
        // fragment with no closing "." / "!" / "?" would otherwise be silently dropped (the
        // regex only matches up to the last terminator). Append it so its characters are
        // counted and it gets a proportional time slice.
        if let lastMatch = matches.last {
            let lastMatchEnd = lastMatch.range.location + lastMatch.range.length
            if lastMatchEnd < nstext.length {
                let tail = nstext.substring(from: lastMatchEnd).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    sentences.append(tail)
                    totalChars += tail.count
                }
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
    private func encodeSpeechAudio(from asset: AVAsset, sourceTrack: AVAssetTrack) async -> URL? {
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

    // MARK: - Frame Extraction

    /// Extracts frames at evenly spaced timestamps. 1024×1024 max resolution: still readable
    /// for code/UI screenshots, ~55% fewer image tokens than 1568.
    private func extractFrames(from videoURL: URL) async -> [Data] {
        let asset = AVAsset(url: videoURL)
        let durationSeconds = CMTimeGetSeconds(asset.duration)

        guard durationSeconds > 0 else { return [] }

        let timestamps = pickTimestamps(duration: durationSeconds)
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

    // MARK: - Frame Budgeting

    /// Base64 inflates raw bytes by 4/3 (ceil division). Every size check against the request
    /// budget must use the ENCODED size — guarding on raw bytes is what let a 6.2 MB body
    /// sail past an 18 MB "limit" and die at the proxy.
    private func base64Size(_ rawBytes: Int) -> Int { (rawBytes + 2) / 3 * 4 }

    private func encodedSize(_ frames: [Data]) -> Int {
        frames.reduce(0) { $0 + base64Size($1.count) }
    }

    private struct FrameBudgetStep {
        let quality: Double
        let maxEdge: Int?
        let keep: Int?
    }

    /// Degradation ladder for oversized frame sets, cheapest-first.
    ///
    /// Quality steps come before downscaling on purpose: Gemini bills images by pixel
    /// dimensions, not bytes, so dropping JPEG quality shrinks the request for free while
    /// downscaling actually costs visual detail (and 1024px was already chosen as the
    /// readability floor for code/UI screenshots). Dropping frames comes last.
    private static let frameBudgetLadder: [FrameBudgetStep] = [
        FrameBudgetStep(quality: 0.60, maxEdge: nil, keep: nil),
        FrameBudgetStep(quality: 0.45, maxEdge: nil, keep: nil),
        FrameBudgetStep(quality: 0.60, maxEdge: 768, keep: nil),
        FrameBudgetStep(quality: 0.60, maxEdge: 768, keep: 6),
        FrameBudgetStep(quality: 0.60, maxEdge: 768, keep: 3),
        FrameBudgetStep(quality: 0.55, maxEdge: 640, keep: 1),
    ]

    /// Shrinks `frames` until their base64 total fits `budget`, returning [] if even one
    /// downscaled frame won't fit. Text-heavy screen content is the worst case for JPEG, and
    /// 10 such frames at 1024px/q0.85 can exceed the entire request budget on their own —
    /// so this runs on every path that sends frames, including the image-only fallback.
    func fitFramesToBudget(_ frames: [Data], budget: Int) -> [Data] {
        guard !frames.isEmpty, budget > 0 else { return [] }
        let original = encodedSize(frames)
        if original <= budget { return frames }

        for step in Self.frameBudgetLadder {
            var candidate = frames
            if let keep = step.keep, keep < candidate.count {
                candidate = evenlySampled(candidate, keep: keep)
            }
            candidate = candidate.map { reencodeJPEG($0, quality: step.quality, maxEdge: step.maxEdge) ?? $0 }
            let size = encodedSize(candidate)
            if size <= budget {
                LogManager.shared.log(
                    "🤖 Frames: fitted \(original / 1024)KB → \(size / 1024)KB b64 (q\(step.quality), edge=\(step.maxEdge.map(String.init) ?? "orig"), \(candidate.count)/\(frames.count) frames)"
                )
                return candidate
            }
        }

        LogManager.shared.log(
            "🤖 Frames: ⚠️ \(original / 1024)KB b64 won't fit \(budget / 1024)KB budget even at minimum quality — dropping frames",
            type: .error
        )
        return []
    }

    /// Picks `keep` frames spread evenly across the set so the sample still spans the whole
    /// recording rather than clustering at the start.
    private func evenlySampled(_ frames: [Data], keep: Int) -> [Data] {
        guard keep > 0, keep < frames.count else { return frames }
        if keep == 1 { return [frames[frames.count / 2]] }
        let step = Double(frames.count - 1) / Double(keep - 1)
        var picked: [Data] = []
        var seen = Set<Int>()
        for i in 0..<keep {
            let idx = min(frames.count - 1, Int((Double(i) * step).rounded()))
            if seen.insert(idx).inserted { picked.append(frames[idx]) }
        }
        return picked
    }

    /// Re-encodes a JPEG at `quality`, optionally downscaling the longest edge to `maxEdge`
    /// first. Returns nil when the image can't be decoded or re-encoded — callers keep the
    /// original frame in that case, so a failure here can only cost budget, never correctness.
    private func reencodeJPEG(_ data: Data, quality: Double, maxEdge: Int?) -> Data? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        var rep = source

        if let maxEdge, max(source.pixelsWide, source.pixelsHigh) > maxEdge {
            let scale = Double(maxEdge) / Double(max(source.pixelsWide, source.pixelsHigh))
            let width = max(1, Int((Double(source.pixelsWide) * scale).rounded()))
            let height = max(1, Int((Double(source.pixelsHigh) * scale).rounded()))
            guard let scaled = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 3,
                hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            scaled.size = NSSize(width: width, height: height)

            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            guard let context = NSGraphicsContext(bitmapImageRep: scaled) else { return nil }
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            context.flushGraphics()
            rep = scaled
        }

        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    // MARK: - Timestamp Selection

    private struct SrtSegment {
        let start: Double
        let end: Double
        let text: String
    }

    private func pickTimestamps(duration: Double) -> [Double] {
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

        return equispaced
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
