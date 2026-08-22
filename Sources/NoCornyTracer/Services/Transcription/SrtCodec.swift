import Foundation

/// Everything that turns model output into clean, correctly-timed SRT.
///
/// Pulled out of AINamingService because both the cloud engine (which repairs and
/// maps each chunk's cues as they arrive) and the orchestrator (which restores the
/// trimmed timeline at the end) need the same code. Deliberately stateless: nothing
/// here reaches the network, which makes it the one part of the pipeline that is
/// cheap to test against real malformed model output.
enum SrtCodec {

    static func normalizedForDedupe(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Parses an SRT body and returns the largest end-timestamp it contains (in seconds).
    /// Used to detect "sparse" outputs where Gemini transcribed only the first phrase.
    static func lastSrtEndSeconds(_ srt: String) -> Double? {
        // Match every "HH:MM:SS,mmm --> HH:MM:SS,mmm" line and take the max end time.
        // Tolerates ',' or '.' as the millisecond separator (Gemini sometimes confuses them).
        let pattern = #"(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d{1,2}):(\d{2}):(\d{2})[,.](\d{1,3})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsrange = NSRange(srt.startIndex..., in: srt)
        var maxEnd: Double = 0
        var found = false
        re.enumerateMatches(in: srt, range: nsrange) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 9 else { return }
            func g(_ i: Int) -> Int {
                guard let r = Range(m.range(at: i), in: srt), let v = Int(srt[r]) else { return 0 }
                return v
            }
            let h = g(5), mm = g(6), s = g(7), ms = g(8)
            let end = Double(h * 3600 + mm * 60 + s) + Double(ms) / 1000.0
            if end > maxEnd { maxEnd = end }
            found = true
        }
        return found ? maxEnd : nil
    }

    /// Maps SRT timestamps from Gemini's stitched-and-sped-up timeline back onto the
    /// original recording timeline AND always re-formats the SRT so the web's `parseSrt`
    /// gets a clean, multi-segment file (Gemini in JSON-mode sometimes collapses everything
    /// into one giant entry — we split that back into per-sentence chunks here).
    /// Returns nil for empty / NO_SPEECH responses, or when too many entries fall out of bounds.
    static func restoreSrtTimestamps(_ srt: String, mapping: [TimestampMapping], speedupFactor: Double, originalDuration: Double) -> String? {
        let segments = parseAndRepairSrt(srt)
        guard !segments.isEmpty else { return nil }

        let (mapped, outOfBoundsCount) = mapSegments(
            segments, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration
        )

        if outOfBoundsCount > segments.count / 5 {
            LogManager.shared.log("🤖 Trim: ⚠️ \(outOfBoundsCount)/\(segments.count) timestamps out of bounds — discarding SRT", type: .error)
            return nil
        }

        return serializeSrt(mapped)
    }

