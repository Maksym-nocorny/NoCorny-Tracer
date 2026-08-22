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
        let result = await engine.transcribe(videoURL: videoURL)

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
