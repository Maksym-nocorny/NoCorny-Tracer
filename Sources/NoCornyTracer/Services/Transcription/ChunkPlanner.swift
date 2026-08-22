import Foundation

/// Deciding where a long recording gets cut, and whether it needs cutting at all.
///
/// Pure arithmetic over speech ranges -- no audio is touched here (that is
/// AudioPreparation) and nothing reaches the network. The thresholds are shared by
/// every cloud engine, so a change here moves all of them at once; that is deliberate,
/// because the ceilings they encode are properties of the transport (a 4.5 MB request
/// body) rather than of any one provider.
enum ChunkPlanner {

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

    struct ChunkTuning {
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
    /// Cutting at a range boundary is always safe: `AudioPreparation.analyzeSpeech` pads every segment with
    /// 200ms of silence on both sides and merges gaps under 800ms, so at least 400ms of real
    /// silence separates adjacent ranges. A chunk therefore ends in silence and the next
    /// begins in silence — no overlap needed. Overlap is introduced ONLY when a single range
    /// is longer than one chunk and must be cut mid-speech.
    ///
    /// Pure and deterministic so it can be unit-tested without any AV or network work.
    static func planChunks(
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
    static func chunkKeptRanges(analysis: SpeechAnalysis, totalSamples: Int) -> [SampleRange] {
        let speechSeconds = analysis.totalSpeechDuration
        let fraction = analysis.totalDuration > 0 ? speechSeconds / analysis.totalDuration : 1.0

        if TranscriptionTuning.enableTrimSilence, !analysis.segments.isEmpty,
           fraction <= 0.95, fraction >= 0.05, speechSeconds >= 5.0 {
            return analysis.segments.map { SampleRange(start: $0.startSamples, end: $0.endSamples) }
        }
        return wholeTimelineRanges(segments: analysis.segments, totalSamples: totalSamples)
    }

    /// Covers the whole timeline with contiguous ranges whose boundaries sit in the middle of
    /// each silence gap. `planChunks` only cuts at range boundaries, so this hands it natural
    /// pause positions to prefer WITHOUT dropping any audio — the union is still [0, total].
    static func wholeTimelineRanges(segments: [SpeechSegment], totalSamples: Int) -> [SampleRange] {
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
}
