import Foundation

/// Small helpers shared by everything that talks to the model: backoff timing, pulling a
/// single field out of a JSON reply, and the glossary preamble that both the
/// transcription and naming prompts carry.
enum TranscriptionSupport {

    /// Exponential backoff with jitter. Concurrent chunks that all catch a Gemini 503 would
    /// otherwise retry in lockstep and hit it again at exactly the same instant.
    static func jitteredDelayNanos(_ seconds: Double) -> UInt64 {
        UInt64(max(0.1, seconds * Double.random(in: 0.75...1.25)) * 1_000_000_000)
    }

    /// Strips markdown fences and pulls one string field out of a JSON response.
    static func parseJSONStringField(_ raw: String, field: String) -> String? {
        let stripped = raw
            .replacingOccurrences(of: "```json\n", with: "")
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```\n", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stripped.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[field] as? String else { return nil }
        return value
    }

    /// Renders the shared spelling-reference block injected into chunk and naming prompts.
    ///
    /// The last two sentences are load-bearing guards, not politeness: without "never insert",
    /// a glossary term can be force-matched onto acoustically similar speech; without the
    /// language disclaimer, a Latin-heavy term list biases Gemini into transcribing Cyrillic
    /// narration as English — the exact failure the web's description prompt already hit.
    static func glossaryBlock(_ terms: [String]) -> String {
        guard !terms.isEmpty else { return "" }
        return """


        SPELLING REFERENCE — names visible on screen in this recording: \(terms.joined(separator: ", ")).
        If the speaker SAYS one of these names, spell it exactly as listed (keep Latin spellings even inside Cyrillic sentences).
        NEVER insert a listed word that is not actually spoken; transcribe unclear speech as heard.
        This list does NOT indicate the audio language — use the language actually spoken.
        """
    }
}
