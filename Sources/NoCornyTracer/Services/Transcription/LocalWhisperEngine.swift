import Foundation
import CoreML
@preconcurrency import WhisperKit

// Portions of this file derive from Corder (`Sources/Corder/Transcription/
// LocalWhisperTranscriber.swift`), reused with the author's explicit permission. Corder's
// HTTP routes, settings layer, path helpers, dual-track logic, its own VAD pre-pass and its
// account/tier handling are not carried over; what is carried over is the model lifecycle,
// because every guard in it exists because something failed in production.

/// Transcription by Whisper on this Mac, through WhisperKit (Core ML).
///
/// Free and offline once the model is downloaded, and it produces cues only: no title comes
/// back, so the orchestrator has to ask NamingService separately. That is the whole reason
/// this engine is smaller than the Gemini one. There is no request-size ceiling, so no
/// chunking; no per-second cost, so no reason to trim silence; no multimodal call, so no
/// frames and no glossary.
///
/// What it does carry is a model lifecycle with sharp edges: a 1.5 GB download that can
/// half-land, a Core ML compile that on a cold machine takes minutes and cannot be
/// cancelled, and two concurrent loads that corrupt each other. The guards below are the
/// scar tissue from that.
final class LocalWhisperEngine: TranscriptionEngine {

    let kind: TranscriptionEngineKind = .localWhisper

    /// Reported to telemetry so a local transcript is distinguishable from a Gemini one.
    static let modelName = "whisperkit-large-v3-turbo"

    /// The single on-device model. Multilingual large-v3 turbo, roughly 1.5 GB on disk and
    /// comfortably faster than real time on any M-series chip. The string has to match the
    /// folder WhisperKit creates under `argmaxinc/whisperkit-coreml/`.
    static let variant = "openai_whisper-large-v3_turbo"

    /// Refuse to start a 1.5 GB download onto a nearly-full disk. A download that dies at
    /// 90% for lack of space leaves a bundle that looks plausible and fails at load time,
    /// which is a much more confusing failure than being told there is no room.
    static let requiredFreeBytes: Int64 = 4_000_000_000

    /// Neural Engine budget on the transcribe path. A warm Core ML cache loads in a couple
    /// of seconds, so this catches it with room to spare; a cold machine busts it and drops
    /// to the GPU encoder rather than making the user wait out the first compile. That
    /// compile is paid once, up front, by `downloadModel`.
    private static let transcribeANEBudget: Double = 30
    /// Download-time prewarm budget. The first ANE compile has been measured at roughly 12
    /// minutes on an M1 and longer on weaker Macs, and it cannot be cancelled. It is worth
    /// waiting out here, once, so that every later transcribe loads warm.
    private static let prewarmANEBudget: Double = 2400

    // MARK: - Availability