    /// Parses a raw Gemini SRT payload into segments, applying the whole recovery ladder:
    /// blank-line normalization, regex recovery for unparseable output, inline-timestamp
    /// splitting, and sentence-splitting of over-long entries. Returns [] for empty /
    /// NO_SPEECH / unrecoverable input.
    ///
    /// Split out of `restoreSrtTimestamps` so the chunked path can parse each chunk on its
    /// own before mapping — the repairs are per-response and must run before any merge.
    static func parseAndRepairSrt(_ srt: String) -> [SrtSegment] {
        let trimmed = srt.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "NO_SPEECH" {
            return []
        }

        let stripped = trimmed
            .replacingOccurrences(of: "```srt\n", with: "")
            .replacingOccurrences(of: "```srt", with: "")
            .replacingOccurrences(of: "```\n", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Normalize single-newline-between-entries to the standard blank-line separator.
        // Gemini in JSON-mode sometimes drops the blank line, especially for Cyrillic /
        // non-Latin content, which collapses the entire SRT into one block under standard
        // parsers. Insert the missing blank line before every "number\ntimestamp -->" run.
        let normalized = stripped.replacingOccurrences(
            of: #"(?<!\n)\n(\d+\n\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->)"#,
            with: "\n\n$1",
            options: .regularExpression
        )

        var segments = parseSrt(normalized)

        // Recovery: if the Gemini response wasn't parseable (no real newlines, exotic format),
        // try a regex sweep over the raw text to find timestamp pairs.
        if segments.isEmpty {
            segments = recoverSrtFromInline(stripped)
            if !segments.isEmpty {
                LogManager.shared.log("🤖 SRT: ⚠️ Standard parse failed, recovered \(segments.count) segments via regex fallback")
            }
        }

        guard !segments.isEmpty else {
            LogManager.shared.log("🤖 SRT: ❌ Could not parse any segments from response. First 200 chars: \(stripped.prefix(200))", type: .error)
            return []
        }

        // Recovery #1.5: Gemini occasionally collapses several adjacent cues into one block
        // where the inner timestamps remain inline as plain text inside the cue body
        // (e.g. "первая фраза 00:00:03,375 --> 00:00:05,335 вторая фраза"). The standard
        // parseSrt() preserves that text verbatim, so the timestamps would render in the
        // transcript UI. Split such segments using the embedded timestamps as breakpoints,
        // then strip any leftover patterns as a safety net.
        let splitByInline = splitSegmentsByInlineTimestamps(segments)
        if splitByInline.count != segments.count {
            LogManager.shared.log("🤖 SRT: Split inline-collapsed segment(s): \(segments.count) → \(splitByInline.count)")
        }
        segments = splitByInline.map { sanitizeInlineTimestamps($0) }

        // Recovery #2: if Gemini collapsed everything into a single very long entry, split
        // it into sentence-sized chunks so the player and the description-generator on the
        // web see a properly segmented transcript.
        var splitSegments: [SrtSegment] = []
        for seg in segments {
            let dur = seg.end - seg.start
            if dur > 15 && seg.text.count > 80 {
                splitSegments.append(contentsOf: splitLongSegmentBySentences(seg))
            } else {
                splitSegments.append(seg)
            }
        }
        if splitSegments.count != segments.count {
            LogManager.shared.log("🤖 SRT: Split \(segments.count) → \(splitSegments.count) segments (Gemini gave overly-long entries)")
        }
        return splitSegments
    }

    /// Maps segments from the AI's timeline onto the original recording timeline, returning
    /// the mapped segments plus a count of entries whose timestamps landed out of bounds.
    ///
    /// The caller decides what to do with `outOfBounds` — the single-call path discards the
    /// whole SRT past a threshold, while the chunked path judges each chunk separately so one
    /// bad chunk cannot destroy the others' work.
    static func mapSegments(
        _ segments: [SrtSegment],
        mapping: [TimestampMapping],
        speedupFactor: Double,
        originalDuration: Double
    ) -> (segments: [SrtSegment], outOfBounds: Int) {
        var mapped: [SrtSegment] = []
        var outOfBoundsCount = 0

        for seg in segments {
            let mappedStart = mapTimestamp(seg.start, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration)
            let mappedEnd = mapTimestamp(seg.end, mapping: mapping, speedupFactor: speedupFactor, originalDuration: originalDuration)

            if mappedEnd <= mappedStart { outOfBoundsCount += 1; continue }
            if mappedStart < 0 || mappedEnd > originalDuration + 0.5 { outOfBoundsCount += 1 }

            let clampedStart = max(0, mappedStart)
            let clampedEnd = min(originalDuration, mappedEnd)
            if clampedEnd <= clampedStart { continue }

            mapped.append(SrtSegment(start: clampedStart, end: clampedEnd, text: seg.text))
        }

        return (mapped, outOfBoundsCount)
    }

    /// Renders segments as a standard SRT file, numbering entries from 1. Any index values
    /// from the source are irrelevant — both our parser and the web's ignore them — so the
    /// chunked path can concatenate segments freely and let this assign final numbering.
    ///
    /// A labelled cue gets its speaker as a `[Name] ` prefix on the text line. That shape is a
    /// contract with the web player, which lifts the name out with `/^\[([^\]]{1,40})\]\s+/`
    /// and renders it as a speaker chip: no brackets, no trailing space, name under 40 chars,
    /// or the prefix stops being a name and starts being part of what someone said. Players
    /// that know nothing about speakers still show a valid subtitle, which is why the label
    /// lives in the text rather than in an extension SRT has no room for.
    static func serializeSrt(_ segments: [SrtSegment]) -> String? {
        var lines: [String] = []
        var idx = 1
        for seg in segments {
            lines.append("\(idx)")
            lines.append("\(formatSrtTimestamp(seg.start)) --> \(formatSrtTimestamp(seg.end))")
            if let speaker = seg.speaker {
                lines.append("[\(speaker)] \(seg.text)")
            } else {
                lines.append(seg.text)
            }
            lines.append("")
            idx += 1
        }
        let result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Last-resort recovery: regex-scan the raw text for timestamp pairs and slice text
    /// between them. Used when the response contains no real newlines (`\\n` literals or
    /// an exotic single-line format).
    static func recoverSrtFromInline(_ raw: String) -> [SrtSegment] {
        let pattern = #"(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nstext = raw as NSString
        let matches = regex.matches(in: raw, range: NSRange(location: 0, length: nstext.length))
        guard !matches.isEmpty else { return [] }

        var segments: [SrtSegment] = []
        for (i, m) in matches.enumerated() {
            let start = parseSrtTimestamp(nstext.substring(with: m.range(at: 1)))
            let end = parseSrtTimestamp(nstext.substring(with: m.range(at: 2)))
            // Text lives between the end of this timestamp pair and the start of the next.
            let textStart = m.range.location + m.range.length
            let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nstext.length
            guard textEnd > textStart else { continue }
            var text = nstext.substring(with: NSRange(location: textStart, length: textEnd - textStart))
            // Strip leading numeric index if the next entry starts with one.
            text = text.replacingOccurrences(of: #"^\s*\d+\s*$"#, with: "", options: .regularExpression)
            // Strip the trailing entry-index that belongs to the NEXT cue — but only when
            // there actually IS a next cue, and only a digit run that stands alone after
            // whitespace (or is the entire slice). This preserves meaningful trailing digits
            // like "port 8080" or "error code 500" — especially in the final cue, which has
            // no following index to remove.
            if i + 1 < matches.count {
                text = text.replacingOccurrences(of: #"(?:^|\s)\d{1,4}\s*$"#, with: "", options: .regularExpression)
            }
            text = text
                .replacingOccurrences(of: "\\n", with: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                segments.append(SrtSegment(start: start, end: end, text: text))
            }
        }
        return segments
    }

    /// Inline-timestamp pattern used to detect Gemini's "collapsed cue" failure mode.
    /// Matches `HH:MM:SS,mmm --> HH:MM:SS,mmm` (also tolerates `.` as the ms separator).
    static let inlineTimestampPattern = #"(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}[,.]\d{1,3})"#

    /// Splits any segment whose text body contains inline `HH:MM:SS,mmm --> HH:MM:SS,mmm`
    /// patterns into multiple segments, using the embedded timestamps as breakpoints.
    /// Timestamps stay on the same (stitched/sped-up) timeline that Gemini returned, so
    /// `mapTimestamp()` later translates them back to the original recording timeline along
    /// with every other segment.
    static func splitSegmentsByInlineTimestamps(_ segments: [SrtSegment]) -> [SrtSegment] {
        guard let regex = try? NSRegularExpression(pattern: Self.inlineTimestampPattern, options: []) else {
            return segments
        }
        var result: [SrtSegment] = []
        for seg in segments {
            let nstext = seg.text as NSString
            let matches = regex.matches(in: seg.text, range: NSRange(location: 0, length: nstext.length))
            if matches.isEmpty {
                result.append(seg)
                continue
            }

            // Pre-chunk: text before the first embedded timestamp keeps the segment's start
            // and ends where the first embedded cue begins.
            let firstMatchLoc = matches[0].range.location
            let firstEmbeddedStart = parseSrtTimestamp(nstext.substring(with: matches[0].range(at: 1)))
            if firstMatchLoc > 0 {
                let preText = nstext.substring(with: NSRange(location: 0, length: firstMatchLoc))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preText.isEmpty {
                    let preEnd = max(seg.start, min(seg.end, firstEmbeddedStart))
                    if preEnd > seg.start {
                        result.append(SrtSegment(start: seg.start, end: preEnd, text: preText))
                    }
                }
            }

            // Per-match chunks: text between this match's end and the next match's start
            // (or seg.end for the last match). Use the embedded pair for the chunk's timing.
            for (i, m) in matches.enumerated() {
                let embeddedStart = parseSrtTimestamp(nstext.substring(with: m.range(at: 1)))
                let embeddedEnd = parseSrtTimestamp(nstext.substring(with: m.range(at: 2)))
                let textStart = m.range.location + m.range.length
                let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nstext.length
                guard textEnd > textStart else { continue }
                let text = nstext.substring(with: NSRange(location: textStart, length: textEnd - textStart))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { continue }
                let chunkStart = max(seg.start, min(seg.end, embeddedStart))
                let chunkEnd = max(chunkStart, min(seg.end, embeddedEnd))
                if chunkEnd > chunkStart {
                    result.append(SrtSegment(start: chunkStart, end: chunkEnd, text: text))
                }
            }
        }
        return result
    }

    /// Final safety net: strip any remaining inline `HH:MM:SS,mmm --> HH:MM:SS,mmm` patterns
    /// from cue text. The splitter above handles well-formed inline timestamps, but malformed
    /// values (e.g. impossible end < start) might fall through — this guarantees the UI never
    /// renders a raw timestamp pair.
    static func sanitizeInlineTimestamps(_ seg: SrtSegment) -> SrtSegment {
        let cleaned = seg.text
            .replacingOccurrences(of: Self.inlineTimestampPattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != seg.text else { return seg }
        return SrtSegment(start: seg.start, end: seg.end, text: cleaned)
    }

    /// Splits one long segment into sentence-sized sub-segments, distributing time
    /// proportionally to character count.
    static func splitLongSegmentBySentences(_ seg: SrtSegment) -> [SrtSegment] {
        let pattern = #"[^.!?]+[.!?]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [seg] }
        let nstext = seg.text as NSString
        let matches = regex.matches(in: seg.text, range: NSRange(location: 0, length: nstext.length))
        guard matches.count >= 2 else { return [seg] }

        var sentences: [String] = []
        var totalChars = 0
        for m in matches {
            let s = nstext.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                sentences.append(s)
                totalChars += s.count
            }
        }

        // Capture any residual text after the last terminal-punctuation match — a trailing
        // fragment with no closing "." / "!" / "?" would otherwise be silently dropped (the
        // regex only matches up to the last terminator). Append it so its characters are
        // counted and it gets a proportional time slice.
        if let lastMatch = matches.last {
            let lastMatchEnd = lastMatch.range.location + lastMatch.range.length
            if lastMatchEnd < nstext.length {
                let tail = nstext.substring(from: lastMatchEnd).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    sentences.append(tail)
                    totalChars += tail.count
                }
            }
        }

        guard sentences.count >= 2, totalChars > 0 else { return [seg] }

        let totalDuration = seg.end - seg.start
        var result: [SrtSegment] = []
        var cursor = seg.start
        for (i, s) in sentences.enumerated() {
            let proportion = Double(s.count) / Double(totalChars)
            let dur = totalDuration * proportion
            let isLast = i == sentences.count - 1
            let end = isLast ? seg.end : min(seg.end, cursor + dur)
            result.append(SrtSegment(start: cursor, end: end, text: s))
            cursor = end
        }
        return result
    }

    static func mapTimestamp(_ aiTime: Double, mapping: [TimestampMapping], speedupFactor: Double, originalDuration: Double) -> Double {
        let stitchedTime = aiTime * speedupFactor
        if mapping.isEmpty { return stitchedTime }
        for seg in mapping {
            if stitchedTime >= seg.stitchedStartSeconds && stitchedTime < seg.stitchedEndSeconds {
                return seg.originalStartSeconds + (stitchedTime - seg.stitchedStartSeconds)
            }
        }
        // Out of range → clamp to last segment's original end.
        if let last = mapping.last {
            let lastOriginalEnd = last.originalStartSeconds + (last.stitchedEndSeconds - last.stitchedStartSeconds)
            return min(originalDuration, lastOriginalEnd)
        }
        return stitchedTime
    }

    static func formatSrtTimestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let h = Int(total / 3600)
        let m = Int(total.truncatingRemainder(dividingBy: 3600) / 60)
        let s = Int(total.truncatingRemainder(dividingBy: 60))
        let ms = Int((total - Double(Int(total))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    static func parseSrt(_ srt: String) -> [SrtSegment] {
        let normalized = srt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let blocks = normalized.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var segments: [SrtSegment] = []
        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard lines.count >= 2 else { continue }

            let timeLineIdx = lines[0].contains("-->") ? 0 : 1
            guard timeLineIdx < lines.count else { continue }
            let timeLine = lines[timeLineIdx]

            let pattern = #"([\d:,.]+)\s*-->\s*([\d:,.]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: timeLine, range: NSRange(timeLine.startIndex..., in: timeLine)),
                  let startRange = Range(match.range(at: 1), in: timeLine),
                  let endRange = Range(match.range(at: 2), in: timeLine) else {
                continue
            }

            let start = parseSrtTimestamp(String(timeLine[startRange]))
            let end = parseSrtTimestamp(String(timeLine[endRange]))

            let text = lines.dropFirst(timeLineIdx + 1)
                .joined(separator: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            segments.append(SrtSegment(start: start, end: end, text: text))
        }
        return segments
    }

    static func parseSrtTimestamp(_ ts: String) -> Double {
        let trimmed = ts.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(\d+):(\d+):(\d+)[,.](\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return 0
        }
        func capture(_ idx: Int) -> String {
            guard let r = Range(match.range(at: idx), in: trimmed) else { return "0" }
            return String(trimmed[r])
        }
        let h = Double(capture(1)) ?? 0
        let m = Double(capture(2)) ?? 0
        let s = Double(capture(3)) ?? 0
        var msStr = capture(4)
        while msStr.count < 3 { msStr += "0" }
        msStr = String(msStr.prefix(3))
        let ms = Double(msStr) ?? 0
        return h * 3600 + m * 60 + s + ms / 1000
    }
}
