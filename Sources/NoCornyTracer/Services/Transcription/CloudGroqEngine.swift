import Foundation
import AVFoundation

/// Transcription by Whisper on Groq, through tracer.nocorny.com.
///
/// Cues and nothing else. Groq hears the recording but never sees it, so no title comes
/// back and the orchestrator asks NamingService separately, exactly as it does for the
/// on-device engine. That also means no frames, no visual glossary and no language-drift
/// wave: those exist on the Gemini path because a general-purpose model can be talked into
/// translating or summarizing, which an ASR decoder cannot.
///
/// What it does share with the Gemini path is the transport. Both go through the same
/// Vercel proxy with the same 4.5 MB request-body ceiling, so this engine reuses
/// ChunkPlanner's numbers unchanged rather than inventing its own: those numbers encode a
/// property of the transport, not of a provider.
final class CloudGroqEngine: TranscriptionEngine {

    let kind: TranscriptionEngineKind = .cloudGroq

    /// Reported to telemetry so a Groq transcript is distinguishable from a Gemini or an
    /// on-device one. The server picks the actual Groq model; this names the contract this
    /// engine was built against.
    static let modelName = "groq/whisper-large-v3-turbo"

    /// Attempts per chunk before the wave gives up on it. A fourth was never the thing that
    /// rescued a chunk on the Gemini path.
    private static let maxAttemptsPerChunk = 3

    private let proxyClient: TranscriptionProxyClient

    init(proxyClient: TranscriptionProxyClient) {
        self.proxyClient = proxyClient
    }

    /// Requires a signed-in Tracer account: the proxy holds the Groq key, not the app.
    /// Entitlement is deliberately NOT consulted here. The server decides that, and a
    /// cached "no" from a failed refresh would hide an engine the user is paying for.
    var isReady: Bool { proxyClient.isReady }

    /// An explicit language, or nil for "work it out". Same `transcriptionLanguage`
    /// preference the on-device engine honours, so switching engines does not silently
    /// change what a user pinned.
    private static var preferredLanguage: String? {
        let raw = UserDefaults.standard.string(forKey: "transcriptionLanguage") ?? "auto"
        return raw == "auto" ? nil : raw
    }

    // MARK: - Transcription

