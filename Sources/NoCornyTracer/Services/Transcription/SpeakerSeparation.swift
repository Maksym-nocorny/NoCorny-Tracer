import Foundation

/// Puts a name on every cue of a finished transcript.
///
/// This runs AFTER transcription, never instead of it, and it is allowed to give up. The
/// transcript is the product; speaker labels are decoration on top of it. Every path out of
/// here that is not a clean success returns the cues exactly as they arrived.
enum SpeakerSeparation {

    /// Nothing in the app knows how many people are in a recording, and there is no honest
    /// way to ask: the setting is flipped once and then every recording goes through it. So
    /// the clustering gets a range instead of a count. Three is where a screen recording
    /// stops being a call and starts being a meeting, and an over-wide range is the failure
    /// mode that matters here - VBx splits one person into two on a bad mic long before it
    /// merges two people into one.
    private static let minSpeakers = 1
    private static let maxSpeakers = 3

    /// Share of the recording's own length we are willing to spend on labelling it.
    private static let deadlineFraction = 0.15
    private static let deadlineFloorSeconds = 30.0
    private static let deadlineCapSeconds = 300.0

    fileprivate enum Outcome: Sendable {
        case labelled([SrtSegment])
        /// Diarization ran and produced nothing worth showing (one voice, or no spans).
        case unlabelled
        case failed(String)
        case deadline
    }

    /// - Parameters:
    ///   - systemAudioURL: the `-system.m4a` sidecar when the recording has one. Its presence
    ///     is what decides which of the two sources below we work from.
    ///   - recordingDuration: used only to size the deadline.
    /// - Returns: the cues, labelled when that succeeded and untouched otherwise.
    static func label(
        cues: [SrtSegment],
        videoURL: URL,
        systemAudioURL: URL?,
        recordingDuration: Double
    ) async -> [SrtSegment] {
        guard !cues.isEmpty else { return cues }

        let budget = min(deadlineCapSeconds, max(deadlineFloorSeconds, recordingDuration * deadlineFraction))
        let startedAt = Date()

        // Deliberately not a task group: a group waits for its children when the body
        // returns, and the Core ML loop inside FluidAudio does not poll for cancellation.
        // The "give up" branch would therefore sit and wait for exactly the work it just
        // gave up on. An abandoned Task finishes into a result nobody reads instead.
        let box = FirstOutcome()
        let work = Task.detached(priority: .utility) {
            let outcome = await run(cues: cues, videoURL: videoURL, systemAudioURL: systemAudioURL)
            box.settle(outcome)
        }
        let timer = Task {
            try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
            box.settle(.deadline)
        }

        let outcome = await box.wait()
        timer.cancel()

        switch outcome {
        case .labelled(let labelled):
            let voices = Set(labelled.compactMap(\.speaker)).count
            LogManager.shared.log("🎛️ Diarization: labelled \(labelled.count) cues across \(voices) speakers in \(Int(Date().timeIntervalSince(startedAt)))s")
            return labelled
        case .unlabelled:
            LogManager.shared.log("🎛️ Diarization: only one voice found - shipping the transcript unlabelled")
            return cues
        case .failed(let reason):
            LogManager.shared.log("🎛️ Diarization: skipped (\(reason))", type: .error)
            return cues
        case .deadline:
            work.cancel()
            LogManager.shared.log("🎛️ Diarization: skipped (deadline)", type: .error)
            return cues
        }
    }

    // MARK: - Choosing a source

    private static func run(cues: [SrtSegment], videoURL: URL, systemAudioURL: URL?) async -> Outcome {
        if let systemAudioURL, FileManager.default.fileExists(atPath: systemAudioURL.path) {
            return await labelFromSystemTrack(cues: cues, systemAudioURL: systemAudioURL)
        }
        return await labelFromMicOnly(cues: cues, videoURL: videoURL)
    }

    /// The good case. The sidecar holds only what the Mac was playing, so "who is this?" stops
    /// being an acoustic guess and becomes a question about which track the words came off:
    /// the far end is on the system track by construction, and the user is everything else.
    /// Diarizing that track is then only about telling several far-end voices apart, which is
    /// the job clustering is actually good at.
    private static func labelFromSystemTrack(cues: [SrtSegment], systemAudioURL: URL) async -> Outcome {
        let spans: [DiarizedSpan]
        do {
            spans = try await SpeakerDiarizer.shared.diarize(
                audioURL: systemAudioURL, minSpeakers: minSpeakers, maxSpeakers: maxSpeakers
            )
        } catch {
            return .failed("system track: \(error.localizedDescription)")
        }
        return apply(cues: cues, spans: spans, userOwnsUnmatched: true)
    }