    /// Apple Silicon only: the Core ML packages have no Intel artefacts, and Core ML on
    /// Intel lacks the kernels these models need.
    ///
    /// Compile-time, not a runtime `hw.optional.arm64` probe. The release build is
    /// universal, so a runtime check answers "what am I running on", which under Rosetta or
    /// in a universal slice is not the same question as "can this build load the model".
    /// `NCTForceIntelBehavior` exists so the Intel path can actually be exercised on the
    /// machines we develop on, which are all arm64.
    static var isAvailable: Bool {
        if DebugOverrides.bool(forKey: "NCTForceIntelBehavior") { return false }
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// No windowing by default. WhisperKit's `.vad` strategy skips stretches it judges
    /// quiet, and on a real 148-second recording it dropped 30 seconds of actual speech --
    /// the opening and the closing, both of which the cloud path transcribed fine. Decoding
    /// straight through took the same time and covered 142 seconds instead of 88.
    /// Overridable to "vad" so the comparison can be repeated.
    static var chunkingStrategy: ChunkingStrategy? {
        DebugOverrides.string(forKey: "whisperChunking") == "vad" ? .vad : nil
    }

    /// An explicit language, or nil for "work it out".
    ///
    /// Working it out has to happen ONCE, up front -- see `resolveLanguage`. Left to
    /// decide per window, Whisper guesses wrong on short or noisy ones and then
    /// "transcribe" quietly becomes "translate": a Russian recording came back in English,
    /// drifting into Spanish halfway through.
    static var preferredLanguage: String? {
        // Through DebugOverrides like every other knob: a live-test session once left this
        // forced to "ru" in the real preferences, and a release build honoured it - every
        // English recording on that Mac would have been transcribed as Russian, with no UI
        // anywhere admitting why.
        let raw = DebugOverrides.string(forKey: "transcriptionLanguage") ?? "auto"
        return raw == "auto" ? nil : raw
    }

    /// Decide the language once over the first 30 seconds and then hold it for the whole
    /// recording. One decision on 30 seconds of speech beats a fresh guess on every window.
    private static func resolveLanguage(_ pipe: WhisperKit, audioPath: String) async -> String? {
        if let explicit = preferredLanguage { return explicit }
        do {
            let detected = try await pipe.detectLanguage(audioPath: audioPath)
            LogManager.shared.log("🎙️ Local: detected language \(detected.language)")
            return detected.language
        } catch {
            LogManager.shared.log("🎙️ Local: language detection failed (\(error)) - letting the model decide per window", type: .error)
            return nil
        }
    }

    /// Ready means the model is already on disk. Never "ready, will fetch 1.5 GB first":
    /// the orchestrator uses this to choose an engine, and a choice that silently turns
    /// into a long download is not a choice.
    var isReady: Bool { Self.isAvailable && Self.isModelDownloaded() }

    // MARK: - Model location

    /// `~/Library/Application Support/NoCornyTracer/Models/`. Machine-wide on purpose: the
    /// model is a public artefact, not user data, and nothing about it is per-recording.
    static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("NoCornyTracer", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Where the bytes actually land.
    ///
    /// `WhisperKit.download` preserves the HuggingFace repo path AND inserts its own
    /// `models/` segment under whatever you hand it as `downloadBase`, so the model folder
    /// sits TWO levels deeper than the base, not one. Getting this wrong does not fail
    /// loudly: `isModelDownloaded` looks in an empty directory, reports every finished
    /// download as incomplete, and the UI snaps back to "Download model" the instant the
    /// no-op re-download returns.
    static var modelFolderURL: URL {
        modelsDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// HuggingFace's download-staging cache, a SIBLING of the model folder. Hub decides
    /// what is "already fetched" from what is in here, so deleting a corrupt model without
    /// also clearing this makes the next download resume from the same bad bytes forever.
    static var huggingFaceDownloadCacheURL: URL {
        modelFolderURL
            .deletingLastPathComponent()
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// The tokenizer ships in a separate `openai/whisper-large-v3` repo, not with the Core
    /// ML packages. Turbo shares large-v3's tokenizer.
    static var tokenizerRepoFolderURL: URL {
        modelsDir
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("openai/whisper-large-v3", isDirectory: true)
    }

    // MARK: - Model presence

    /// True only when a COMPLETE, loadable model is on disk.
    ///
    /// Every clause here is a way a half-download has passed a laxer check:
    /// an in-flight download materialises the package folders long before the bytes are in;
    /// Hub leaves `*.incomplete` markers while it works; and WhisperKit writes each
    /// `.mlmodelc` shell plus its `model.mil` FIRST and streams the large weight blob in
    /// last, so a fetch interrupted near the end leaves packages that look finished and
    /// fail the Core ML load on both encoders.
    static func isModelDownloaded() -> Bool {
        if DownloadProgressRegistry.shared.current != nil { return false }

        let dir = modelFolderURL
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        if let walker = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent.hasSuffix(".incomplete") {
                return false
            }
        }

        let packages = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        for name in packages + ["config.json"] {
            if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) { return false }
        }
        for name in packages {
            let pkg = dir.appendingPathComponent(name, isDirectory: true)
            let contents = (try? fm.contentsOfDirectory(atPath: pkg.path)) ?? []
            if contents.isEmpty { return false }
            let weight = pkg.appendingPathComponent("weights/weight.bin")
            let size = ((try? fm.attributesOfItem(atPath: weight.path))?[.size] as? Int) ?? 0
            if size <= 0 { return false }
        }
        return true
    }

    /// The tokenizer lives in its own repo, so a model can pass `isModelDownloaded` and
    /// still need the network at load time.
    static func isTokenizerDownloaded() -> Bool {
        let candidates = [
            tokenizerRepoFolderURL.appendingPathComponent("tokenizer.json"),
            modelFolderURL.appendingPathComponent("tokenizer.json"),
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Download

    /// Fetch the model, then pay the first Core ML compile.
    ///
    /// Explicit by design: nothing else in this file downloads on its own (the one
    /// exception is the corrupt-bundle repair in `transcribe`, which re-fetches a model the
    /// user already asked for). 1.5 GB over someone's connection is a decision, not a side
    /// effect of hitting Stop on a recording.
    ///
    /// The compile runs here, with a generous budget and no GPU fallback, precisely so it
    /// does NOT run during the user's first transcribe. It caches to disk, so from then on
    /// loads take seconds.
    func downloadModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await Self.downloadModel(progress: progress)
    }

    static func downloadModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard isAvailable else { throw LocalWhisperError.notAvailableOnAppleSilicon }
        guard DownloadProgressRegistry.shared.current == nil else {
            throw LocalWhisperError.downloadAlreadyRunning
        }

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try checkFreeSpace()

        if !isModelDownloaded() {
            LogManager.shared.log("🎙️ Local: downloading \(variant) into \(modelsDir.path)")
            DownloadProgressRegistry.shared.set(progress: 0.0)
            do {
                try await fetchModelBytes(progress: progress)
            } catch {
                DownloadProgressRegistry.shared.set(progress: nil)
                LocalModelState.pushFailure(error.localizedDescription)
                throw error
            }
            DownloadProgressRegistry.shared.set(progress: nil)
            LogManager.shared.log("🎙️ Local: ✅ download complete (\(variant))")
        }

        do {
            _ = try await WhisperModelHost.shared.ensureLoaded(
                aneBudget: prewarmANEBudget, allowGPUFallback: false
            )
        } catch LocalWhisperError.modelLoadTimedOut {
            // The compile is still going and will cache when it lands. The model is on
            // disk and usable, so this is not a download failure; a transcribe started now
            // falls back to the GPU encoder rather than hanging.
            LogManager.shared.log("🎙️ Local: first compile still running past \(Int(prewarmANEBudget))s, leaving it to finish in the background")
        }
        LocalModelState.pushRefresh()
    }

    /// Free space against the volume the model would land on. `ImportantUsage` is the right
    /// key here: it counts space the system would free by evicting purgeable caches, which
    /// is what a large download actually gets to use.
    private static func checkFreeSpace() throws {
        let values = try? modelsDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return }
        guard free >= requiredFreeBytes else {
            let freeGB = String(format: "%.1f", Double(free) / 1_000_000_000)
            throw LocalWhisperError.notEnoughDiskSpace(freeGB)
        }
    }

    /// One resumable retry. HuggingFace keeps the partial bytes, so a flaky link or a CDN
    /// hiccup usually completes on the second attempt without refetching what already
    /// landed. A second failure is reported as a connection problem rather than a bug.
    fileprivate static func fetchModelBytes(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        @Sendable func attempt() async throws {
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: modelsDir,
                useBackgroundSession: false,
                progressCallback: { p in
                    let f = p.totalUnitCount > 0 ? max(0.0, min(1.0, p.fractionCompleted)) : 0.0
                    DownloadProgressRegistry.shared.set(progress: f)
                    progress?(f)
                }
            )
        }
        do {
            try await attempt()
        } catch {
            LogManager.shared.log("🎙️ Local: download failed (\(error)), retrying once", type: .error)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            do {
                try await attempt()
            } catch {
                LogManager.shared.log("🎙️ Local: ❌ download failed again (\(error))", type: .error)
                throw LocalWhisperError.modelDownloadFailed(error.localizedDescription)
            }
        }
    }

