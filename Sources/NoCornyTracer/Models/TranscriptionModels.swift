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
    /// Who said it, once speaker separation has run. nil is the normal state and means
    /// "unlabelled": diarization is off by default, and a run that fails or overruns its
    /// deadline leaves every cue like this rather than costing us the transcript.
    var speaker: String? = nil
}

/// One speaker-labelled span of audio from on-device diarization.
///
/// `speakerId` is stable for the whole file it was diarized from, so the same voice keeps
/// the same id from the first minute to the last. It is NOT a display label: the numbering
/// the transcript shows is decided later, once we know whether the user occupies Speaker 1.
struct DiarizedSpan: Sendable {
    let speakerId: String
    let startMs: Int64
    let endMs: Int64
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

/// How many people the user says were in a recording, counted as a total including
/// themselves - which is how anyone thinks about it ("it was a call with two of us"),
/// not as a count of the far end.
///
/// The setting picks the default for new recordings; the real answer is usually the one given
/// afterwards, from the Recordings list, once the transcript shows how many people the
/// clustering actually found. That correction is possible because `DiarizationAudioCache` keeps
/// the 16 kHz audio a re-run needs long after the local MP4 is deleted.
enum ExpectedSpeakers: String, CaseIterable, Identifiable, Codable {
    /// Let clustering decide, bounded to a sane range. Right for a screen recording, and
    /// the only honest answer when the count genuinely varies.
    case auto
    case justMe
    case two
    case three
    case four
    case five
    /// Anything larger. Clustering is asked for a range rather than a number, because past
    /// a handful of voices an exact count is a worse guess than no guess.
    case manyMore

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Detect automatically"
        case .justMe: return "Just me"
        case .two: return "2 people"
        case .three: return "3 people"
        case .four: return "4 people"
        case .five: return "5 people"
        case .manyMore: return "6 or more"
        }
    }

    /// Total headcount, when the user named one.
    var totalPeople: Int? {
        switch self {
        case .auto, .manyMore: return nil
        case .justMe: return 1
        case .two: return 2
        case .three: return 3
        case .four: return 4
        case .five: return 5
        }
    }

    /// The constraint handed to clustering, for the audio it will actually see.
    ///
    /// - Parameter userIsOnAnotherTrack: true when system audio was recorded, so the user's
    ///   own voice is on the mic track and the audio being clustered contains only the far
    ///   end. Their headcount then has to lose one before it means anything here.
    func clusterRange(userIsOnAnotherTrack: Bool) -> (min: Int, max: Int) {
        guard let total = totalPeople else {
            return self == .manyMore ? (2, 8) : (1, 3)
        }
        let voices = userIsOnAnotherTrack ? total - 1 : total
        // "Just me" on a two-track recording leaves nothing to separate; asking for zero
        // clusters is meaningless, so ask for one and let the caller find no far-end spans.
        let clamped = max(1, voices)
        return (clamped, clamped)
    }
}

// MARK: Compact menus (redesign, phase 6b)

/// The redesign's compact speaker menus (the drawer's "People in new recordings" row,
/// macro 559:2030, and the Gallery row's context submenu) offer Auto / 2 / 3 / 4 —
/// the everyday answers — instead of the old Settings page's full seven-row list.
/// The full enum still exists and old values still work: a stored choice outside the
/// quick four is spliced into the menu so it can show as selected and be re-picked.
extension ExpectedSpeakers {
    /// What the compact menus offer by default (macro: Auto / 2 / 3 / 4).
    static let quickPickCases: [ExpectedSpeakers] = [.auto, .two, .three, .four]

    /// Short labels for the compact menus, where "People in new recordings" or
    /// "Speakers" already says what the number counts.
    var shortName: String {
        switch self {
        case .auto: return "Auto"
        case .justMe: return "Just me"
        case .two: return "2"
        case .three: return "3"
        case .four: return "4"
        case .five: return "5"
        case .manyMore: return "6+"
        }
    }

    /// The compact offer, guaranteed to contain `current`: a value outside the quick
    /// four (picked in the old UI, or per-recording) is inserted at its natural
    /// position in `allCases` order, so the menu can never show an empty selection.
    static func quickPickChoices(including current: ExpectedSpeakers) -> [ExpectedSpeakers] {
        guard !quickPickCases.contains(current) else { return quickPickCases }
        return allCases.filter { quickPickCases.contains($0) || $0 == current }
    }
}

