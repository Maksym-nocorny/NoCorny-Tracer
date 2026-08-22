import Foundation

/// Coarse script and language guesses over transcript text.
///
/// Used in two places for the same reason: catching the failure mode where Ukrainian or
/// Russian narration comes back with an English title, or where one chunk of a long
/// recording drifts into a different language than its neighbours. Deliberately crude --
/// real language identification is not needed to spot either.
enum LanguageDetection {

    /// Returns whichever of {Cyrillic, Latin} dominates the alphabetic characters in `s`.
    /// `mixed` if both are present in roughly equal share, `undetermined` if there are no
    /// alphabetic characters at all.
    static func dominantScript(_ s: String) -> NameScript {
        var latin = 0
        var cyrillic = 0
        for u in s.unicodeScalars {
            let v = u.value
            if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
                latin += 1
            } else if v >= 0x00C0 && v <= 0x024F && u.properties.isAlphabetic {
                latin += 1
            } else if (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F) {
                cyrillic += 1
            }
        }
        let total = latin + cyrillic
        guard total > 0 else { return .undetermined }
        let latinRatio = Double(latin) / Double(total)
        let cyrillicRatio = Double(cyrillic) / Double(total)
        if latinRatio >= 0.85 { return .latin }
        if cyrillicRatio >= 0.85 { return .cyrillic }
        return .mixed
    }

    /// Best-effort dominant-language detection — finer-grained than `dominantScript`.
    /// Within Cyrillic, distinguishes Russian vs Ukrainian by language-specific letter
    /// markers (ї/є/ґ → Ukrainian; ы/э/ъ/ё → Russian); otherwise defaults to Russian
    /// for unmarked Cyrillic. Latin always returns "English" — we don't try to tell
    /// English apart from Spanish/French/etc.
    ///
    /// Returns nil for too-short or unclassifiable input. Used to detect cases like
    /// Russian narration getting a Ukrainian title (both Cyrillic — `dominantScript`
    /// flags them as a match even though the language is wrong).
    static func dominantLanguage(_ s: String) -> String? {
        var latin = 0
        var cyrillic = 0
        var hasUkrainianMarker = false
        var hasRussianMarker = false
        for u in s.unicodeScalars {
            let v = u.value
            if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
                latin += 1
            } else if (v >= 0x0400 && v <= 0x04FF) || (v >= 0x0500 && v <= 0x052F) {
                cyrillic += 1
                // Ukrainian-only letters: і І ї Ї є Є ґ Ґ
                if v == 0x0456 || v == 0x0406 || v == 0x0457 || v == 0x0407
                    || v == 0x0454 || v == 0x0404 || v == 0x0491 || v == 0x0490 {
                    hasUkrainianMarker = true
                }
                // Russian-only letters: ы Ы э Э ъ Ъ ё Ё
                if v == 0x044B || v == 0x042B || v == 0x044D || v == 0x042D
                    || v == 0x044A || v == 0x042A || v == 0x0451 || v == 0x0401 {
                    hasRussianMarker = true
                }
            }
        }
        let total = latin + cyrillic
        guard total >= 5 else { return nil }
        if cyrillic > latin {
            if hasUkrainianMarker && !hasRussianMarker { return "Ukrainian" }
            if hasRussianMarker && !hasUkrainianMarker { return "Russian" }
            if hasUkrainianMarker { return "Ukrainian" }
            // Cyrillic but no language-specific markers — default to Russian
            // (more common globally; safer fallback than mis-tagging as Ukrainian).
            return "Russian"
        }
        return "English"
    }
}
