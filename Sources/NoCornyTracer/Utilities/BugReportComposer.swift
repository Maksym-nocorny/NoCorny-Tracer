import Foundation

/// Builds the log slice that goes into a problem report.
///
/// Derived from Corder's reporter, used with permission. The shape of it encodes two
/// lessons that are not obvious:
///
/// **Scope is the last few launches, not the current one.** People reopen the app before
/// they report, so the run that misbehaved is usually one or two launches back. Scoping to
/// the current session reliably shipped a clean startup tail that explained nothing.
///
/// **Two filters, not one.** Matching on error words alone is useless for a quality bug --
/// a transcript that came back short, a title in the wrong language, a recording that
/// uploaded fine and said nothing. Those throw nothing. So domain-flow lines are kept too.
enum BugReportComposer {

    /// Enough to cover several launches without reading an unbounded file.
    private static let maxScanLines = 12_000
    /// Matches the server's cap; the tail is what matters, so truncation drops the head.
    private static let maxBytes = 200_000
    /// Cheap insurance against a failure mode we have no keyword for yet.
    private static let alwaysKeepTailLines = 200
    private static let contextLines = 3
    private static let sessionMarker = "🚀 NoCorny Tracer v"

    private static let errorPattern = try? NSRegularExpression(
        pattern: "(❌|☠️|ERROR|FAULT|fail(ed|ure)?|error|exception|timeout|denied|invalid|refused|HTTP [45][0-9]{2}|premium_required|payloadTooLarge|413|403|401)",
        options: [.caseInsensitive]
    )

    /// Domain flow. A quality bug leaves a trail here and nowhere else.
    private static let flowPattern = try? NSRegularExpression(
        pattern: "(🤖|📤|🎬|🎛️|🎙️|🔗|Proxy:|Combined:|Chunk|Local:|Engine:|VAD|Upload:|Dropbox|Thumbnail|Sparkle|Tracer:)",
        options: []
    )

    /// True when there is anything at all to send.
    ///
    /// Deliberately not "are there errors". Gating on an error count hid the button exactly
    /// when it was most needed, because the bugs worth reporting are the quiet ones.
    static func hasAnythingToReport() -> Bool {
        !readScopedLines().isEmpty
    }

    /// The report payload: filtered matches with context, always followed by the raw tail.
    static func composeLogTail() -> String {
        let lines = readScopedLines()
        guard !lines.isEmpty else { return "(log file missing or unreadable)" }

        var keep = Set<Int>()
        for (i, line) in lines.enumerated() where matchesFilter(line) {
            for j in max(0, i - contextLines)...min(lines.count - 1, i + contextLines) {
                keep.insert(j)
            }
        }
        for i in max(0, lines.count - alwaysKeepTailLines)..<lines.count {
            keep.insert(i)
        }

        var out: [String] = []
        var lastKept = -1
        for i in keep.sorted() {
            if lastKept >= 0 && i > lastKept + 1 { out.append("…") }
            out.append(lines[i])
            lastKept = i
        }
        return clampToBytes(out.joined(separator: "\n"))
    }

    // MARK: - Internals

    private static func matchesFilter(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        if let errorPattern, errorPattern.firstMatch(in: line, options: [], range: range) != nil {
            return true
        }
        if let flowPattern, flowPattern.firstMatch(in: line, options: [], range: range) != nil {
            return true
        }
        return false
    }

    /// The window the report covers: everything since the third-most-recent session marker.
    /// Falls back to the whole window when there are fewer markers than that, and never to
    /// nothing -- a log with no marker at all is still the best evidence available.
    private static func readScopedLines() -> [String] {
        let lines = readTail(maxLines: maxScanLines)
        guard !lines.isEmpty else { return [] }

        let markers = lines.indices.filter { lines[$0].contains(sessionMarker) }
        guard let start = markers.suffix(3).first else { return lines }
        return Array(lines[start...])
    }

    /// Reads app.log, and prepends app.old.log when rotation has just left the current file
    /// nearly empty -- otherwise a report filed right after a 2 MB rollover contains only
    /// the handful of lines written since.
    private static func readTail(maxLines: Int) -> [String] {
        let current = LogManager.shared.getLogFileURL()
        let previous = current.deletingLastPathComponent().appendingPathComponent("app.old.log")

        var lines = readLines(current)
        if lines.count < maxLines / 4 {
            lines = readLines(previous) + lines
        }
        return lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return content
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            // Redact on the way out, not just on the way in. Write-time sanitizing only
            // protects lines written by a build that has it: anyone upgrading carries a log
            // full of share links and transcript previews written by the previous version,
            // and those are precisely the users most likely to be reporting something.
            .map { redact($0) }
    }

    private static let transcriptPreviewPattern = try? NSRegularExpression(
        pattern: "(Raw SRT \\([0-9]+ chars\\) preview:|preview:|First 200 chars:).*$",
        options: [.caseInsensitive]
    )

    private static func redact(_ line: String) -> String {
        var result = LogManager.shared.sanitize(line)
        if let transcriptPreviewPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = transcriptPreviewPattern.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "[REDACTED]"
            )
        }
        return result
    }

    /// Keeps the END of the log: the failure is at the bottom.
    private static func clampToBytes(_ text: String) -> String {
        var data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        data = data.suffix(maxBytes)
        // Dropping mid-character leaves invalid UTF-8; walk forward to a boundary.
        var kept = String(data: data, encoding: .utf8)
        var offset = 0
        while kept == nil && offset < 4 {
            offset += 1
            kept = String(data: data.dropFirst(offset), encoding: .utf8)
        }
        return "…(truncated to last \(maxBytes / 1000) KB)…\n" + (kept ?? "")
    }
}
