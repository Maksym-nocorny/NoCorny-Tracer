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

    private let engine: TranscriptionEngine
    private let namingService: NamingService

    init(proxyClient: GeminiProxyClient) {
        let naming = NamingService(proxyClient: proxyClient)
        self.namingService = naming
        self.engine = CloudGeminiEngine(proxyClient: proxyClient, namingService: naming)
    }

    /// Injection point for a different engine (tests, and the on-device path).
    init(engine: TranscriptionEngine, namingService: NamingService) {
        self.engine = engine
        self.namingService = namingService
    }

    /// True when the pipeline can run at all. Callers use it to skip the work up front
    /// rather than to discover the failure one expensive step in.
    var isReady: Bool { engine.isReady || namingService.isReady }

    func generateSubtitlesAndName(for videoURL: URL) async -> NamingResult {
        var result = await engine.transcribe(videoURL: videoURL)

        // Only Gemini's single-call path names a recording while transcribing it. Every
        // other engine returns cues alone, so the title is a second, separate call --
        // otherwise on-device transcription would leave every recording named after its
        // timestamp, which reads as the feature being broken rather than free.
        //
        // Sent without frames on purpose. Naming normally ships stills alongside the
        // transcript and they dominate its cost; with a real transcript in hand the text
        // carries the meaning, and this keeps the one call a free-tier recording still
        // makes down to a rounding error.
        if result.name == nil, let srt = result.srt, !srt.isEmpty, namingService.isReady {
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