    /// Delete the model on disk. Also clears the sibling Hub cache, otherwise the next
    /// download resumes from whatever is staged there.
    static func deleteModel() {
        try? FileManager.default.removeItem(at: modelFolderURL)
        try? FileManager.default.removeItem(at: huggingFaceDownloadCacheURL)
        LocalModelState.pushRefresh()
    }

    // MARK: - Transcription

    /// Serialises runs. `WhisperModelHost` single-flights the LOAD and then hands every
    /// caller the same `WhisperKit` instance - and that instance carries mutable per-run
    /// state (its audio processor, its timings). Two recordings finishing close together is
    /// not exotic: stopping one starts its transcription, which now takes minutes rather
    /// than one HTTP call, and nothing stopped the user recording again meanwhile.
    /// Internal rather than private so a test can occupy it and prove `transcribe` actually
    /// queues behind it. Pinning the gate's own behaviour proves nothing about whether
    /// anything is wired to it - which is how the walk it replaced shipped uncovered.
    static let runs = SerialGate()

    func transcribe(videoURL: URL, multiSpeaker: Bool) async -> EngineResult {
        await Self.runs.enqueue { await self.runTranscription(videoURL: videoURL, multiSpeaker: multiSpeaker) }
    }

    private func runTranscription(videoURL: URL, multiSpeaker: Bool) async -> EngineResult {
        let t0 = Date()
        // multiSpeaker is accepted and ignored: WhisperKit transcribes, it does not tell
        // speakers apart. Honouring the flag needs a diarizer, not a different prompt.
        LogManager.shared.log("🎙️ Local: Starting for \(videoURL.lastPathComponent)")

        guard Self.isAvailable else {
            LogManager.shared.log("🎙️ Local: ⏭️  Not available on this build (Intel or forced Intel behaviour)")
            return Self.failure(code: "not_apple_silicon", fatal: true, since: t0)
        }
        guard Self.isModelDownloaded() else {
            LogManager.shared.log("🎙️ Local: ⏭️  Model not downloaded, refusing to fetch 1.5 GB mid-transcribe")
            return Self.failure(code: "local_model_missing", fatal: true, since: t0)
        }

        guard let audioURL = await AudioPreparation.extractCompressedAudio(from: videoURL) else {
            LogManager.shared.log("🎙️ Local: ❌ Failed to extract audio", type: .error)
            return Self.failure(code: "audio_extraction_failed", fatal: true, since: t0)
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let analysis = await AudioPreparation.analyzeSpeech(audioURL: audioURL)
        LogManager.shared.log("🎙️ Local: VAD - duration=\(String(format: "%.1f", analysis.totalDuration))s, speech=\(String(format: "%.1f", analysis.totalSpeechDuration))s, segments=\(analysis.segments.count), silenceCoverage=\(String(format: "%.2f", analysis.silenceCoverage))")

        if analysis.shouldSkipTranscription {
            // Nothing was said. That is an answer, not a failure: reporting it as one would
            // send the orchestrator into a retry over audio that will stay silent.
            LogManager.shared.log("🎙️ Local: 🤫 No clear speech detected, nothing to transcribe")
            return EngineResult(
                srt: nil, name: nil, usage: .zero, model: Self.modelName,
                latencyMs: Self.elapsedMs(since: t0), attempts: 1,
                success: true, errorCode: nil, fatal: false
            )
        }

        var attempts = 1
        let pipe: WhisperKit
        do {
            let loaded = try await Self.loadForTranscribe()
            pipe = loaded.pipe
            attempts = loaded.attempts
        } catch {
            let mapped = Self.classify(error)
            LogManager.shared.log("🎙️ Local: ❌ Model unavailable: \(error)", type: .error)
            return Self.failure(code: mapped.code, fatal: mapped.fatal, since: t0, attempts: 2)
        }

        // WhisperKit gets the UNTRIMMED extracted audio, so the timestamps it returns are
        // already on the original recording's timeline and `EngineResult.srt` needs no
        // projection back. Trimming silence would save nothing here (there is no per-second
        // cost and WhisperKit's own `.vad` chunking already skips quiet windows) while
        // adding the one bug class that no bounds check catches: cues that are plausible,
        // in range, and drift. So: do not trim.
        let forcedLanguage = await Self.resolveLanguage(pipe, audioPath: audioURL.path)
        let decodeOptions = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: forcedLanguage,
            detectLanguage: forcedLanguage == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: false,
            chunkingStrategy: Self.chunkingStrategy
        )

        let results: [TranscriptionResult]
        do {
            results = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: decodeOptions)
        } catch is CancellationError {
            LogManager.shared.log("🎙️ Local: transcription cancelled")
            return Self.failure(code: "cancelled", fatal: true, since: t0, attempts: attempts)
        } catch {
            // WhisperKit surfaces a killed chunk as a plain NSError with the generic
            // "operation couldn't be completed" wording, so a cancel can arrive without a
            // CancellationError in sight.
            let raw = error.localizedDescription.lowercased()
            if raw.contains("cancel") || raw.contains("operation couldn't be completed") {
                LogManager.shared.log("🎙️ Local: transcription cancelled")
                return Self.failure(code: "cancelled", fatal: true, since: t0, attempts: attempts)
            }
            LogManager.shared.log("🎙️ Local: ❌ Transcription failed: \(error)", type: .error)
            return Self.failure(code: "local_transcribe_failed", fatal: true, since: t0, attempts: attempts)
        }

