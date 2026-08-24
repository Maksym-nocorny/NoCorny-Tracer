import Foundation

/// Which engine turns a recording into cues.
enum TranscriptionEngineKind: String, CaseIterable, Identifiable {
    /// Gemini through tracer.nocorny.com. Multimodal: it sees frames as well as audio,
    /// which is why it can name a recording in the same call that transcribes it.
    case cloudGemini = "cloud"
    /// Whisper on Groq, through the same proxy. Cues only, like the on-device engine: it
    /// hears the recording but never sees it, so a title comes from a separate call.
    case cloudGroq = "groq"
    /// Whisper on this Mac. Free and offline, and it produces cues only -- a title still
    /// has to come from somewhere else.
    case localWhisper = "local"

    var id: String { rawValue }

    /// How `/api/tokens/me` names this engine in `features.cloudEngines`. Spelled out
    /// rather than derived from `rawValue`, which is a persisted UserDefaults key and says
    /// "cloud" for Gemini for historical reasons.
    var serverName: String? {
        switch self {
        case .cloudGemini: return "gemini"
        case .cloudGroq: return "groq"
        case .localWhisper: return nil  // never asks the server for permission
        }
    }

    /// What the Settings picker offers.
    ///
    /// Groq is parked: no key on the server, switched off, and not for sale - so listing it,
    /// even padlocked, advertises a choice nobody can make. It appears only when the server
    /// EXPLICITLY offers it, which inverts the permissive default on purpose: for gemini,
    /// "the server said nothing" must mean available (a server rollback must not lock
    /// people out), but for a parked engine the same silence must mean absent - visibility
    /// is an announcement, and announcements are opt-in.
    static func pickerCases(offeredCloudEngines: [String]?) -> [TranscriptionEngineKind] {
        allCases.filter { kind in
            kind != .cloudGroq || (offeredCloudEngines?.contains("groq") ?? false)
        }
    }

    var displayName: String {
        switch self {
        case .cloudGemini: return "Cloud (Gemini)"
        case .cloudGroq: return "Cloud (Groq)"
        case .localWhisper: return "On this Mac"
        }
    }
}

/// What an engine hands back. Same shape as `NamingResult` on purpose -- the orchestrator
/// maps between them -- with one rule the protocol depends on:
///
/// **`srt` is always on the ORIGINAL recording's timeline.** Engines that trim silence or
/// cut chunks are responsible for mapping their cues back before returning. Getting this
/// wrong produces subtitles that look plausible and drift, which no bounds check catches.
struct EngineResult {
    var srt: String?
    /// Non-nil only when the engine names the recording as a side effect of transcribing
    /// it, as the Gemini single-call path does. Otherwise the orchestrator asks
    /// NamingService separately.
    var name: String?
    var usage: GeminiUsage
    var model: String
    var latencyMs: Int
    var attempts: Int
    /// Whether the run produced anything usable at all.
    var success: Bool
    var errorCode: String?
    /// Retrying cannot help: the failure was deterministic (oversized payload, not signed
    /// in, no entitlement), or the engine already ran its own retry wave internally.
    var fatal: Bool = false
    var totalChunks: Int = 1
    var failedChunks: Int = 0
}

/// One way of producing a transcript.
///
/// Engines own their own preparation rather than receiving finished audio: what they need
/// genuinely differs. The Gemini path trims silence, cuts chunks against a 4.5 MB request
/// ceiling and sends video frames; a local Whisper run needs none of that. The expensive,
/// fiddly parts they do share -- extraction, VAD, chunk math, SRT repair -- already live
/// in AudioPreparation, ChunkPlanner and SrtCodec, so sharing happens there rather than
/// through a lowest-common-denominator argument list.
protocol TranscriptionEngine {
    var kind: TranscriptionEngineKind { get }

    /// False when the engine cannot run at all right now -- no account for a cloud engine,
    /// no downloaded model for a local one. The orchestrator uses this to fall back
    /// rather than to fail.
    var isReady: Bool { get }

    /// - Parameter multiSpeaker: ask for every audible speaker rather than only the
    ///   foreground narrator. Ignored by engines that cannot tell them apart.
    func transcribe(videoURL: URL, multiSpeaker: Bool) async -> EngineResult
}

extension TranscriptionEngine {
    func transcribe(videoURL: URL) async -> EngineResult {
        await transcribe(videoURL: videoURL, multiSpeaker: false)
    }
}
