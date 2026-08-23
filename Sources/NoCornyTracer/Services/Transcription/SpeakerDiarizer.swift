import Foundation
import FluidAudio

/// On-device speaker diarization: pyannote community-1 segmentation, WeSpeaker embeddings
/// and VBx clustering, all Core ML, all local.
///
/// `OfflineDiarizerManager` is a non-Sendable class holding compiled Core ML state, and two
/// recordings finishing at once must not race its models. Actor isolation alone does not buy
/// that: actors are reentrant, so the `await manager.process(...)` below suspends and lets
/// the next call straight in - which is precisely the window the confinement was meant to
/// close. The queue is what closes it.
///
/// One prepared manager is kept per speaker-count constraint, because the constraint is baked
/// in at init and preparing a fresh one costs a Core ML compile plus prewarm.
actor SpeakerDiarizer {
    static let shared = SpeakerDiarizer()
    private init() {}

    /// Internal for the same reason as the engine's: a test occupies it to prove `diarize`
    /// is wired to it, not merely that the gate works.
    let runs = SerialGate()

    /// Keyed by the constraint, not by recording: the same "1 to 3 speakers" manager serves
    /// every recording in a session, which is the whole point of caching it.
    private var managers: [String: OfflineDiarizerManager] = [:]

    /// Diarize one audio file. Format conversion is FluidAudio's job (it resamples whatever
    /// AVAudioFile can read down to the segmentation model's rate), so an m4a sidecar or an
    /// extracted 16 kHz mono track both work as-is.
    ///
    /// Throws on a first run with no network, a corrupt model cache, or unreadable audio.
    /// Callers ship the transcript unlabelled: labels are a bonus on top of a transcript that
    /// already exists, never a reason to lose one.
    func diarize(audioURL: URL, minSpeakers: Int, maxSpeakers: Int) async throws -> [DiarizedSpan] {
        try await runs.enqueueThrowing {
            try await self.runDiarization(audioURL: audioURL, minSpeakers: minSpeakers, maxSpeakers: maxSpeakers)
        }
    }

    private func runDiarization(audioURL: URL, minSpeakers: Int, maxSpeakers: Int) async throws -> [DiarizedSpan] {
        // Checked here, at the front of the queued work, because whoever asked may have given
        // up while waiting for their turn. Core ML cannot be interrupted once it starts, so
        // the only cheap moment to notice is before starting: a diarization nobody is waiting
        // for otherwise runs to the end holding the queue against the next recording.
        try Task.checkCancellation()
        let key = "\(minSpeakers)-\(maxSpeakers)"
        let manager: OfflineDiarizerManager
        if let warm = managers[key] {
            manager = warm
        } else {
            let config = OfflineDiarizerConfig().withSpeakers(min: minSpeakers, max: maxSpeakers)
            let fresh = OfflineDiarizerManager(config: config)
            // ~130 MB, downloaded once ever and then read from the Application Support cache.
            // The first diarization on a Mac therefore takes minutes; every one after it takes
            // the Core ML compile and prewarm, which is seconds.
            try await fresh.prepareModels()
            managers[key] = fresh
            manager = fresh
        }

        let result = try await manager.process(audioURL)
        let spans = result.segments
            .map {
                DiarizedSpan(
                    speakerId: $0.speakerId,
                    startMs: Int64($0.startTimeSeconds * 1000),
                    endMs: Int64($0.endTimeSeconds * 1000)
                )
            }
            .sorted { $0.startMs < $1.startMs }

        let voices = Set(spans.map(\.speakerId)).count
        LogManager.shared.log("🎛️ Diarization: \(audioURL.lastPathComponent) -> \(spans.count) spans, \(voices) voices (\(minSpeakers)-\(maxSpeakers) allowed)")
        return spans
    }
}