        // Whisper decodes in 30-second windows and snaps the last segment of a window to its
        // edge, so a 148-second recording hands back a cue ending around 168. `SrtCodec` and
        // the Groq path both bound cues to the recording; do the same here rather than ship a
        // subtitle that outlives the video. A VAD pass that reported no duration is not a
        // reason to throw the transcript away, so that case bounds nothing.
        let recordingEnd = analysis.totalDuration > 0 ? analysis.totalDuration : .infinity

        var segments: [SrtSegment] = []
        var dropped = 0
        for result in results {
            for s in result.segments {
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                guard !Hallucinations.isHallucination(text) else {
                    dropped += 1
                    continue
                }
                let start = Double(s.start)
                guard start < recordingEnd else { continue }
                let end = min(Double(s.end), recordingEnd)
                guard end > start else { continue }
                segments.append(SrtSegment(start: start, end: end, text: text))
            }
        }
        // Chunked decoding hands back one result per window and the windows are not
        // guaranteed to arrive in order.
        segments.sort { $0.start < $1.start }

        // Decoding straight through yields long cues -- eight seconds and more of speech in
        // one block, which is unreadable as a subtitle. The cloud path already splits these
        // on sentence boundaries; reuse it so both engines produce transcripts of the same
        // shape rather than ones that merely contain the same words.
        segments = segments.flatMap { SrtCodec.splitLongSegmentBySentences($0) }

        if dropped > 0 {
            LogManager.shared.log("🎙️ Local: dropped \(dropped) hallucinated cue(s)")
        }

        guard let srt = SrtCodec.serializeSrt(segments) else {
            LogManager.shared.log("🎙️ Local: ❌ VAD found speech but the model produced no usable cues", type: .error)
            return Self.failure(code: "local_empty_transcript", fatal: true, since: t0, attempts: attempts)
        }

