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
    /// Any header line, ours or not.
    private static let sessionMarkerPrefix = "🚀 NoCorny Tracer"

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
        if case .ready = availability { return true }
        return false
    }

    /// Why a report can or cannot be made right now. "Nothing yet" and "everything in the
    /// log predates this version" are different facts, and telling someone the log is empty
    /// when it is full of an older build's lines is simply untrue.
    enum Availability: Equatable {
        case ready
        case noLogYet
        /// The log exists but holds nothing this build wrote - normal right after updating,
        /// until the app has run long enough to log something of its own.
        case onlyOlderVersions
    }

    static var availability: Availability {
        if readTail(maxLines: maxScanLines).isEmpty { return .noLogYet }
        return readScopedLines().isEmpty ? .onlyOlderVersions : .ready
    }

    /// The report payload: filtered matches with context, always followed by the raw tail.
    static func composeLogTail() -> String {
        let lines = readScopedLines()
        guard !lines.isEmpty else {
            // Two different facts, and saying the wrong one is what the availability work
            // was for. Neither string is ever sent - `send` refuses both - but they show up
            // in logs and in support conversations.
            return availability == .noLogYet
                ? "(log file missing or unreadable)"
                : "(nothing logged by this version yet)"
        }

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
    /// The exact header this build writes, version AND build number. Taken from the one
    /// accessor LogManager uses, so the string being hunted for is by construction the
    /// string being written - the previous version built it separately and, with the app
    /// version left unbumped, matched the leaky release's own headers instead.
    static var currentVersionMarker: String {
        let (version, build) = LogManager.sessionIdentity
        return "\(sessionMarker)\(version) (\(build))"
    }

    /// The window a report covers: the last few launches OF THIS BUILD, and nothing else.
    ///
    /// This is the load-bearing rule, and it replaces trying to sanitize whatever an older
    /// build happened to write. Pattern-matching free-form log text failed three times in
    /// three different ways - a prefix nobody had listed, a model reply spanning several
    /// lines so per-line rules protected only the first, a twelfth naming line the
    /// enumeration missed. Each fix closed one shape and left the class open.
    ///
    /// Scoping inverts that: this build is auditable, so what an older one wrote stops
    /// mattering. Redaction stays as a second line rather than the only one.
    ///
    /// Sessions are filtered individually rather than sliced from the earliest match,
    /// because a foreign session can sit BETWEEN two of ours - a downgrade, a second
    /// install, someone running an old DMG from Downloads once - and a slice takes it whole.
    private static func readScopedLines() -> [String] {
        let lines = readTail(maxLines: maxScanLines)
        guard !lines.isEmpty else { return [] }

        let marker = currentVersionMarker
        var sessions: [[String]] = []
        var current: [String]? = nil

        for line in lines {
            if line.contains(sessionMarker) {
                // A header always starts a session; only ours starts a KEPT one.
                current = line.contains(marker) ? [line] : nil
                if current != nil { sessions.append([line]) }
                continue
            }
            // A foreign session whose header lost its marker - two processes appending at
            // once can clobber a line - would otherwise be appended to ours, because
            // nothing closes the current session. Fail closed: a line that cannot be
            // recognised as a continuation ends the session rather than joining it.
            guard current != nil, !sessions.isEmpty else { continue }
            if line.hasPrefix("[") && line.contains("Z] ") && line.contains(sessionMarkerPrefix) {
                current = nil
                continue
            }
            sessions[sessions.count - 1].append(line)
        }

        // Lines before the first header at all belong to a session whose header has scrolled
        // out of the window. Whose build wrote them is unknowable, so they are not eligible.
        return Array(sessions.suffix(3).joined())
    }

    /// Reads app.log, and prepends app.old.log when rotation has just left the current file
    /// nearly empty -- otherwise a report filed right after a 2 MB rollover contains only
    /// the handful of lines written since.
    /// Injectable so the scope rule can be tested against a log this process did not
    /// write. Reading the developer's real log made three tests pass for the wrong reason:
    /// under `swift test` the bundle version is the test runner's, so the scope matched the
    /// runner's own startup banners and never exercised the rule at all.
    static var logSourceOverride: (current: URL, previous: URL)?

    private static func readTail(maxLines: Int) -> [String] {
        if let override = logSourceOverride {
            let lines = readLines(override.previous) + readLines(override.current)
            return lines.count > maxLines ? Array(lines.suffix(maxLines)) : lines
        }
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
            // Drop continuation lines along with the payload they belong to. A log line
            // starts with an ISO timestamp; anything after a redacted payload that does not
            // is the rest of that payload, and per-line redaction can never see it. This is
            // how a multi-line model reply used to walk out whole while its first line was
            // dutifully cleaned.
            .reduce(into: [String]()) { acc, line in
                let isNewEntry = line.hasPrefix("[") && line.contains("Z] ")
                if !isNewEntry, let last = acc.last, last.contains(payloadMarker) {
                    return
                }
                acc.append(redact(line))
            }
    }

    /// Left in place of a dropped payload, and used to recognise its continuation lines.
    private static let payloadMarker = "[REDACTED]"

    private static let transcriptPreviewPattern = try? NSRegularExpression(
        pattern: "(Raw SRT \\([0-9]+ chars\\) preview:|preview:|First 200 chars:|Could not parse JSON response:|Could not parse any segments from response\\.).*$",
        options: [.caseInsensitive]
    )

    /// Exposed for tests: the report is the last place these lines can be stopped, so the
    /// assertion belongs on this function rather than on something further upstream.
    static func redactForTests(_ line: String) -> String { redact(line) }

    private static func redact(_ line: String) -> String {
        var result = LogManager.shared.sanitize(line)
        if let transcriptPreviewPattern {
            let range = NSRange(result.startIndex..., in: result)
            result = transcriptPreviewPattern.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: payloadMarker
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