    /// The weak case, and it is worth being honest about why. There is one microphone, so the
    /// far end reaches it only as whatever leaked out of the speakers - quieter, room-coloured
    /// and often clipped short. Worse, "Reduce background noise" is a setting people leave on,
    /// and its whole job is to remove exactly that leakage. So this path can be asked to
    /// separate speakers from audio the recorder has already done its best to reduce to one.
    /// It stays because a labelled guess beats no labels at all on a recording made before
    /// system audio was ever switched on.
    private static func labelFromMicOnly(cues: [SrtSegment], videoURL: URL) async -> Outcome {
        guard let audioURL = await AudioPreparation.extractCompressedAudio(from: videoURL) else {
            return .failed("could not extract audio")
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let spans: [DiarizedSpan]
        do {
            spans = try await SpeakerDiarizer.shared.diarize(
                audioURL: audioURL, minSpeakers: minSpeakers, maxSpeakers: maxSpeakers
            )
        } catch {
            return .failed("mic track: \(error.localizedDescription)")
        }
        return apply(cues: cues, spans: spans, userOwnsUnmatched: false)
    }

    // MARK: - Cues to speakers

    /// Cue index to diarized speaker id, by how much time they share.
    ///
    /// Not Corder's anchor-word alignment ladder, on purpose. That exists to repair timestamps
    /// a model invented; ours are measured - Whisper emits them from the audio, and the cloud
    /// path maps each chunk back onto the original timeline before anything else sees it. The
    /// ladder would also drag in a second ~600 MB model to solve a problem we do not have.
    ///
    /// - Parameter fallbackToNearest: what "overlaps nothing" means. On one track it means the
    ///   span boundaries landed a little off the cue, so the nearest span is the answer. Across
    ///   two tracks it is the answer in itself - the words are not on the track we diarized,
    ///   so they belong to whoever holds the other one.
    static func assign(
        cues: [SrtSegment], spans: [DiarizedSpan], fallbackToNearest: Bool
    ) -> [Int: String] {
        guard !spans.isEmpty else { return [:] }

        var assignment: [Int: String] = [:]
        for (index, cue) in cues.enumerated() {
            let cueStart = Int64(cue.start * 1000)
            let cueEnd = Int64(cue.end * 1000)

            var bestId: String? = nil
            var bestOverlap: Int64 = 0
            var nearestId: String? = nil
            var nearestDistance = Int64.max

            for span in spans {
                let overlap = min(cueEnd, span.endMs) - max(cueStart, span.startMs)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestId = span.speakerId
                }
                let distance = overlap >= 0 ? 0 : -overlap
                if distance < nearestDistance {
                    nearestDistance = distance
                    nearestId = span.speakerId
                }
            }

            if let bestId {
                assignment[index] = bestId
            } else if fallbackToNearest, let nearestId {
                assignment[index] = nearestId
            }
        }
        return assignment
    }

    /// Turns diarizer ids into the numbers a reader sees.
    ///
    /// Numbering follows first appearance rather than the diarizer's internal order, so a
    /// transcript opens on Speaker 1 instead of Speaker 3. When there is a user track, they
    /// hold Speaker 1 outright - being "the person whose Mac this is" outranks who spoke first.
    private static func apply(
        cues: [SrtSegment], spans: [DiarizedSpan], userOwnsUnmatched: Bool
    ) -> Outcome {
        guard !spans.isEmpty else { return .unlabelled }

        // A NUL byte is not something a diarizer id can contain, which is the whole
        // requirement: the user is one more entry in the same id-to-number map.
        let userId = "\u{0}user"
        let assignment = assign(cues: cues, spans: spans, fallbackToNearest: !userOwnsUnmatched)
        let ids: [String?] = cues.indices.map { index in
            assignment[index] ?? (userOwnsUnmatched ? userId : nil)
        }

        var names: [String: String] = [:]
        var next = 1
        if userOwnsUnmatched, ids.contains(where: { $0 == userId }) {
            names[userId] = "Speaker 1"
            next = 2
        }
        for id in ids.compactMap({ $0 }) where names[id] == nil {
            names[id] = "Speaker \(next)"
            next += 1
        }

        // One name across the whole transcript is a solo screen recording that happens to have
        // been diarized. Prefixing every line with "[Speaker 1] " there costs the reader
        // something and tells them nothing.
        guard names.count > 1 else { return .unlabelled }

        let labelled = zip(cues, ids).map { cue, id -> SrtSegment in
            SrtSegment(start: cue.start, end: cue.end, text: cue.text, speaker: id.flatMap { names[$0] })
        }
        return .labelled(labelled)
    }
}

/// Whichever of two racing tasks settles first wins; the loser is ignored rather than waited on.
private final class FirstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var settled: SpeakerSeparation.Outcome?
    private var waiter: CheckedContinuation<SpeakerSeparation.Outcome, Never>?

    func settle(_ outcome: SpeakerSeparation.Outcome) {
        lock.lock()
        guard settled == nil else { lock.unlock(); return }
        settled = outcome
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: outcome)
    }

    func wait() async -> SpeakerSeparation.Outcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let settled {
                lock.unlock()
                continuation.resume(returning: settled)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}
