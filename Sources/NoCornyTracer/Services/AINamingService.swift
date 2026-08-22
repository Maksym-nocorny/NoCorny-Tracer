import Foundation
import AVFoundation
import AppKit
import CoreMedia
import ImageIO


/// Turns a finished recording into subtitles and a title.
///
/// The work is split three ways and this type only decides who does what: an engine
/// produces cues, NamingService produces a title, and everything mechanical -- extraction,
/// VAD, chunk math, SRT repair -- lives in the shared helpers next door. Adding an engine
/// therefore does not touch this file.
///
/// Naming is asked for separately whenever the engine did not supply one. That is the case
/// for every engine except Gemini's single-call path, which names a recording in the same
/// response that transcribes it.
final class AINamingService {

    private let engines: [TranscriptionEngineKind: TranscriptionEngine]
    private let namingService: NamingService
    /// Read per run, not captured once: the user can change engines between recordings,
    /// and a lazily-built service that resolved this at init would keep using whatever was
    /// selected the first time the app transcribed anything.
    private let preferredKind: () -> TranscriptionEngineKind

    init(
        proxyClient: GeminiProxyClient,
        transcriptionClient: TranscriptionProxyClient,
        preferredKind: @escaping () -> TranscriptionEngineKind = { .cloudGemini }
    ) {
        let naming = NamingService(proxyClient: proxyClient)
        self.namingService = naming
        self.preferredKind = preferredKind
        self.engines = [
            .cloudGemini: CloudGeminiEngine(proxyClient: proxyClient, namingService: naming),
            .cloudGroq: CloudGroqEngine(proxyClient: transcriptionClient),
            .localWhisper: LocalWhisperEngine(),
        ]
    }

    /// Who gets asked when the chosen engine cannot run, in order. Spelled out rather than
    /// left to `engines.values.first`: with two cloud engines in the map, dictionary order
    /// would make "which service is this recording billed to" arbitrary.
    private static let fallbackOrder: [TranscriptionEngineKind] = [.cloudGemini, .cloudGroq, .localWhisper]

    /// Injection point for tests.
    init(engine: TranscriptionEngine, namingService: NamingService) {
        self.engines = [engine.kind: engine]
        self.namingService = namingService
        self.preferredKind = { engine.kind }
    }

    /// The engine that will actually run: the chosen one when it can, otherwise anything
    /// that can. Falling back matters most for the on-device engine, which reports itself
    /// unready until its model is downloaded -- a recording made before that finishes
    /// should still get transcribed rather than silently produce nothing.
    private var activeEngine: TranscriptionEngine? {
        let wanted = preferredKind()
        if let engine = engines[wanted], engine.isReady { return engine }
        if let fallback = readyEngines.first {
            LogManager.shared.log("🎛️ Engine: \(wanted.rawValue) is not ready, falling back to \(fallback.kind.rawValue)")
            return fallback
        }
        return nil
    }

    private var readyEngines: [TranscriptionEngine] {
        Self.fallbackOrder.compactMap { engines[$0] }.filter(\.isReady)
    }

    /// True when the pipeline can run at all. Callers use it to skip the work up front
    /// rather than to discover the failure one expensive step in.
    var isReady: Bool { activeEngine != nil || namingService.isReady }

    func generateSubtitlesAndName(for videoURL: URL) async -> NamingResult {
        guard let engine = activeEngine else {
            LogManager.shared.log("🎛️ Engine: no engine is ready — sign in, or download the on-device model", type: .error)
            return NamingResult(
                srt: nil, name: nil, usage: .zero, model: "none",
                latencyMs: 0, attempts: 0, success: false,
                errorCode: "no_engine_available", fatal: true
            )
        }

        var result = await engine.transcribe(videoURL: videoURL)

        // An engine an admin has switched off server-side has said nothing about the
        // recording, so it is worth asking someone else instead of returning nothing.
        // Narrow on purpose: only this one code, only when no cues came back, and only one
        // alternative -- anything broader turns a billing decision into a retry loop.
        if result.srt == nil, result.errorCode == "engine_disabled",
           let alternative = readyEngines.first(where: { $0.kind != engine.kind }) {
            LogManager.shared.log("🎛️ Engine: \(engine.kind.rawValue) is switched off server-side, falling back to \(alternative.kind.rawValue)")
            result = await alternative.transcribe(videoURL: videoURL)
        }

        // Only Gemini's single-call path names a recording while transcribing it. Every
        // other engine returns cues alone, so the title is a second, separate call --
        // otherwise on-device transcription would leave every recording named after its
        // timestamp, which reads as the feature being broken rather than free.
        //
        // Sent without frames on purpose. Naming normally ships stills alongside the
        // transcript and they dominate its cost; with a real transcript in hand the text
        // carries the meaning, and this keeps the one call a free-tier recording still
        // makes down to a rounding error.
        // On-device naming needs no account, so a signed-out user transcribing locally can
        // still get a real title rather than a timestamp.
        let canName = namingService.isReady || OnDeviceNaming.isAvailable
        if result.name == nil, let srt = result.srt, !srt.isEmpty, canName {
            let transcript = namingService.namingTranscriptText(SrtCodec.parseAndRepairSrt(srt))
            if !transcript.isEmpty {
                let call = await namingService.generateNameFromTranscript(
                    transcript: transcript, frames: [], glossary: []
                )
                result.name = call.name
                result.usage.add(call.usage)
                result.latencyMs += call.latencyMs
                result.attempts += call.attempts
                if call.name == nil {
                    LogManager.shared.log("🤖 Naming: ⚠️ Could not title a transcript from \(engine.kind.rawValue) — keeping the placeholder", type: .error)
                    result.errorCode = result.errorCode ?? call.errorCode ?? "naming_failed"
                }
            }
        }

        return NamingResult(
            srt: result.srt,
            name: result.name,
            usage: result.usage,
            model: result.model,
            latencyMs: result.latencyMs,
            attempts: result.attempts,
            success: result.success,
            errorCode: result.errorCode,
            fatal: result.fatal,
            totalChunks: result.totalChunks,
            failedChunks: result.failedChunks
        )
    }
}