        LogManager.shared.log("🎙️ Local: ✅ \(segments.count) cues from \(videoURL.lastPathComponent) in \(Self.elapsedMs(since: t0) / 1000)s")
        return EngineResult(
            // name stays nil: local transcription produces cues and nothing else, so the
            // orchestrator has to ask NamingService for a title separately.
            srt: srt, name: nil,
            usage: .zero, model: Self.modelName,
            latencyMs: Self.elapsedMs(since: t0), attempts: attempts,
            success: true, errorCode: nil, fatal: false
        )
    }

    /// Load the model, repairing it once if the bundle on disk turns out to be corrupt.
    ///
    /// This is the one place a download can start without the user asking. It is a repair
    /// of a model they DID ask for, not a first fetch: the alternative is failing a
    /// two-hour recording and telling them to press Re-transcribe so the exact same broken
    /// bytes can fail again. A second failure propagates, so there is no loop.
    private static func loadForTranscribe() async throws -> (pipe: WhisperKit, attempts: Int) {
        do {
            let pipe = try await WhisperModelHost.shared.ensureLoaded(
                aneBudget: transcribeANEBudget, allowGPUFallback: true
            )
            return (pipe, 1)
        } catch LocalWhisperError.modelCorruptWiped(let detail) {
            LogManager.shared.log("🎙️ Local: corrupt bundle wiped (\(detail)), re-downloading once and retrying the load", type: .error)
            DownloadProgressRegistry.shared.set(progress: 0.0)
            defer { DownloadProgressRegistry.shared.set(progress: nil) }
            try await fetchModelBytes()
            let pipe = try await WhisperModelHost.shared.ensureLoaded(
                aneBudget: transcribeANEBudget, allowGPUFallback: true
            )
            return (pipe, 2)
        }
    }

    // MARK: - Failure mapping

    /// Which failures are worth another run.
    ///
    /// The default is fatal, deliberately. The caller's outer retry re-runs the WHOLE
    /// engine, which on a two-hour recording means re-extracting the audio and decoding it
    /// again from scratch. Only a failure that a later attempt could plausibly survive -
    /// the network, or a cold compile that is still running and will have cached by then -
    /// earns that.
    private static func classify(_ error: Error) -> (code: String, fatal: Bool) {
        switch error {
        case LocalWhisperError.notAvailableOnAppleSilicon:
            return ("not_apple_silicon", true)
        case LocalWhisperError.modelNotReady:
            return ("local_model_missing", true)
        case LocalWhisperError.notEnoughDiskSpace:
            return ("local_disk_full", true)
        case LocalWhisperError.modelCorruptWiped:
            return ("local_model_corrupt", true)
        case LocalWhisperError.modelLoadTimedOut:
            return ("local_model_compiling", false)
        case LocalWhisperError.modelDownloadFailed:
            return ("local_model_download_failed", false)
        case LocalWhisperError.tokenizerUnavailable:
            return ("local_tokenizer_unavailable", false)
        case LocalWhisperError.downloadAlreadyRunning:
            return ("local_download_in_progress", false)
        default:
            return ("local_model_load_failed", true)
        }
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

// MARK: - Errors

enum LocalWhisperError: Error, LocalizedError {
    case notAvailableOnAppleSilicon
    case modelNotReady
    case notEnoughDiskSpace(String)
    case downloadAlreadyRunning
    case modelDownloadFailed(String)
    case tokenizerUnavailable(String)
    /// The bundle failed to load on BOTH encoders, which means it is corrupt rather than
    /// slow, and it has just been wiped along with its download cache.
    case modelCorruptWiped(String)
    /// The model could not COMPILE inside its budget. Distinct from corruption: the bytes
    /// are fine, the compile is still running in the background and will cache when it
    /// lands, so a later run finds it warm.
    case modelLoadTimedOut

    var errorDescription: String? {
        switch self {
        case .notAvailableOnAppleSilicon:
            return "On-device transcription needs an Apple Silicon Mac."
        case .modelNotReady:
            return "The on-device model has not been downloaded yet."
        case .notEnoughDiskSpace(let freeGB):
            return "Not enough disk space for the on-device model: \(freeGB) GB free, about 4 GB needed."
        case .downloadAlreadyRunning:
            return "The on-device model is already downloading."
        case .modelDownloadFailed:
            return "Could not download the on-device model. Check the connection and try again."
        case .tokenizerUnavailable:
            return "Could not fetch the model's tokenizer. Check the connection and try again."
        case .modelCorruptWiped:
            return "The on-device model was incomplete and has been removed. It needs downloading again."
        case .modelLoadTimedOut:
            return "The on-device model is still preparing after its first download. It will be ready shortly."
        }
    }
}

// MARK: - Download progress registry

/// Lock-guarded because `isModelDownloaded()` has to answer synchronously from `isReady`,
/// on whatever thread asks, and it must say NO while bytes are still moving: WhisperKit
/// materialises the package folders early, so the folder-shape check alone flips to "ready"
/// mid-download. `LocalModelState` is the observable mirror for the UI; this is the copy the
/// engine can read without an await.
private final class DownloadProgressRegistry: @unchecked Sendable {
    static let shared = DownloadProgressRegistry()

    private let lock = NSLock()
    private var progress: Double?

    var current: Double? {
        lock.lock(); defer { lock.unlock() }
        return progress
    }

    func set(progress value: Double?) {
        lock.lock()
        progress = value
        lock.unlock()
        LocalModelState.push(progress: value)
    }
}

// MARK: - Model host

/// Owns the loaded WhisperKit instance and everything about getting one.
///
/// An actor rather than a pile of statics because of the single-flight rule below: two
/// concurrent inits genuinely corrupt each other, so the check and the claim have to be
/// atomic.
private actor WhisperModelHost {
    static let shared = WhisperModelHost()

    private var pipe: WhisperKit?
    /// Single-flight guard. `WhisperKit(config)` fetches the tokenizer sidecar at init;
    /// two concurrent inits race on the same `.incomplete` file in the same folder and
    /// corrupt each other, which surfaces later as "Required configuration file missing:
    /// tokenizer.json". Funnelling every caller through one task makes the second wait
    /// instead of starting a competing download.
    private var initTask: Task<Void, Error>?
    /// Whether the in-flight task is a download-time prewarm (long budget, no GPU
    /// fallback) or a transcribe (short budget, GPU fallback). The distinction is load
    /// bearing, see `ensureLoaded`.
    private var initTaskIsPrewarm = false

    func ensureLoaded(aneBudget: Double, allowGPUFallback: Bool) async throws -> WhisperKit {
        try await stageTokenizerIfNeeded()

        if let p = pipe { return p }

        if let inFlight = initTask {
            if !initTaskIsPrewarm {
                // Another TRANSCRIBE is loading. Wait it out in full and reuse its pipe.
                // Starting a second load next to it is not an option: two concurrent GPU
                // loads crash Metal outright (MPSGraph assert, SIGABRT). It is bounded, so
                // waiting is safe.
                do {
                    try await inFlight.value
                    if let p = pipe { return p }
                } catch {
                    LogManager.shared.log("🎙️ Local: in-flight load failed (\(error)), loading ourselves", type: .error)
                }
            } else {
                // A PREWARM is compiling, and its budget is measured in tens of minutes. We
                // must not inherit that wait, so give up at our own budget and load on the
                // GPU instead. That is safe alongside the prewarm because they are
                // different engines: Neural Engine versus Metal, no contention.
                do {
                    try await withDeadline(aneBudget) { try await inFlight.value }
                    if let p = pipe { return p }
                } catch {
                    guard allowGPUFallback else { throw LocalWhisperError.modelLoadTimedOut }
                    LogManager.shared.log("🎙️ Local: prewarm still compiling after \(Int(aneBudget))s, loading on the GPU alongside it")
                    do {
                        try await loadGPU(budget: 180)
                        if let p = pipe { return p }
                    } catch LocalWhisperError.modelLoadTimedOut {
                        // Slowest class of Mac: the GPU compile could not land either. Ride
                        // the prewarm's ANE compile to completion rather than failing the
                        // recording. It does finish, measured at roughly 16 minutes cold,
                        // and it caches.
                        LogManager.shared.log("🎙️ Local: GPU timed out too, riding the prewarm compile to completion")
                        try? await withDeadline(1500) { try await inFlight.value }
                        guard let p = pipe else { throw LocalWhisperError.modelLoadTimedOut }
                        return p
                    }
                }
            }
        }

        let task = Task<Void, Error> {
            try await self.loadPipe(aneBudget: aneBudget, allowGPUFallback: allowGPUFallback)
        }
        initTask = task
        initTaskIsPrewarm = !allowGPUFallback
        defer { initTask = nil }
        try await task.value
        guard let p = pipe else { throw LocalWhisperError.modelNotReady }
        return p
    }

    // MARK: Loading

    private func loadPipe(aneBudget: Double, allowGPUFallback: Bool) async throws {
        purgeIncompleteDownloads()
        clearStaleTokenizer()

        // Nothing below reports progress: the Core ML compile is silent and can run for
        // minutes. Say "preparing" rather than leaving a progress bar frozen near the end.
        LocalModelState.push(preparing: true)
        defer { LocalModelState.push(preparing: false) }

        // On a RAM-constrained Mac, skip the leak-and-fallback dance entirely. A busted ANE
        // budget leaves an uncancellable compile running while we ALSO load the GPU model,
        // and two model loads resident at once can swap-storm an 8 GB machine. The budget
        // here is generous rather than the 180s used below, because with ANE never started
        // the GPU compile runs alone with nothing to race: a slow cold compile just needs
        // time, and capping it would hard-fail the first transcript on exactly the weak
        // Macs this branch protects.
        let ramGB = ProcessInfo.processInfo.physicalMemory / 1_073_741_824
        if ramGB <= 8 {
            LogManager.shared.log("🎙️ Local: \(ramGB) GB RAM, loading on the GPU directly with a generous budget")
            try await loadGPU(budget: 1500)
            return
        }

        LogManager.shared.log("🎙️ Local: loading WhisperKit (ANE) from \(LocalWhisperEngine.modelFolderURL.path), budget \(Int(aneBudget))s")
        do {
            let t0 = Date()
            let box = PipeBox()
            try await withDeadline(aneBudget) { box.set(try await WhisperKit(makeWhisperConfig(useANE: true))) }
            guard let loaded = box.value else { throw LocalWhisperError.modelNotReady }
            pipe = loaded
            LogManager.shared.log(String(format: "🎙️ Local: loaded in %.1fs (encoder=ANE)", Date().timeIntervalSince(t0)))
            return
        } catch is DeadlineError {
            // The init that lost the race keeps compiling and caches when it finishes, so
            // the next load is fast. For this run:
            guard allowGPUFallback else {
                LogManager.shared.log("🎙️ Local: ANE compile past \(Int(aneBudget))s, leaving it to finish and cache in the background")
                throw LocalWhisperError.modelLoadTimedOut
            }
            LogManager.shared.log("🎙️ Local: ANE compile past \(Int(aneBudget))s, falling back to the GPU encoder for this run")
        } catch {
            // A real init error, not a timeout. Do NOT delete 1.5 GB here: an ANE-only
            // error is often transient, and the GPU path below loads the same files fine.
            // Only `loadGPU` deletes, and only when both encoders have failed.
            guard allowGPUFallback else {
                LogManager.shared.log("🎙️ Local: ANE init error (\(error)), model kept, failing this run", type: .error)
                throw error
            }
            LogManager.shared.log("🎙️ Local: ANE init error (\(error)), trying the GPU encoder", type: .error)
        }

        do {
            try await loadGPU(budget: 180)
        } catch LocalWhisperError.modelLoadTimedOut {
            // Both compiles missed their budgets. Rather than fail the recording, wait out
            // the ANE compile leaked in step 1: it is the one that actually completes on
            // slow machines, and once it does the load is warm forever after.
            LogManager.shared.log("🎙️ Local: GPU timed out too, riding the leaked ANE compile to completion")
            let t0 = Date()
            let box = PipeBox()
            try await withDeadline(1500) { box.set(try await WhisperKit(makeWhisperConfig(useANE: true))) }
            guard let loaded = box.value else { throw LocalWhisperError.modelLoadTimedOut }
            pipe = loaded
            LogManager.shared.log(String(format: "🎙️ Local: loaded in %.1fs (encoder=ANE, after the GPU timeout)", Date().timeIntervalSince(t0)))
        }
    }

    /// GPU encoder. Roughly 50 seconds to compile on a typical Mac and the transcript is
    /// identical, just decoded slower.
    ///
    /// The default 180s budget is for the path where this compile races a LEAKED ANE
    /// compile. Do not raise it: on a genuinely slow Mac the GPU compile never lands (a 900s
    /// budget was measured running the full 900s without finishing), it simply thrashes
    /// alongside the ANE compile and doubles the heat for fifteen minutes. Failing fast here
    /// drops to the ANE ride, which is the path that actually completes. The 8 GB caller
    /// overrides with a generous budget because there the GPU has nothing to race.
    private func loadGPU(budget: TimeInterval) async throws {
        let t0 = Date()
        do {
            let box = PipeBox()
            try await withDeadline(budget) { box.set(try await WhisperKit(makeWhisperConfig(useANE: false))) }
            guard let loaded = box.value else { throw LocalWhisperError.modelNotReady }
            pipe = loaded
            LogManager.shared.log(String(format: "🎙️ Local: loaded in %.1fs (encoder=GPU)", Date().timeIntervalSince(t0)))
        } catch is DeadlineError {
            LogManager.shared.log("🎙️ Local: GPU load timed out (>\(Int(budget))s), slow cold compile", type: .error)
            throw LocalWhisperError.modelLoadTimedOut
        } catch {
            LogManager.shared.log("🎙️ Local: GPU init error (\(error)), both encoders failed, wiping the model and its download cache", type: .error)
            LocalWhisperEngine.deleteModel()
            throw LocalWhisperError.modelCorruptWiped(error.localizedDescription)
        }
    }

    // MARK: Tokenizer

    /// Stage the tokenizer before the load rather than during it.
    ///
    /// WhisperKit otherwise fetches it lazily inside `WhisperKit(config)` with no timeout,
    /// so a stalled fetch wedges the whole load indefinitely. Doing it here, bounded and
    /// under the "preparing" banner, makes the load itself purely local. Idempotent and
    /// fast once staged.
    private func stageTokenizerIfNeeded() async throws {
        guard !LocalWhisperEngine.isTokenizerDownloaded() else { return }

        LogManager.shared.log("🎙️ Local: tokenizer missing, pre-fetching it (bounded)")
        LocalModelState.push(preparing: true)
        defer { LocalModelState.push(preparing: false) }

        let base = LocalWhisperEngine.modelsDir
        let modelFolder = LocalWhisperEngine.modelFolderURL
        do {
            try await withDeadline(120) {
                _ = try await ModelUtilities.loadTokenizer(
                    for: .largev3,
                    tokenizerFolder: base,
                    additionalSearchPaths: [modelFolder]
                )
            }
            LogManager.shared.log("🎙️ Local: tokenizer staged")
        } catch is DeadlineError {
            LogManager.shared.log("🎙️ Local: tokenizer fetch timed out (>120s), model kept", type: .error)
            throw LocalWhisperError.tokenizerUnavailable("timed out")
        } catch {
            LogManager.shared.log("🎙️ Local: tokenizer fetch failed (\(error)), model kept", type: .error)
            throw LocalWhisperError.tokenizerUnavailable(error.localizedDescription)
        }
    }

    /// An interrupted tokenizer fetch leaves `tokenizer_config.json` plus Hub metadata but
    /// no `tokenizer.json`, and that stale metadata convinces Hub the file is accounted for,
    /// so it never refetches and every init fails the same way. Removing the folder clears
    /// the poisoned metadata.
    private func clearStaleTokenizer() {
        let fm = FileManager.default
        let folder = LocalWhisperEngine.tokenizerRepoFolderURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return }
        if !fm.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path) {
            try? fm.removeItem(at: folder)
            LogManager.shared.log("🎙️ Local: cleared a stale tokenizer repo (no tokenizer.json)")
        }
    }

    /// Leftover `*.incomplete` markers from an interrupted fetch block the next clean
    /// download with "couldn't be moved" or "configuration file missing". Hub's resume
    /// cannot always recover them.
    private func purgeIncompleteDownloads() {
        let fm = FileManager.default
        for root in [LocalWhisperEngine.modelFolderURL, LocalWhisperEngine.tokenizerRepoFolderURL] {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.lastPathComponent.hasSuffix(".incomplete") {
                try? fm.removeItem(at: url)
                LogManager.shared.log("🎙️ Local: purged stale download fragment \(url.lastPathComponent)")
            }
        }
    }
}