    func transcribe(videoURL: URL, multiSpeaker: Bool) async -> EngineResult {
        let t0 = Date()
        // multiSpeaker is accepted and ignored: Whisper transcribes, it does not tell
        // speakers apart. Honouring the flag needs a diarizer, not a different request.
        LogManager.shared.log("🎧 Groq: Starting for \(videoURL.lastPathComponent)")

        guard proxyClient.isReady else {
            LogManager.shared.log("🎧 Groq: ⏭️  Not signed in to Tracer, nothing to authenticate with")
            return Self.failure(code: ProxyTranscriptionError.notSignedIn.code, fatal: true, since: t0)
        }

        guard let audioURL = await AudioPreparation.extractCompressedAudio(from: videoURL) else {
            LogManager.shared.log("🎧 Groq: ❌ Failed to extract audio", type: .error)
            return Self.failure(code: "audio_extraction_failed", fatal: true, since: t0)
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let analysis = await AudioPreparation.analyzeSpeech(audioURL: audioURL)
        LogManager.shared.log("🎧 Groq: VAD - duration=\(String(format: "%.1f", analysis.totalDuration))s, speech=\(String(format: "%.1f", analysis.totalSpeechDuration))s, segments=\(analysis.segments.count), silenceCoverage=\(String(format: "%.2f", analysis.silenceCoverage))")

        if analysis.shouldSkipTranscription {
            // Nothing was said. That is an answer, not a failure: reporting it as one would
            // send the orchestrator into a retry over audio that will stay silent.
            LogManager.shared.log("🎧 Groq: 🤫 No clear speech detected, nothing to transcribe")
            return EngineResult(
                srt: nil, name: nil, usage: .zero, model: Self.modelName,
                latencyMs: Self.elapsedMs(since: t0), attempts: 1,
                success: true, errorCode: nil, fatal: false
            )
        }

        // Every run goes through the planner, including a 40-second one that plans a single
        // chunk. A separate short-recording path would be a second place for the timeline
        // projection to be written, and that projection is the one thing here whose bugs are
        // invisible: cues that are in range, well-formed and silently offset.
        let totalSamples = Int(analysis.totalDuration * 16000)
        let keptRanges = ChunkPlanner.chunkKeptRanges(analysis: analysis, totalSamples: totalSamples)
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
            LogManager.shared.log("🎧 Groq: ❌ No chunks planned", type: .error)
            return Self.failure(code: "chunk_plan_empty", fatal: true, since: t0)
        }

        let sourceAsset = AVAsset(url: audioURL)
        // Spelled out rather than chained, for the same reason as the Gemini path: writing
        // `try? await ….loadTracks(…).first` as one expression crashes the 6.3.3
        // type-checker while type-checking the enclosing function.
        let sourceTracks: [AVAssetTrack]? = try? await sourceAsset.loadTracks(withMediaType: .audio)
        guard let sourceTrack: AVAssetTrack = sourceTracks?.first else {
            LogManager.shared.log("🎧 Groq: ❌ Could not load the extracted audio track", type: .error)
            return Self.failure(code: "chunk_source_track_missing", fatal: true, since: t0)
        }

        LogManager.shared.log(
            "🎧 Groq: \(plans.count) chunk(s) (target \(tuning.targetSamples / 16000)s), concurrency \(tuning.maxConcurrent)"
        )

        let verdict = RunVerdict()
        var outcomes = await runChunkWave(
            plans: plans, sourceAsset: sourceAsset, sourceTrack: sourceTrack,
            originalDuration: analysis.totalDuration,
            concurrency: tuning.maxConcurrent, verdict: verdict
        )

        // Targeted retry of ONLY the chunks that failed recoverably, same shape as the
        // Gemini path: re-running everything would re-encode and re-upload all N chunks to
        // fix a few.
        let retryable = plans.filter { plan in
            guard let outcome = outcomes[plan.index] else { return true }
            return outcome.status == .failed && !outcome.fatal
        }
        if !retryable.isEmpty {
            LogManager.shared.log("🎧 Groq: retrying \(retryable.count)/\(plans.count) failed chunk(s)")
            let retried = await runChunkWave(
                plans: retryable, sourceAsset: sourceAsset, sourceTrack: sourceTrack,
                originalDuration: analysis.totalDuration,
                concurrency: tuning.maxConcurrent, verdict: verdict
            )
            for (index, result) in retried {
                guard let previous = outcomes[index] else {
                    outcomes[index] = result
                    continue
                }
                // Keep the retry only when it improved on the first attempt; either way the
                // first attempt's cost stays on the books.
                var merged = result.status == .failed ? previous : result
                merged.latencyMs = previous.latencyMs + result.latencyMs
                merged.attempts = previous.attempts + result.attempts
                outcomes[index] = merged
            }
        }

        let results = outcomes.values.sorted { $0.index < $1.index }
        let latencyMs = results.reduce(0) { $0 + $1.latencyMs }
        let attempts = max(1, results.reduce(0) { $0 + $1.attempts })
        let failedChunks = results.filter { $0.status == .failed }.count

        // Coverage counts NO_SPEECH as handled, not lost: a clip Groq reports as silent is a
        // legitimate outcome and must not drag `success` down.
        let handledSpeech = plans
            .filter { outcomes[$0.index].map { $0.status != .failed } ?? false }
            .reduce(0.0) { $0 + $1.speechSeconds }
        let totalSpeech = plans.reduce(0.0) { $0 + $1.speechSeconds }
        let speechCoverage = totalSpeech > 0 ? handledSpeech / totalSpeech : 0

        let merged = mergeChunkSegments(results)
        LogManager.shared.log(
            "🎧 Groq: \(plans.count - failedChunks)/\(plans.count) chunk(s) OK, speech coverage \(String(format: "%.0f%%", speechCoverage * 100)), \(merged.count) cues"
        )

        guard let srt = SrtCodec.serializeSrt(merged) else {
            if !results.isEmpty, results.allSatisfy({ $0.status == .noSpeech }) {
                LogManager.shared.log("🎧 Groq: 🤫 every chunk came back silent")
                return EngineResult(
                    srt: nil, name: nil, usage: .zero, model: Self.modelName,
                    latencyMs: latencyMs, attempts: attempts,
                    success: true, errorCode: nil, fatal: false,
                    totalChunks: plans.count, failedChunks: failedChunks
                )
            }
            let outcome = Self.aggregateFailure(results)
            LogManager.shared.log("🎧 Groq: ❌ No usable transcript from any chunk (\(outcome.code))", type: .error)
            return EngineResult(
                srt: nil, name: nil, usage: .zero, model: Self.modelName,
                latencyMs: latencyMs, attempts: attempts,
                success: false, errorCode: outcome.code, fatal: outcome.fatal,
                totalChunks: plans.count, failedChunks: failedChunks
            )
        }

        return EngineResult(
            srt: srt,
            // name stays nil: Groq only transcribes, so the orchestrator has to ask
            // NamingService for a title separately.
            name: nil,
            // Zero on purpose. The server prices this call by audio duration, not by
            // tokens, so a token count here would be a fabricated number in the cost report.
            usage: .zero,
            model: Self.modelName,
            latencyMs: latencyMs, attempts: attempts,
            success: speechCoverage >= 0.5,
            errorCode: failedChunks > 0 ? "partial_chunks_failed_\(failedChunks)_of_\(plans.count)" : nil,
            // The internal retry wave already did everything the caller's second pass would,
            // so never ask for a full re-run of an hour-long recording.
            fatal: true,
            totalChunks: plans.count, failedChunks: failedChunks
        )
    }

