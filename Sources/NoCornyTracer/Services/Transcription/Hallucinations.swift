import Foundation

/// Ported from Corder (`Sources/Corder/Transcription/Hallucinations.swift`) with the
/// author's permission. Corder-specific pieces (the destructive launch-time purge and its
/// exact-match-only variant) are not carried over.
///
/// Whisper fills silence with the subtitle boilerplate it was trained on. Left alone those
/// phrases land in the transcript as confident, well-timed cues over stretches where nobody
/// said anything, which is worse than a gap: a reader has no way to tell them from speech.
///
/// The lists below are all things Whisper produced over silence in production, not a
/// theoretical catalogue. Every entry is a distinctive multi-word phrase or an unmistakable
/// watermark, because the filter runs on real meeting speech too and a short generic pattern
/// would eat legitimate cues.
enum Hallucinations {

    /// Phrases that only count when they dominate the cue (see the 60% rule below), so a
    /// real sentence that happens to contain one survives.
    static let patterns: [String] = [
        "субтитры сделал dimatorzok",
        "субтитры подготовил dimatorzok",
        "субтитры создавал dimatorzok",
        "субтитры подобрал dimatorzok",
        "субтитры от dimatorzok",
        "продолжение следует",
        "продолжение в следующем видео",
        "продолжение в следующем выпуске",
        "спасибо за просмотр",
        // "спасибо за внимание" is a real closing line, but in practice it shows up over
        // silence far more often than anyone actually says it, so it stays filtered.
        "спасибо за внимание",
        // Russian YouTube-outro farewells emitted over near-silence. Multi-word so a
        // genuine "до встречи завтра" is untouched.
        "до скорых встреч",
        "до новых встреч",
        "не забудьте подписаться",
        "подписывайтесь на канал",
        "ставьте лайк",
        // English YouTube outros, the same artefact in the other half of the training set.
        "thank you for watching",
        "thanks for watching",
        "thank you for your watching",
        "thank you so much for watching",
        "i hope you enjoyed",
        "i hope you will enjoy",
        "hope you enjoy this video",
        "enjoy watching this video",
        "enjoy this video",
        "have a wonderful day",
        "have a great day",
        "see you in the next video",
        "see you in the next one",
        "see you next time",
        "i will see you in the next video",
        "dont forget to subscribe",
        "please subscribe to my channel",
        "subscribe to my channel",
        "like and subscribe",
        "if you enjoyed this video",
        "see you guys next time",
        "subtitles by",
        "transcribed by",
        "please subscribe",
        "редактор субтитров",
        "субтитри",
        "дякую за перегляд",
        "дякую за увагу",
    ]

    /// Watermarks that are never real speech, so containment alone is enough and the 60%
    /// rule does not apply. "amaraorg" covers the whole Amara.org subtitle-community credit
    /// family in every language Whisper emits it in, because they all normalise down to it.
    /// "dimatorzok" is here as well as in `patterns` because the credit often arrives
    /// clipped to the bare handle, which is too short to dominate a cue.
    static let alwaysDropFragments: [String] = [
        "amaraorg",
        "castingwords",
        "dimatorzok",
    ]

    /// Bare caption words Whisper emits over silence. Unlike the watermarks these are
    /// ordinary vocabulary a speaker can genuinely use, so only a cue made of nothing but
    /// them ("자막: 자막:") is dropped.
    static let captionWords: [String] = ["자막", "字幕"]

    static func isOnlyCaptionWords(_ text: String) -> Bool {
        var t = text.lowercased()
        for w in captionWords { t = t.replacingOccurrences(of: w, with: " ") }
        guard text.lowercased() != t else { return false }
        return !t.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Non-speech captions: music notes, or a cue entirely wrapped in brackets ("[Music]",
    /// "(applause)", "[BLANK_AUDIO]"). Checked on the raw text because normalisation strips
    /// the brackets that identify them.
    static func isNonSpeechCaption(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.allSatisfy({ $0 == "♪" || $0 == "♫" || $0.isWhitespace }) { return true }
        if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) {
            return true
        }
        return false
    }

    static func isHallucination(_ text: String) -> Bool {
        if isNonSpeechCaption(text) { return true }
        if isOnlyCaptionWords(text) { return true }

        let lower = text.lowercased()
        let stripped = lower.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " "
        }
        let normalised = String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !normalised.isEmpty else { return false }

        for frag in alwaysDropFragments where normalised.contains(frag) { return true }

        for pat in patterns where normalised.contains(pat) {
            if normalised == pat { return true }
            // Substring matches only count when the pattern DOMINATES the cue. Dropping a
            // whole cue costs real speech, and a short pattern buried in a long sentence is
            // almost always someone actually saying it.
            if Double(pat.count) >= Double(normalised.count) * 0.6 { return true }
        }
        return false
    }
}