// MARK: - Load plumbing

/// `useANE` picks the audio encoder's compute units: Neural Engine decodes roughly twice as
/// fast but pays a slow one-time compile, the GPU compiles reliably and decodes slower.
/// `download: true` lets WhisperKit fetch the tokenizer sidecar if staging somehow missed
/// it; the model files on disk are reused either way. `prewarm: false` skips a second
/// compile that batch transcription has no use for.
private func makeWhisperConfig(useANE: Bool) -> WhisperKitConfig {
    let compute = useANE
        ? ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine)
        : ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)
    return WhisperKitConfig(
        model: LocalWhisperEngine.variant,
        downloadBase: LocalWhisperEngine.modelsDir,
        modelFolder: LocalWhisperEngine.modelFolderURL.path,
        computeOptions: compute,
        verbose: false,
        logLevel: .error,
        prewarm: false,
        load: true,
        download: true
    )
}

/// Carries a loaded WhisperKit out of the detached task `withDeadline` runs it in. WhisperKit
/// is a plain class, so it cannot travel as a task result.
private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WhisperKit?

    var value: WhisperKit? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func set(_ p: WhisperKit) {
        lock.lock()
        stored = p
        lock.unlock()
    }
}

private enum DeadlineError: Error { case timedOut }

/// Single-shot guard so the race between the operation and the timer resumes the
/// continuation exactly once.
private final class DeadlineOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Run `op`, but stop waiting after `seconds` even if it is wedged somewhere that ignores
/// cancellation, which a Core ML model load is. The operation is left to finish or leak in
/// the background on purpose: an abandoned compile still caches its artifact, which is what
/// makes the next load fast.
private func withDeadline(
    _ seconds: Double,
    _ op: @escaping @Sendable () async throws -> Void
) async throws {
    let once = DeadlineOnce()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        Task.detached {
            do {
                try await op()
                if once.claim() { cont.resume() }
            } catch {
                if once.claim() { cont.resume(throwing: error) }
            }
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.claim() { cont.resume(throwing: DeadlineError.timedOut) }
        }
    }
}
