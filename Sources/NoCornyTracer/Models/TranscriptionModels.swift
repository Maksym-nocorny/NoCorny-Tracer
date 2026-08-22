import Foundation

// Shared value types for the transcription pipeline.
//
// These all began as private nested types inside AINamingService. They are here
// because the pipeline is being split into an orchestrator plus pluggable
// transcription engines, and every one of these is traded across that seam:
// SrtSegment alone is touched by the SRT codec, the chunk merge, and naming.
// Nothing here holds behaviour -- only shapes.

/// Result of a naming + subtitles run, including accumulated cost-tracking metadata.
struct NamingResult {
    var srt: String?
    var name: String?
    var usage: GeminiUsage
    var model: String
    var latencyMs: Int
    var attempts: Int
    var success: Bool
    var errorCode: String?
    /// True when retrying the whole run cannot help: the failure was deterministic (oversized
    /// payload, not signed in, bad request), or the chunked path already ran its own internal
    /// retry wave. The caller uses this to skip its outer second pass instead of burning a
    /// full re-run — for an hour-long recording that re-run means re-encoding every chunk.
    var fatal: Bool = false
    /// Chunk accounting for the chunked path (1/0 for the single-call path). Surfaced so a
    /// partial transcript is visible in telemetry rather than silently shipping as complete.
    var totalChunks: Int = 1
    var failedChunks: Int = 0
}

/// Internal (not private) so `planChunks` — a pure, deterministic function that is the
/// single most test-worthy piece of the chunked path — stays reachable from tests.
struct SampleRange {
    var start: Int
    var end: Int
    var length: Int { end - start }
}

struct PlannedChunk {
    let index: Int
    let ranges: [SampleRange]
    var speechSamples: Int { ranges.reduce(0) { $0 + $1.length } }
    var speechSeconds: Double { Double(speechSamples) / 16000.0 }
}

struct AudioChunk {
    let index: Int
    let url: URL
    /// Chunk-LOCAL mapping: `stitchedStart` begins at 0, so `mapSegments` lands cues
    /// directly on the original timeline with no offset arithmetic anywhere.
    let mapping: [TimestampMapping]
    let localDuration: Double
    let speechSeconds: Double
    /// Always 1.0 today. Carried explicitly rather than hardcoded at the merge so that
    /// enabling `enableSpeedUp` later cannot silently desync timestamps — a factor
    /// mismatch produces uniformly compressed, in-bounds cues that no bounds check catches.
    let speedupFactor: Double
}

struct ChunkResult {
    enum Status { case transcribed, noSpeech, failed }
    let index: Int
    var status: Status
    /// Segments already mapped onto the ORIGINAL recording timeline.
    var segments: [SrtSegment] = []
    /// Plain cue text, used for per-chunk language detection.
    var text: String = ""
    var usage = GeminiUsage.zero
    var latencyMs = 0
    var attempts = 0
    var model: String? = nil
    var errorCode: String? = nil
    /// Failure that retrying cannot fix — excluded from the targeted retry wave.
    var fatal = false
}

struct GlossaryResult {
    var terms: [String] = []
    var usage = GeminiUsage.zero
    var latencyMs = 0
    var attempts = 0
    var model: String? = nil
}

struct NamingCallResult {
    var name: String?
    var usage = GeminiUsage.zero
    var latencyMs = 0
    var attempts = 0
    var model: String? = nil
    var errorCode: String? = nil
    var fatal = false
}

struct ImageOnlyResult {
    var name: String?
    var usage: GeminiUsage
    var model: String
    var latencyMs: Int
    var attempts: Int
    var errorCode: String?
}

/// Coarse script classification used to verify the AI title is in the same script as
/// the transcript. We don't need true language identification — script is enough to
/// catch the failure mode we see in production: Russian/Ukrainian narration getting
/// an English title.
enum NameScript: String {
    case cyrillic, latin, mixed, undetermined
}

struct CombinedResponse {
    let srt: String
    let name: String
}

struct SpeechSegment {
    let startSamples: Int
    let endSamples: Int
    var startSeconds: Double { Double(startSamples) / 16000.0 }
    var endSeconds: Double { Double(endSamples) / 16000.0 }
}

struct SpeechAnalysis {
    let totalDuration: Double
    let totalSpeechDuration: Double
    let segments: [SpeechSegment]
    let silenceCoverage: Float
    let shouldSkipTranscription: Bool
}

struct TimestampMapping {
    let stitchedStartSamples: Int
    let stitchedEndSamples: Int
    let originalStartSamples: Int
    var stitchedStartSeconds: Double { Double(stitchedStartSamples) / 16000.0 }
    var stitchedEndSeconds: Double { Double(stitchedEndSamples) / 16000.0 }
    var originalStartSeconds: Double { Double(originalStartSamples) / 16000.0 }
}

struct StitchResult {
    let url: URL
    let mapping: [TimestampMapping]
}

struct FrameBudgetStep {
    let quality: Double
    let maxEdge: Int?
    let keep: Int?
}

struct SrtSegment {
    let start: Double
    let end: Double
    let text: String
}


/// Pipeline-wide switches. They live outside the orchestrator because the chunk
/// planner reads the same trim flag the orchestrator does -- keeping two copies in
/// step by hand is exactly how a trimmed timeline and its restore mapping drift apart.
enum TranscriptionTuning {

    /// Trim long silences before sending audio to Gemini. Phase A — enabled.
    static let enableTrimSilence: Bool = true
    /// Apply 1.25× speedup to trimmed audio. Phase B — disabled until validated on real ukr/rus recordings.
    static let enableSpeedUp: Bool = false
    static let speedUpFactor: Double = 1.25

    /// Budget for the base64-ENCODED inline media (audio + frames) in one Gemini request.
    ///
    /// This was 18 MB, sized against Gemini's ~20 MB inline-data cap — but the request never
    /// reaches Gemini. It goes through our Vercel-hosted proxy, whose serverless request-body
    /// limit is 4.5 MB, enforced at the edge before the handler runs. An 18 MB budget meant
    /// the guard could not fire: a 10-minute recording built a ~6.2 MB body and died with
    /// `413 FUNCTION_PAYLOAD_TOO_LARGE`, six times over, producing no title and no transcript.
    ///
    /// Kept slightly under `GeminiProxyClient.maxRequestBodyBytes` so the prompt and JSON
    /// scaffolding fit alongside the media; that client-side check on the exact serialized
    /// body is the real guard, this one is the pre-emptive budget used to degrade gracefully.
    static let maxInlineMediaBytes = 3_800_000
}