    // MARK: - Chunk fan-out

    /// Runs a set of chunk plans through build + upload with a sliding-window task group.
    ///
    /// Chunk audio is built lazily inside each task so at most `concurrency` AAC encodes run
    /// at once. Building all of them up front would spike CPU and disk for an hour-long file.
    private func runChunkWave(
        plans: [PlannedChunk],
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        concurrency: Int,
        verdict: RunVerdict
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
                    await runOneChunk(plan: plan, sourceAsset: sourceAsset, sourceTrack: sourceTrack,
                                      originalDuration: originalDuration, verdict: verdict)
                }
            }

            while let outcome = await group.next() {
                outcomes[outcome.index] = outcome
                if next < plans.count {
                    let plan = plans[next]
                    next += 1
                    group.addTask { [self] in
                        await runOneChunk(plan: plan, sourceAsset: sourceAsset, sourceTrack: sourceTrack,
                                          originalDuration: originalDuration, verdict: verdict)
                    }
                }
            }
        }
        return outcomes
    }

    private func runOneChunk(
        plan: PlannedChunk,
        sourceAsset: AVAsset,
        sourceTrack: AVAssetTrack,
        originalDuration: Double,
        verdict: RunVerdict
    ) async -> ChunkResult {
        // Checked before the encode, not just before the upload: once the server has given a
        // run-wide verdict there is no point spending CPU on audio nobody will accept.
        if let stop = await verdict.current() {
            var skipped = ChunkResult(index: plan.index, status: .failed)
            skipped.errorCode = stop
            skipped.fatal = true
            return skipped
        }

        guard let chunk = await AudioPreparation.buildChunkAudio(sourceAsset: sourceAsset, sourceTrack: sourceTrack, plan: plan) else {
            var failed = ChunkResult(index: plan.index, status: .failed)
            failed.errorCode = "chunk_build_failed"
            failed.fatal = true
            return failed
        }
        defer { try? FileManager.default.removeItem(at: chunk.url) }

        // Below a second of speech there is nothing to transcribe, so skip the network.
        if chunk.speechSeconds < 1.0 {
            return ChunkResult(index: plan.index, status: .noSpeech)
        }

        return await transcribeChunk(chunk, originalDuration: originalDuration, verdict: verdict)
    }

    /// Uploads one chunk and lands its cues on the ORIGINAL recording's timeline.
    func transcribeChunk(_ chunk: AudioChunk, originalDuration: Double, verdict: RunVerdict) async -> ChunkResult {
        var result = ChunkResult(index: chunk.index, status: .failed)
        result.model = Self.modelName

        guard let audioData = try? Data(contentsOf: chunk.url) else {
            result.errorCode = "chunk_audio_read_failed"
            result.fatal = true
            return result
        }

        var delay: Double = 4.0

        for attempt in 1...Self.maxAttemptsPerChunk {
            if let stop = await verdict.current() {
                result.errorCode = stop
                result.fatal = true
                return result
            }

            do {
                let response = try await proxyClient.transcribe(
                    audio: audioData,
                    filename: String(format: "chunk-%03d.m4a", chunk.index),
                    language: Self.preferredLanguage,
                    // No prompt. The Gemini path derives its spelling reference from
                    // SCREENSHOTS, which Groq never receives; the other way to fill this
                    // field is the previous chunk's tail, and chunks run concurrently, so
                    // there is no previous chunk to quote.
                    prompt: nil
                )
                result.attempts += 1
                result.latencyMs += response.latencyMs

                let local = Self.clipLocalSegments(response, clipDuration: chunk.localDuration)
                guard !local.isEmpty else {
                    // Groq answers a clip with no speech with an empty segment list. VAD
                    // already thought there was speech here, but a hallucination filter that
                    // ate every cue lands here too, and both mean the same thing downstream.
                    result.status = .noSpeech
                    result.errorCode = nil
                    return result
                }

                // Chunk timestamps are clip-local; `chunk.mapping` is clip-local on the
                // stitched side and carries the original sample offset on the other, so this
                // one call is the whole projection back onto the recording's timeline. Same
                // call, same arguments as the Gemini path, deliberately: this is the piece
                // whose bugs produce cues that look perfectly valid and drift.
                let (mapped, outOfBounds) = SrtCodec.mapSegments(
                    local, mapping: chunk.mapping,
                    speedupFactor: chunk.speedupFactor, originalDuration: originalDuration
                )

                // Judge each chunk on its own rather than against a global ratio, so one
                // corrupted chunk cannot discard every other chunk's work.
                if outOfBounds > local.count / 2 {
                    result.errorCode = "chunk_timestamps_out_of_bounds"
                    LogManager.shared.log(
                        "🎧 Groq: chunk \(chunk.index) ⚠️ \(outOfBounds)/\(local.count) cues out of bounds",
                        type: .error
                    )
                    // No inline retry: unlike a prompted model, the decoder has no hint to
                    // give it, so an identical request would land in the same place. The
                    // targeted wave gets one more go at it.
                    return result
                }

                result.status = .transcribed
                result.segments = mapped
                result.text = local.map(\.text).joined(separator: " ")
                result.errorCode = nil
                return result

            } catch {
                result.attempts += 1
                if let proxyError = error as? ProxyTranscriptionError {
                    result.errorCode = proxyError.code
                    await verdict.record(proxyError)
                } else {
                    result.errorCode = String("\(error)".prefix(200))
                }

                if !isRetryableTranscriptionError(error) {
                    result.fatal = true
                    LogManager.shared.log("🎧 Groq: chunk \(chunk.index) ❌ non-retryable (\(error))", type: .error)
                    return result
                }
                if attempt < Self.maxAttemptsPerChunk {
                    LogManager.shared.log("🎧 Groq: chunk \(chunk.index) ⏳ attempt \(attempt) failed (\(error)), retrying...", type: .error)
                    try? await Task.sleep(nanoseconds: TranscriptionSupport.jitteredDelayNanos(delay))
                    delay *= 2
                }
            }
        }
        return result
    }

    // MARK: - Response to cues

    /// Turns one Groq response into clip-local cues.
    ///
    /// No "did this chunk answer in whole-recording time?" detector, which the Gemini path
    /// needs: Whisper timestamps are decoder output rather than an instruction a model may
    /// misread, so a cue reaching past the clip's end is rounding, not a lost plot. Clamp it
    /// and move on.
    static func clipLocalSegments(_ response: ProxyTranscription, clipDuration: Double) -> [SrtSegment] {
        var out: [SrtSegment] = []
        for segment in response.segments {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // Same Whisper model family as the on-device engine, so the same subtitle
            // boilerplate turns up over silence and the same filter applies.
            guard !Hallucinations.isHallucination(text) else { continue }
            let start = max(0, segment.start)
            let end = min(segment.end, clipDuration)
            guard end > start else { continue }
            out.append(SrtSegment(start: start, end: end, text: text))
        }
        out.sort { $0.start < $1.start }

        // Decoding straight through yields long cues, eight seconds and more of speech in
        // one block, which is unreadable as a subtitle. Both other engines split those on
        // sentence boundaries; reuse the same splitter so all three produce transcripts of
        // the same shape rather than ones that merely contain the same words.
        return out.flatMap { SrtCodec.splitLongSegmentBySentences($0) }
    }

    // MARK: - Merge

    /// Merges per-chunk segments (already on the original timeline) into one ordered list.
    ///
    /// The seam rule is where this differs from `CloudGeminiEngine.mergeChunkSegments`. That
    /// one drops an overlapping cue only when its normalized text is EXACTLY equal to its
    /// predecessor's, which works there because temperature 0 makes two readings of the same
    /// 1.5s of overlap come back byte-identical. Groq re-decodes that overlap acoustically
    /// from a different starting context each time, so the two readings differ in
    /// punctuation, casing and often a word: exact equality would never fire and every
    /// forced mid-speech cut would ship the same phrase twice.
    ///
    /// So the test below is tolerant, and kept narrow to pay for that tolerance. It only
    /// ever compares cues that actually overlap in TIME, so a phrase genuinely repeated
    /// later in the recording is untouched.
    func mergeChunkSegments(_ results: [ChunkResult]) -> [SrtSegment] {
        var all = results.filter { $0.status == .transcribed }.flatMap(\.segments)
        guard !all.isEmpty else { return [] }
        all.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        var kept: [SrtSegment] = []
        for seg in all {
            // Two or three candidates is the realistic maximum: the planner's overlap window
            // is 1.5s and only a forced mid-speech cut opens one at all.
            let overlapping = kept.suffix(3).filter { $0.end > seg.start + 0.2 }
            if overlapping.contains(where: { Self.isSeamDuplicate(seg.text, of: $0.text) }) { continue }

            guard let prev = kept.last else { kept.append(seg); continue }
            // Enforce monotonicity so the merged file never has overlapping cues.
            let start = max(seg.start, prev.end)
            if seg.end > start {
                kept.append(SrtSegment(start: start, end: seg.end, text: seg.text))
            }
        }
        return kept
    }

    /// Whether `text` is a re-reading of `previous` rather than new speech.
    ///
    /// Three tests, loosest last: identical once normalized, one a word-for-word prefix of
    /// the other (the overlap was cut short on one side), or most of the shorter cue's words
    /// also appear in the longer one. The token counts are the guardrail: "yeah" and "okay"
    /// get repeated for real, so a cue that short is never merged away on similarity alone.
    static func isSeamDuplicate(_ text: String, of previous: String) -> Bool {
        let a = SrtCodec.normalizedForDedupe(previous)
        let b = SrtCodec.normalizedForDedupe(text)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }

        let aTokens = a.split(separator: " ").map(String.init)
        let bTokens = b.split(separator: " ").map(String.init)
        let shorter = aTokens.count <= bTokens.count ? aTokens : bTokens
        let longer = aTokens.count <= bTokens.count ? bTokens : aTokens

        guard shorter.count >= 2 else { return false }
        if longer.starts(with: shorter) { return true }

        guard shorter.count >= 4 else { return false }
        let longerSet = Set(longer)
        let shared = shorter.filter { longerSet.contains($0) }.count
        return Double(shared) / Double(shorter.count) >= 0.7
    }

    // MARK: - Failure mapping

    /// The one verdict that explains a run where nothing came back.
    ///
    /// Account- and switch-level answers win over whatever an individual chunk reported,
    /// because they explain every chunk at once.
    static func aggregateFailure(_ results: [ChunkResult]) -> (code: String, fatal: Bool) {
        let codes = results.compactMap(\.errorCode)

        if codes.contains(ProxyTranscriptionError.premiumRequired.code) {
            // Deterministic: this account will be refused again in a second and in an hour.
            return (ProxyTranscriptionError.premiumRequired.code, true)
        }
        if codes.contains(ProxyTranscriptionError.engineNotConfigured.code) {
            // Same shape as the switch: nothing about this recording, and another engine can
            // answer it right now.
            return (ProxyTranscriptionError.engineNotConfigured.code, false)
        }
        if codes.contains(ProxyTranscriptionError.engineDisabled.code) {
            // NOT fatal, on purpose. An admin switched this engine off server-side, which
            // says nothing about the recording, so the orchestrator is meant to fall back to
            // another engine rather than write the run off.
            return (ProxyTranscriptionError.engineDisabled.code, false)
        }
        // Everything else already survived three attempts and a targeted retry wave. Fatal
        // only when every chunk failed for a reason retrying cannot touch.
        let allFatal = !results.isEmpty && results.allSatisfy(\.fatal)
        return (codes.first ?? "groq_no_transcript", allFatal)
    }

    private static func failure(code: String, fatal: Bool, since t0: Date, attempts: Int = 1) -> EngineResult {
        EngineResult(
            srt: nil, name: nil, usage: .zero, model: modelName,
            latencyMs: elapsedMs(since: t0), attempts: attempts,
            success: false, errorCode: code, fatal: fatal
        )
    }

    private static func elapsedMs(since t0: Date) -> Int {
        Int(Date().timeIntervalSince(t0) * 1000)
    }
}

/// Stops a fan-out the moment the server gives an answer that applies to every chunk.
///
/// `premium_required` and `engine_disabled` are properties of the account or of an admin
/// switch, not of the audio. Without this, hearing one of them on chunk 1 of 12 still costs
/// eleven more encodes and eleven more uploads, each to be told exactly the same thing.
actor RunVerdict {
    private var stopCode: String?

    func record(_ error: ProxyTranscriptionError) {
        switch error {
        case .premiumRequired, .engineDisabled, .engineNotConfigured, .notSignedIn:
            if stopCode == nil { stopCode = error.code }
        case .transient, .fatal:
            // A 4xx on one chunk can genuinely be about that chunk (an oversized body from
            // an unusually dense encode), so it never stops the others.
            break
        }
    }

    /// Same decision from a code rather than a typed error, for the engine whose proxy
    /// client throws `ProxyError`. Kept on this actor so there is ONE definition of "this
    /// answer applies to every chunk" rather than two that can drift.
    func record(code: String?) {
        guard let code, stopCode == nil else { return }
        if AINamingService.refusalCodes.contains(code) {
            stopCode = code
        }
    }

    func current() -> String? { stopCode }
}
