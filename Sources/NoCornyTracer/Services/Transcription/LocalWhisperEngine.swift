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

    /// Asked, while a decode runs, whether a cloud engine could take the recording over if
    /// this Mac turns out too slow (see `SlowDecodeProbe`). Wired by the orchestrator from
    /// the cloud engines' readiness; the default says no, so a bare engine (tests, the
    /// benchmark harness) never gives up on its own Mac.
    private let cloudRescueAvailable: @Sendable () -> Bool

    /// Set by the orchestrator around a re-run on this Mac after a hand-off the cloud could
    /// not finish (signed in but offline, plan refused, token dead): the probe stays quiet and
    /// the Mac decodes at whatever speed it has, because the alternative is no transcript.
    @TaskLocal static var rescueDisabled = false

    init(cloudRescueAvailable: @escaping @Sendable () -> Bool = { false }) {
        self.cloudRescueAvailable = cloudRescueAvailable
    }

    /// Reported to telemetry so a local transcript is distinguishable from a Gemini one. The
    /// web's pricing table keys on this exact string (`ai-pricing.ts`), so it stays as it was
    /// across the model switch below: the name was always meant to say "large-v3-turbo", and
    /// from 4.6.0 it finally is one.
    static let modelName = "whisperkit-large-v3-turbo"

    /// The on-device model: OpenAI's Whisper large-v3-turbo (the September 2024 release,
    /// large-v3's encoder with a 4-layer decoder), about 1.6 GB on disk. The string has to
    /// match the folder WhisperKit creates under `argmaxinc/whisperkit-coreml/`.
    ///
    /// Naming trap, learned the expensive way: in that repo the `_turbo` SUFFIX means
    /// Argmax's compressed build of whatever model precedes it, NOT OpenAI's turbo. Up to
    /// 4.5.5 this was `openai_whisper-large-v3_turbo`, believed to be turbo, and it is the
    /// FULL large-v3: `config.json` says `decoder_layers: 32`, the TextDecoder weighs 1.8 GB,
    /// the folder 3 GB, and every transcript decoded through 32 decoder layers instead of 4.
    /// Corder caught it first (0.15.75): a 400 s two-track call on an M1 Air went from 131 s
    /// to 30 s with the real turbo, and the text agreed with the cloud transcript slightly
    /// better. OpenAI's turbo in WhisperKit naming is `large-v3-v20240930`.
    static let defaultVariant = "openai_whisper-large-v3-v20240930_turbo"

    /// The model the app wants: what `downloadModel` fetches and what a fresh Mac ends up
    /// with. A `var` for exactly one reader, the benchmark harness (`LocalASRBenchTests`),
    /// which points it at each variant in turn to time them on the same recording. Nothing
    /// in the app writes it.
    static var variant = defaultVariant

    /// Model folders earlier builds left on disk, oldest last. Read by `activeVariant` so a
    /// Mac that updated keeps transcribing on the model it has until the new one has landed,
    /// and by `reclaimLegacyModels` so the 3 GB folder goes once it is no longer needed.
    static let legacyVariants = ["openai_whisper-large-v3_turbo"]

    /// The model a transcribe loads right now: `variant` when it is complete on disk,
    /// otherwise the first legacy model that is, otherwise `variant` (the download target)
    /// so a missing model reads as "not downloaded" rather than as a legacy path.
    ///
    /// Exists for the update window. Switching the default to a model nobody has yet would
    /// otherwise turn every updated Mac into "model not downloaded" the moment the app
    /// relaunched, and a signed-out user with a two-hour take queued would get nothing until
    /// 1.6 GB had come down. `WhisperModelHost` reloads when this answer changes.
    static var activeVariant: String {
        if isModelDownloaded(variant: variant) { return variant }
        if let legacy = legacyVariants.first(where: { isModelDownloaded(variant: $0) }) { return legacy }
        return variant
    }

    /// What the Settings row shows next to "Ready". The legacy model is three gigabytes,
    /// and a user who looks while the update is still coming down deserves to know why
    /// the number is not the one the changelog promised.
    static var readySizeLabel: String {
        activeVariant == variant ? "Ready · 1.6 GB" : "Ready · 3 GB (older model)"
    }

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
    static var modelFolderURL: URL { modelFolderURL(for: activeVariant) }

    static func modelFolderURL(for variant: String, under base: URL = modelsDir) -> URL {
        base
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    /// HuggingFace's download-staging cache, a SIBLING of the model folder. Hub decides
    /// what is "already fetched" from what is in here, so deleting a corrupt model without
    /// also clearing this makes the next download resume from the same bad bytes forever.
    static var huggingFaceDownloadCacheURL: URL { huggingFaceDownloadCacheURL(for: activeVariant) }

    static func huggingFaceDownloadCacheURL(for variant: String, under base: URL = modelsDir) -> URL {
        modelFolderURL(for: variant, under: base)
            .deletingLastPathComponent()
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent(variant, isDirectory: true)
    }

    // MARK: - Legacy models

    /// Remove model folders earlier builds left behind, once they can no longer be needed.
    ///
    /// Up to 4.5.5 the on-device model was the full large-v3 (3 GB, see `legacyVariants`).
    /// After the update every Mac that had it carries both models until this runs: at launch
    /// and right after a download. Never while the current model is incomplete or still
    /// coming down, because until it lands the legacy folder is the one `activeVariant`
    /// serves transcripts from. Returns the bytes freed, 0 when there was nothing to do.
    @discardableResult
    static func reclaimLegacyModels(under base: URL = modelsDir) -> Int64 {
        guard isModelDownloaded(variant: variant, under: base) else { return 0 }
        let fm = FileManager.default
        var freed: Int64 = 0
        // `variant` can itself be a legacy name (the benchmark harness points it at the old
        // model to time it): the model under test must not be swept away as its own leftover.
        for legacy in legacyVariants where legacy != variant {
            let targets = [modelFolderURL(for: legacy, under: base), huggingFaceDownloadCacheURL(for: legacy, under: base)]
                .filter { fm.fileExists(atPath: $0.path) }
            guard !targets.isEmpty else { continue }
            for url in targets {
                if let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                    for case let file as URL in walker {
                        freed += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                }
                try? fm.removeItem(at: url)
            }
            LogManager.shared.log("🎙️ Local: removed the legacy model \(legacy), freed \(freed / 1_000_000) MB")
        }
        if freed > 0 { LocalModelState.pushRefresh() }
        return freed
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
        isModelDownloaded(variant: activeVariant)
    }

    /// Per variant, so the update window can tell "the new model is still coming down" from
    /// "the legacy model is complete and can serve meanwhile". A download in flight only
    /// disqualifies the variant it is writing.
    static func isModelDownloaded(variant: String, under base: URL = modelsDir) -> Bool {
        if DownloadProgressRegistry.shared.downloadingVariant == variant { return false }

        let dir = modelFolderURL(for: variant, under: base)
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
    ///
    /// `prewarm: false` fetches the bytes and stops. The background auto-download uses it on
    /// 8 GB Macs, where the model host loads on the GPU directly and a transcribe that
    /// arrives mid-compile would start a second GPU init beside it (Metal answers that with
    /// SIGABRT, see `LocalModelWarmup.mayWarm`); there the first transcribe pays the compile
    /// itself, alone, as it always has.
    func downloadModel(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await Self.downloadModel(progress: progress)
    }

    static func downloadModel(prewarm: Bool = true, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard isAvailable else { throw LocalWhisperError.notAvailableOnAppleSilicon }
        guard DownloadProgressRegistry.shared.current == nil else {
            throw LocalWhisperError.downloadAlreadyRunning
        }

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        try checkFreeSpace()

        if !isModelDownloaded(variant: variant) {
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

        if prewarm {
            do {
                if try await !WhisperModelHost.shared.prewarmIfIdle(aneBudget: prewarmANEBudget) {
                    LogManager.shared.log("🎙️ Local: model host busy, leaving the first compile to the background warm")
                }
            } catch LocalWhisperError.modelLoadTimedOut {
                // The compile is still going and will cache when it lands. The model is on
                // disk and usable, so this is not a download failure; a transcribe started now
                // falls back to the GPU encoder rather than hanging.
                LogManager.shared.log("🎙️ Local: first compile still running past \(Int(prewarmANEBudget))s, leaving it to finish in the background")
            }
        }
        LocalModelState.pushRefresh()
        // The new model is complete, so the folder an earlier build left behind has nothing
        // left to serve. Three gigabytes on every Mac that updated.
        await reclaimLegacyModelsWhenIdle()
    }

    /// `reclaimLegacyModels`, gated on the model host being idle. The entry point for the
    /// app; the ungated function is for the unit tests' temporary folders.
    static func reclaimLegacyModelsWhenIdle() async {
        _ = await WhisperModelHost.shared.reclaimLegacyIfIdle()
    }

    /// Re-pay the compile in the background after the system cache has plausibly dropped it
    /// (see `LocalModelWarmup`). Same budget and no GPU fallback, as at download time: the
    /// Neural Engine cache is the one a transcribe tries first.
    static func warmCache(reason: String) async throws {
        guard isAvailable, isModelDownloaded() else { return }
        try await WhisperModelHost.shared.warmCache(reason: reason, aneBudget: prewarmANEBudget)
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
    ///
    /// One variant, decided once. Reading `activeVariant` twice here deleted the new model's
    /// folder on the first line and, with it gone, the LEGACY model's cache on the second,
    /// leaving the new model's poisoned cache behind for the next download to resume from.
    static func deleteModel(variant: String = activeVariant) {
        try? FileManager.default.removeItem(at: modelFolderURL(for: variant))
        try? FileManager.default.removeItem(at: huggingFaceDownloadCacheURL(for: variant))
        LocalModelState.pushRefresh()
    }

    /// "Remove" in Settings: every model this app knows, current and legacy. A user who asks
    /// for the model to go means the 3 GB folder too, not whichever one happened to be active.
    static func deleteAllModels() {
        for v in [variant] + legacyVariants { deleteModel(variant: v) }
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

    func transcribe(
        videoURL: URL,
        multiSpeaker: Bool,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async -> EngineResult {
        await Self.runs.enqueue { await self.runTranscription(videoURL: videoURL, multiSpeaker: multiSpeaker, progress: progress) }
    }

    private func runTranscription(
        videoURL: URL,
        multiSpeaker: Bool,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async -> EngineResult {
        let t0 = Date()
        // multiSpeaker is accepted and ignored: WhisperKit transcribes, it does not tell
        // speakers apart. Honouring the flag needs a diarizer, not a different prompt.
        LogManager.shared.log("🎙️ Local: Starting for \(videoURL.lastPathComponent)")

        guard Self.isAvailable else {
            LogManager.shared.log("🎙️ Local: ⏭️  Not available on this build (Intel or forced Intel behaviour)")
            return Self.failure(code: "not_apple_silicon", fatal: true, since: t0)
        }
        guard Self.isModelDownloaded() else {
            LogManager.shared.log("🎙️ Local: ⏭️  Model not downloaded, refusing to fetch 1.6 GB mid-transcribe")
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

        // Progress from segment discovery: WhisperKit has no percentage of its own, so the
        // share is the last decoded cue's end against the recording's duration. Windows can
        // land out of order, so the fraction is held monotonic; chunk counts are 0/0, the
        // signal for "a share of time, not of chunks". The callback lives on the SHARED
        // WhisperKit instance, so it is cleared before this function returns -- the serial
        // gate guarantees nobody else is mid-transcribe while it is set.
        let totalDuration = analysis.totalDuration
        let monotonic = MonotonicProgress()
        if totalDuration > 0 {
            pipe.segmentDiscoveryCallback = { segments in
                guard let last = segments.last else { return }
                guard let fraction = monotonic.advance(to: Double(last.end) / totalDuration) else { return }
                progress(TranscriptionProgress(completedChunks: 0, totalChunks: 0, fraction: fraction))
            }
        }
        defer { pipe.segmentDiscoveryCallback = nil }

        // The slow-Mac probe reads the same monotonic fraction the bar does, credited with the
        // silence the VAD saw after it (Whisper reports nothing for a quiet window, and a
        // quiet minute must not read as a slow minute). Without a duration there is no rate
        // to judge, so such a run is never handed off.
        let decodeStart = Date()
        let decodingVariant = Self.activeVariant
        let speech = analysis.segments.map { (start: $0.startSeconds, end: $0.endSeconds) }
        let canRescue = cloudRescueAvailable
        let rescueOff = Self.rescueDisabled
        let decodedSeconds: @Sendable () -> Double = {
            SlowDecodeProbe.creditedPosition(position: monotonic.current * totalDuration, speech: speech, duration: totalDuration)
        }

        let results: [TranscriptionResult]
        do {
            switch try await Self.decode(
                pipe: pipe, audioPath: audioURL.path, options: decodeOptions,
                decodedSeconds: decodedSeconds,
                canRescue: { totalDuration > 0 && !rescueOff && canRescue() }
            ) {
            case .results(let decoded):
                results = decoded
            case .tooSlow(let factor, let decoded, let wall):
                LogManager.shared.log(String(format: "🎙️ Local: ⏭️  decoding at %.2fx real time (%.0f s of %.0f s in %.0f s), this Mac is too slow, handing the recording to the cloud", factor, decoded, totalDuration, wall))
                return Self.failure(code: Self.tooSlowCode, fatal: true, since: t0, attempts: attempts)
            }
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

        Self.logDecodeSummary(results: results, audioSec: totalDuration, variant: decodingVariant, since: decodeStart)

        // Whisper decodes in 30-second windows and snaps the last segment of a window to its
        // edge, so a 148-second recording hands back a cue ending around 168. `SrtCodec` and
        // the Groq path both bound cues to the recording; do the same here rather than ship a
        // subtitle that outlives the video. A VAD pass that reported no duration is not a
        // reason to throw the transcript away, so that case bounds nothing.
        let recordingEnd = analysis.totalDuration > 0 ? analysis.totalDuration : .infinity

        var dropped = 0
        var segments = Self.cues(from: results, recordingEnd: recordingEnd, dropped: &dropped)
        // Chunked decoding hands back one result per window and the windows are not
        // guaranteed to arrive in order.
        segments.sort { $0.start < $1.start }

        // Whisper drops whole 30-second windows now and then: on a 289 s take the turbo
        // model came back without 227-257 s in one run of five and without 182-212 s in
        // another, nothing hallucinated, nothing logged, the speech simply absent. The VAD
        // already knows where people spoke, so every voiced stretch the decode left without a
        // cue is decoded again on its own; a window that collapsed in context decodes fine
        // from its own start. Corder found the same (0.15.64) and recovers the same way.
        let gaps = GapRecovery.uncoveredSpans(
            speech: speech, cues: segments.map { (start: $0.start, end: $0.end) }, duration: recordingEnd
        )
        if !gaps.isEmpty {
            let listed = gaps.map { String(format: "%.0f-%.0f", $0.start, $0.end) }.joined(separator: ", ")
            LogManager.shared.log("🎙️ Local: \(gaps.count) voiced span(s) came back without cues (\(listed) s), decoding them again alone")
            var clipOptions = decodeOptions
            clipOptions.clipTimestamps = gaps.flatMap { [Float($0.start), Float($0.end)] }
            // A short clip is a poor place to guess a language: hold the main pass's answer.
            if clipOptions.language == nil, let majority = Self.majorityLanguage(of: results) {
                clipOptions.language = majority
                clipOptions.detectLanguage = false
            }
            do {
                let extra = try await pipe.transcribe(audioPath: audioURL.path, decodeOptions: clipOptions)
                var droppedInGaps = 0
                var recovered = Self.cues(from: extra, recordingEnd: recordingEnd, dropped: &droppedInGaps)
                    .filter { cue in gaps.contains { cue.start < $0.end && cue.end > $0.start } }
                let isEcho: (SrtSegment) -> Bool = { cue in
                    GapRecovery.isEdgeEcho(
                        cue.text,
                        previous: segments.last(where: { $0.end <= cue.start + 0.001 })?.text,
                        next: segments.first(where: { $0.start >= cue.end - 0.001 })?.text
                    )
                }
                let echoes = recovered.filter(isEcho).count
                recovered.removeAll(where: isEcho)
                let noise = recovered.filter { !GapRecovery.isPlausibleRecovery(text: $0.text) }.count
                recovered.removeAll { !GapRecovery.isPlausibleRecovery(text: $0.text) }
                dropped += droppedInGaps
                segments.append(contentsOf: recovered)
                segments.sort { $0.start < $1.start }
                LogManager.shared.log("🎙️ Local: recovered \(recovered.count) cue(s) from the gaps\(echoes > 0 ? ", dropped \(echoes) edge echo(es)" : "")\(noise > 0 ? ", dropped \(noise) filler(s) over noise" : "")")
            } catch {
                // The transcript in hand is still a transcript; the gaps stay gaps.
                LogManager.shared.log("🎙️ Local: gap recovery failed (\(error)), keeping the transcript as decoded", type: .error)
            }
        }

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

    // MARK: - Decoding

    /// WhisperKit's segments as cues on the recording's timeline: trimmed, with hallucinated
    /// lines dropped and counted, and bounded to the recording. Whisper snaps the last
    /// segment of a window to the window's edge, so a 148-second recording hands back a cue
    /// ending around 168; bounding it here is what keeps a subtitle from outliving its video.
    private static func cues(from results: [TranscriptionResult], recordingEnd: Double, dropped: inout Int) -> [SrtSegment] {
        var segments: [SrtSegment] = []
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
        return segments
    }

    /// The language most windows of a pass agreed on, for the gap clips to inherit.
    private static func majorityLanguage(of results: [TranscriptionResult]) -> String? {
        var tally: [String: Int] = [:]
        for r in results where !r.segments.isEmpty { tally[r.language, default: 0] += r.segments.count }
        return tally.max { $0.value < $1.value }?.key
    }

    /// The error code a run too slow for this Mac comes back with. The orchestrator treats
    /// it like a refusal and asks a cloud engine; it is never retried on-device.
    static let tooSlowCode = "local_too_slow"

    private enum DecodeOutcome {
        case results([TranscriptionResult])
        case tooSlow(factor: Double, decodedSec: Double, wall: TimeInterval)
    }

    /// Run the decode with a probe beside it. Whichever answers first decides, and the other
    /// is cancelled: WhisperKit checks for cancellation between windows, so a handed-off
    /// decode stops within one window rather than running on for an hour behind the cloud.
    ///
    /// The probe never fires without somewhere to go. A signed-out Mac keeps decoding at
    /// whatever speed it has, because a slow transcript is still a transcript and the
    /// alternative is none.
    private static func decode(
        pipe: WhisperKit,
        audioPath: String,
        options: DecodingOptions,
        decodedSeconds: @escaping @Sendable () -> Double,
        canRescue: @escaping @Sendable () -> Bool
    ) async throws -> DecodeOutcome {
        try await withThrowingTaskGroup(of: DecodeOutcome?.self) { group in
            group.addTask {
                .results(try await pipe.transcribe(audioPath: audioPath, decodeOptions: options))
            }
            group.addTask {
                let start = Date()
                while true {
                    try await Task.sleep(nanoseconds: UInt64(SlowDecodeProbe.interval * 1_000_000_000))
                    let wall = Date().timeIntervalSince(start)
                    let decoded = decodedSeconds()
                    if SlowDecodeProbe.isTooSlow(decodedAudioSec: decoded, wallSec: wall), canRescue() {
                        return .tooSlow(factor: decoded / wall, decodedSec: decoded, wall: wall)
                    }
                }
            }
            defer { group.cancelAll() }
            for try await outcome in group {
                if let outcome { return outcome }
            }
            throw CancellationError()
        }
    }

    /// One line per run with what WhisperKit measured: wall time against audio time, encoder
    /// and decoder seconds, decoder loops and temperature fallbacks, and the language it
    /// detected per window. Before 4.6.0 the log had the cue count and nothing else, so a
    /// slow transcript could not be told apart from a fallback storm or a mis-detected
    /// language. Nothing in it identifies the recording.
    private static func logDecodeSummary(results: [TranscriptionResult], audioSec: Double, variant: String, since start: Date) {
        let wall = Date().timeIntervalSince(start)
        var languages: [String: Int] = [:]
        var encode = 0.0, decode = 0.0, loops = 0.0, fallbackSec = 0.0
        for r in results {
            languages[r.language, default: 0] += 1
            encode += r.timings.encoding
            decode += r.timings.decodingLoop
            loops += r.timings.totalDecodingLoops
            // Seconds spent in temperature fallbacks. WhisperKit's fallback COUNT is assigned,
            // not summed, so it reads as the last window's temperature index, not a total.
            fallbackSec += r.timings.decodingFallback
        }
        let langs = languages.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        LogManager.shared.log(String(
            format: "🎙️ Local: decoded %.0f s of audio in %.1f s (%.2fx real time) on %@, encode %.1f s, decode %.1f s, %.0f decoder loops, %.1f s in fallbacks, language: %@",
            audioSec, wall, audioSec / max(wall, 0.001), variant, encode, decode, loops, fallbackSec, langs.isEmpty ? "none" : langs
        ))
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

// MARK: - Gap recovery

/// Which stretches of speech a decode left without a single cue, so they can be decoded
/// again on their own. Pure: the VAD's segments and the decode's cues go in, clip ranges on
/// the recording's timeline come out.
enum GapRecovery {
    /// Voiced audio a stretch must hold before it earns a second decode. Below this it is a
    /// cough, a "yes", or the VAD's edge, and a clip that short confuses Whisper more than it
    /// helps.
    static let minVoicedSec: Double = 2.0
    /// Air around each clip so Whisper hears the sentence edges rather than a word cut in half.
    static let padSec: Double = 0.5
    /// Stretches closer than this decode as one clip.
    static let mergeGapSec: Double = 1.0
    /// The most clips one run re-decodes. A transcript missing more than this did not lose
    /// windows, it lost the recording (wrong language, broken audio), and a second pass would
    /// only lose it again, slower.
    static let maxSpans = 40

    struct Span: Equatable {
        let start: Double
        let end: Double
    }

    static func uncoveredSpans(
        speech: [(start: Double, end: Double)],
        cues: [(start: Double, end: Double)],
        duration: Double,
        minVoiced: Double = minVoicedSec,
        pad: Double = padSec,
        mergeGap: Double = mergeGapSec,
        cap: Int = maxSpans
    ) -> [Span] {
        let sortedCues = cues.sorted { $0.start < $1.start }

        // Each voiced segment minus every cue that overlaps it, keeping the uncovered pieces
        // long enough to matter.
        var pieces: [Span] = []
        for seg in speech.sorted(by: { $0.start < $1.start }) {
            var cursor = seg.start
            for cue in sortedCues where cue.end > seg.start && cue.start < seg.end {
                if cue.start > cursor, cue.start - cursor >= minVoiced {
                    pieces.append(Span(start: cursor, end: cue.start))
                }
                cursor = max(cursor, cue.end)
            }
            if seg.end > cursor, seg.end - cursor >= minVoiced {
                pieces.append(Span(start: cursor, end: seg.end))
            }
        }
        guard !pieces.isEmpty, pieces.count <= cap else { return [] }

        // Merge neighbours, unless a cue sits between them: re-decoding across an existing
        // cue would say its words a second time. Then pad, then clamp to the recording.
        var merged: [Span] = []
        for piece in pieces {
            if let last = merged.last, piece.start - last.end <= mergeGap,
               !sortedCues.contains(where: { $0.start >= last.end - 0.001 && $0.end <= piece.start + 0.001 }) {
                merged[merged.count - 1] = Span(start: last.start, end: max(last.end, piece.end))
            } else {
                merged.append(piece)
            }
        }
        // Pad for the sentence edges, but never into a neighbouring cue: a clip that starts
        // half a second inside the previous cue transcribes its last word again, and that word
        // came back as a subtitle of its own ("application" after "...in the application.").
        let limit = duration.isFinite ? duration : .greatestFiniteMagnitude
        return merged.map { span in
            let previousEnd = sortedCues.filter { $0.end <= span.start + 0.001 }.map(\.end).max() ?? 0
            let nextStart = sortedCues.filter { $0.start >= span.end - 0.001 }.map(\.start).min() ?? limit
            return Span(start: max(previousEnd, max(0, span.start - pad)),
                        end: min(nextStart, min(limit, span.end + pad)))
        }.filter { $0.end > $0.start }
    }

    /// A recovered cue that merely repeats the edge of a neighbour. Whisper tends to re-say
    /// the word a clip starts or ends on; a one- or two-word cue that is the tail of the cue
    /// before it or the head of the cue after it is that echo, not speech that was missing.
    static func isEdgeEcho(_ text: String, previous: String?, next: String?) -> Bool {
        let w = tokens(text)
        guard !w.isEmpty, w.count <= 2 else { return false }
        if let p = previous.map(tokens), p.count >= w.count, Array(p.suffix(w.count)) == w { return true }
        if let n = next.map(tokens), n.count >= w.count, Array(n.prefix(w.count)) == w { return true }
        return false
    }

    /// Whether a recovered cue reads like recovered speech at all. The clips come from
    /// stretches the main pass found nothing in, and an energy VAD counts keyboard clatter
    /// and room noise as "voice", so Whisper is handed noise here more than anywhere else and
    /// answers it with its favourite fillers: "Thank you." over twelve seconds of typing, a
    /// lone "you". Their timestamps are invented too (the same "Thank you." came back as one
    /// second on the next run), so duration cannot tell them apart. What can: this pass
    /// exists to put back a LOST WINDOW, which is tens of words. One or two words in a
    /// stretch the first pass heard nothing in are noise, and are dropped whatever they say.
    static func isPlausibleRecovery(text: String) -> Bool {
        tokens(text).count >= 3
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }
}

// MARK: - Slow-Mac probe

/// When an on-device decode is too slow to be worth finishing here.
///
/// The numbers are Corder's, measured on real Macs (0.15.71): a healthy Apple Silicon Mac
/// decodes at 2x to 10x real time with the turbo model, while an 8 GB Mac under memory
/// pressure ran at a fifth of real time and spent 83 minutes on 12 minutes of speech. Pure,
/// so the decision is covered without a model on disk.
enum SlowDecodeProbe {
    /// How long a decode runs before anyone judges it. The first stretch of a cold run goes
    /// to the window warm-up and, on a Mac that missed its Neural Engine budget, to the slower
    /// GPU encoder; judging earlier would hand healthy Macs to the cloud for nothing.
    static let probeAfter: TimeInterval = 180
    /// Audio seconds decoded per wall second below which the Mac is too slow.
    static let realtimeFloor: Double = 0.5
    /// How often the probe looks.
    static let interval: TimeInterval = 15

    static func isTooSlow(
        decodedAudioSec: Double,
        wallSec: TimeInterval,
        probeAfter: TimeInterval = probeAfter,
        floor: Double = realtimeFloor
    ) -> Bool {
        guard wallSec >= probeAfter else { return false }
        return decodedAudioSec / wallSec < floor
    }

    /// How far the decoder is, credited with the silence ahead of it. The bar moves on the
    /// end of the last cue, and Whisper says nothing for a window with no speech, so during
    /// a quiet stretch the position stands still while the decoder is in fact racing through
    /// it. A position inside speech is taken as is; one in silence is moved to the start of
    /// the next speech segment, or to the end when none is left. Generous on purpose: the
    /// cost of under-reporting is a hand-off a healthy Mac did not need.
    static func creditedPosition(position: Double, speech: [(start: Double, end: Double)], duration: Double) -> Double {
        if speech.contains(where: { position >= $0.start && position < $0.end }) { return position }
        let next = speech.map(\.start).filter { $0 > position }.min()
        return min(duration, next ?? duration)
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
    /// Which folder the bytes are landing in. A download only makes ITS variant read as
    /// incomplete; the legacy model next to it stays usable for the whole update window.
    private var variant: String?

    var current: Double? {
        lock.lock(); defer { lock.unlock() }
        return progress
    }

    var downloadingVariant: String? {
        lock.lock(); defer { lock.unlock() }
        return variant
    }

    func set(progress value: Double?) {
        lock.lock()
        progress = value
        variant = value == nil ? nil : LocalWhisperEngine.variant
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
    /// Which model folder `pipe` was loaded from. The folder on disk can change under a
    /// resident instance: the real turbo lands while the legacy model is loaded, and
    /// `LocalWhisperEngine.activeVariant` moves. The next caller then gets a fresh load
    /// rather than the model the app has already stopped wanting.
    private var loadedVariant: String?
    /// Single-flight guard. `WhisperKit(config)` fetches the tokenizer sidecar at init;
    /// two concurrent inits race on the same `.incomplete` file in the same folder and
    /// corrupt each other, which surfaces later as "Required configuration file missing:
    /// tokenizer.json". Funnelling every caller through one task makes the second wait
    /// instead of starting a competing download.
    private var initTask: Task<WhisperKit, Error>?
    /// Whether the in-flight task is a download-time prewarm (long budget, no GPU
    /// fallback) or a transcribe (short budget, GPU fallback). The distinction is load
    /// bearing, see `ensureLoaded`.
    private var initTaskIsPrewarm = false

    func ensureLoaded(aneBudget: Double, allowGPUFallback: Bool) async throws -> WhisperKit {
        try await stageTokenizerIfNeeded()

        if let p = pipe {
            if loadedVariant == LocalWhisperEngine.activeVariant { return p }
            // Safe to drop: a transcribe reaches here only through the serial gate, and a
            // background warm only when nothing is resident, so nobody is mid-decode on it.
            LogManager.shared.log("🎙️ Local: model on disk changed (\(loadedVariant ?? "?") → \(LocalWhisperEngine.activeVariant)), releasing the loaded one")
            pipe = nil
            loadedVariant = nil
        }

        if let inFlight = initTask {
            if !initTaskIsPrewarm {
                // Another TRANSCRIBE is loading. Wait it out in full and reuse its pipe.
                // Starting a second load next to it is not an option: two concurrent GPU
                // loads crash Metal outright (MPSGraph assert, SIGABRT). It is bounded, so
                // waiting is safe.
                do {
                    try await inFlight.value
                    if let p = residentIfCurrent() { return p }
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
                    if let p = residentIfCurrent() { return p }
                } catch {
                    guard allowGPUFallback else { throw LocalWhisperError.modelLoadTimedOut }
                    LogManager.shared.log("🎙️ Local: prewarm still compiling after \(Int(aneBudget))s, loading on the GPU alongside it")
                    do {
                        try await loadGPU(budget: 180, variant: LocalWhisperEngine.activeVariant)
                        if let p = residentIfCurrent() { return p }
                    } catch LocalWhisperError.modelLoadTimedOut {
                        // Slowest class of Mac: the GPU compile could not land either. Ride
                        // the prewarm's ANE compile to completion rather than failing the
                        // recording. It does finish, measured at roughly 16 minutes cold,
                        // and it caches.
                        LogManager.shared.log("🎙️ Local: GPU timed out too, riding the prewarm compile to completion")
                        let landed = (try? await withDeadline(1500) { try await inFlight.value }) != nil
                        if let p = residentIfCurrent() { return p }
                        // A background warm lets its model go the moment it lands, so the ride
                        // can end at an empty host with the cache now warm: load our own below.
                        // Still compiling or failed stays a timeout, because a second init
                        // beside a live compile is the corruption this host exists to prevent.
                        guard landed, initTask == nil else { throw LocalWhisperError.modelLoadTimedOut }
                    }
                }
            }
        }

        let task = Task<WhisperKit, Error> {
            try await self.loadPipe(aneBudget: aneBudget, allowGPUFallback: allowGPUFallback)
        }
        initTask = task
        initTaskIsPrewarm = !allowGPUFallback
        // Ours to clear only while it is still ours: a waiter that resumed first may have
        // started its own load by now, and wiping that would let a third caller start a
        // second init beside it, the corruption this host exists to prevent.
        defer { if initTask == task { initTask = nil } }
        // The instance THIS load produced, not whatever `pipe` holds by the time the await
        // returns: a waiter that saw the model on disk change can have released it meanwhile.
        return try await task.value
    }

    /// The resident instance, but only if it came from the folder the engine wants NOW. A
    /// load that was in flight while the new model landed may have adopted the legacy one;
    /// handing that out would keep the slow model in service for the rest of the session.
    private func residentIfCurrent() -> WhisperKit? {
        guard let p = pipe else { return nil }
        guard loadedVariant == LocalWhisperEngine.activeVariant else {
            pipe = nil
            loadedVariant = nil
            return nil
        }
        return p
    }

    /// The download-time compile. Only when nothing is loaded or loading: a transcribe mid-load
    /// on the legacy model and a prewarm of the new one resuming in the wrong order used to
    /// leave the transcribe with no instance at all (`local_model_missing`, no cloud fallback).
    /// Returns false when it stood aside; the background warm pays the compile later.
    func prewarmIfIdle(aneBudget: Double) async throws -> Bool {
        // A resident instance of a model the engine no longer wants is not "busy": the new
        // model has to be compiled regardless, and nobody is decoding on the old one here.
        guard residentIfCurrent() == nil, initTask == nil else { return false }
        _ = try await ensureLoaded(aneBudget: aneBudget, allowGPUFallback: false)
        return true
    }

    /// Delete the legacy folders, but never under a load: WhisperKit reads the encoder last,
    /// after minutes of decoder compile on an 8 GB Mac, and a folder that vanishes meanwhile
    /// fails the load and wipes a model. Synchronous inside the actor, so no load can start
    /// between the check and the removal. A resident instance is fine: its weights are mapped
    /// into memory and outlive the files.
    func reclaimLegacyIfIdle() -> Int64 {
        guard initTask == nil else {
            LogManager.shared.log("🎙️ Local: legacy model left in place, a load is in flight")
            return 0
        }
        return LocalWhisperEngine.reclaimLegacyModels()
    }

    /// Load for the cache's sake, then let the model go. A resident model would hold its
    /// weights in memory for a recording that may be days away, and the next transcribe
    /// reloads from a warm cache in about two seconds.
    ///
    /// Nothing to do when a model is already resident (it is what the next transcribe gets)
    /// or when a load is already running (it fills the cache itself, and a second init beside
    /// it corrupts both). A resident model does NOT refresh the stamp: the stamp dates the
    /// last load, and an app left open for a week on one early transcript must still warm
    /// after its next launch. A transcribe that joins while this warm is loading keeps the
    /// reference it was handed; dropping ours does not touch it.
    func warmCache(reason: String, aneBudget: Double) async throws {
        guard residentIfCurrent() == nil, initTask == nil else { return }
        LogManager.shared.log("🎙️ Local: warming the model cache in the background (\(reason))")
        let t0 = Date()
        _ = try await ensureLoaded(aneBudget: aneBudget, allowGPUFallback: false)
        pipe = nil
        LogManager.shared.log(String(format: "🎙️ Local: ✅ model cache warm in %.1fs, model released", Date().timeIntervalSince(t0)))
    }

    /// Every successful load goes through here, so the warm-up schedule knows the cache was
    /// just filled no matter who asked for the load.
    private func adopt(_ loaded: WhisperKit, variant: String) {
        pipe = loaded
        loadedVariant = variant
        LocalModelWarmup.recordLoad(variant: variant)
    }

    // MARK: Loading

    private func loadPipe(aneBudget: Double, allowGPUFallback: Bool) async throws -> WhisperKit {
        purgeIncompleteDownloads()
        clearStaleTokenizer()

        // Pinned once per load. A download finishing mid-compile must not make the config
        // and the bookkeeping disagree about which folder this instance came from.
        let variant = LocalWhisperEngine.activeVariant

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
            return try await loadGPU(budget: 1500, variant: variant)
        }

        LogManager.shared.log("🎙️ Local: loading WhisperKit (ANE) from \(LocalWhisperEngine.modelFolderURL(for: variant).path), budget \(Int(aneBudget))s")
        do {
            let t0 = Date()
            let box = PipeBox()
            try await withDeadline(aneBudget) { box.set(try await WhisperKit(makeWhisperConfig(useANE: true, variant: variant))) }
            guard let loaded = box.value else { throw LocalWhisperError.modelNotReady }
            adopt(loaded, variant: variant)
            LogManager.shared.log(String(format: "🎙️ Local: loaded in %.1fs (encoder=ANE)", Date().timeIntervalSince(t0)))
            return loaded
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
            return try await loadGPU(budget: 180, variant: variant)
        } catch LocalWhisperError.modelLoadTimedOut {
            // Both compiles missed their budgets. Rather than fail the recording, wait out
            // the ANE compile leaked in step 1: it is the one that actually completes on
            // slow machines, and once it does the load is warm forever after.
            LogManager.shared.log("🎙️ Local: GPU timed out too, riding the leaked ANE compile to completion")
            let t0 = Date()
            let box = PipeBox()
            try await withDeadline(1500) { box.set(try await WhisperKit(makeWhisperConfig(useANE: true, variant: variant))) }
            guard let loaded = box.value else { throw LocalWhisperError.modelLoadTimedOut }
            adopt(loaded, variant: variant)
            LogManager.shared.log(String(format: "🎙️ Local: loaded in %.1fs (encoder=ANE, after the GPU timeout)", Date().timeIntervalSince(t0)))
            return loaded
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
    @discardableResult
    private func loadGPU(budget: TimeInterval, variant: String) async throws -> WhisperKit {
        let t0 = Date()
        do {
            let box = PipeBox()
            try await withDeadline(budget) { box.set(try await WhisperKit(makeWhisperConfig(useANE: false, variant: variant))) }
            guard let loaded = box.value else { throw LocalWhisperError.modelNotReady }
            adopt(loaded, variant: variant)
            LogManager.shared.log(String(format: "🎙️ Local: loaded in %.1fs (encoder=GPU)", Date().timeIntervalSince(t0)))
            return loaded
        } catch is DeadlineError {
            LogManager.shared.log("🎙️ Local: GPU load timed out (>\(Int(budget))s), slow cold compile", type: .error)
            throw LocalWhisperError.modelLoadTimedOut
        } catch {
            LogManager.shared.log("🎙️ Local: GPU init error (\(error)), both encoders failed, wiping \(variant) and its download cache", type: .error)
            LocalWhisperEngine.deleteModel(variant: variant)
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
private func makeWhisperConfig(useANE: Bool, variant: String) -> WhisperKitConfig {
    let compute = useANE
        ? ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine)
        : ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)
    return WhisperKitConfig(
        model: variant,
        downloadBase: LocalWhisperEngine.modelsDir,
        modelFolder: LocalWhisperEngine.modelFolderURL(for: variant).path,
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
