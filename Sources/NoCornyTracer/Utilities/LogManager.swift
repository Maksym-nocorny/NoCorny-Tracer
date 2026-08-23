import Foundation
import OSLog

/// Manages application logs and persists them to a file for diagnostics
@Observable
final class LogManager {
    static let shared = LogManager()
    
    private let logger = Logger(subsystem: "com.nocorny.tracer", category: "App")
    private let logFileURL: URL
    private let maxLogSize: Int64 = 2 * 1024 * 1024 // 2MB
    private let logQueue = DispatchQueue(label: "com.nocorny.tracer.logging", qos: .background)
    /// Minimum interval between rotation checks on the write path (avoids a stat per line).
    private let rotationCheckInterval: TimeInterval = 60
    /// Timestamp of the last rotation check. Only read/written on `logQueue`.
    private var lastRotationCheck = Date.distantPast

    var lastLogs: [String] = []
    
    /// True while running under XCTest.
    ///
    /// The suite writes here the same way the app does - simply constructing this singleton
    /// appends a session header - and it had put 477 of them into the developer's real
    /// diagnostic log in one afternoon, a megabyte of noise in the file bug reports are cut
    /// from. It also made the suite four times slower, because the tests that read that log
    /// were reading everything the suite itself had written to it.
    /// Detected by the presence of the XCTest class, not by an environment variable: under
    /// SwiftPM's `swift test` the usual `XCTestConfigurationFilePath` is simply not set - the
    /// only thing in the environment is `SWIFT_TESTING_ENABLED` - which I found out by
    /// shipping a check that silently never fired. XCTest is never linked into the app.
    static let isRunningUnderTests = NSClassFromString("XCTest") != nil

    /// Where the SHIPPED app keeps its log, whatever this process is writing to.
    ///
    /// The privacy tests exist to answer "what would leave a real user's Mac", so they have
    /// to read the real file even when the process they run in has been redirected away from
    /// it. Reading `getLogFileURL()` instead made them read the test's own scratch log -
    /// clean by construction - and quietly skip.
    static var productionLogFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoCornyTracer/Logs/app.log")
    }

    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = appSupport.appendingPathComponent("NoCornyTracer/Logs", isDirectory: true)
        
        // Tests write to a throwaway file. They still READ the real log where they mean to -
        // proving no credential or speech survives into a report is worth doing against real
        // data - but nothing they write ends up in it.
        if Self.isRunningUnderTests {
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("NoCornyTracerTestLogs", isDirectory: true)
            try? fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            self.logFileURL = scratch.appendingPathComponent("app.log")
        } else {
            // Only here: creating it above the branch left a test run planting an empty
            // NoCornyTracer directory tree on machines that never ran the app.
            try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
            self.logFileURL = logDir.appendingPathComponent("app.log")
        }
        
        rotateLogsIfNeeded()
        // A rotation during startup is followed by the real header a moment later, so it
        // must not also trigger the mid-session reheader and its append.
        didRotateMidSession = false
        loadLogs()
        logSystemHeader()
    }
    
    /// The exact identity written into every session header, and the string the report
    /// scope matches on. One accessor, because two spellings of the same lookup is how the
    /// scope ends up hunting for a version that is never written.
    static var sessionIdentity: (version: String, build: String) {
        let d = Bundle.main.infoDictionary
        return (d?["CFBundleShortVersionString"] as? String ?? "unknown",
                d?["CFBundleVersion"] as? String ?? "unknown")
    }

    private func logSystemHeader() {
        let version = Self.sessionIdentity.version
        let build = Self.sessionIdentity.build
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let model = getMachineModel()
        
        let header = """
        ========================================
        🚀 NoCorny Tracer v\(version) (\(build)) Started
        📅 Date: \(Date().description)
        💻 OS: \(osVersion)
        🛠 Model: \(model)
        ========================================
        """
        log(header)
    }
    
    func log(_ message: String, type: OSLogType = .default) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let prefix: String
        switch type {
        case .error: prefix = "❌ ERROR"
        case .fault: prefix = "☠️ FAULT"
        case .debug: prefix = "🔍 DEBUG"
        case .info: prefix = "ℹ️ INFO"
        default: prefix = "📝"
        }
        
        let sanitizedMessage = sanitize(message)
        let logLine = "[\(timestamp)] \(prefix): \(sanitizedMessage)"
        
        // Console log (synchronous for immediate debugging)
        logger.log(level: type, "\(logLine)")
        
        // UI log (main thread)
        DispatchQueue.main.async {
            self.lastLogs.insert(logLine, at: 0)
            if self.lastLogs.count > 500 {
                self.lastLogs.removeLast()
            }
        }
        
        // File log (background thread for performance and thread-safety)
        logQueue.async {
            self.appendToFile(logLine)
        }
    }
    
    /// High-level error logging with context
    func log(error: Error, message: String) {
        let details = """
        \(message)
        Details: \(error.localizedDescription)
        Domain: \((error as NSError).domain)
        Code: \((error as NSError).code)
        """
        log(details, type: .error)
    }
    
    private func appendToFile(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            do {
                let fileHandle = try FileHandle(forWritingTo: logFileURL)
                defer { try? fileHandle.close() }
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
            } catch {
                // Never recurse back into self.log() — write directly to the OSLog
                // sink so a persistently failing disk (e.g. disk-full) cannot crash
                // or infinite-loop the logger.
                logger.error("LogManager appendToFile failed: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            try? data.write(to: logFileURL)
        }

        // Periodically rotate from the serial write path so an always-running
        // menu bar app's log can't grow unbounded between launches. Throttled so
        // we don't stat the file on every line.
        let now = Date()
        if now.timeIntervalSince(lastRotationCheck) >= rotationCheckInterval {
            lastRotationCheck = now
            rotateLogsIfNeeded()
            reheaderAfterRotationIfNeeded()
        }
    }
    
    private func rotateLogsIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? Int64,
              size > maxLogSize else { return }
        
        let oldLogURL = logFileURL.deletingLastPathComponent().appendingPathComponent("app.old.log")
        try? FileManager.default.removeItem(at: oldLogURL)
        try? FileManager.default.moveItem(at: logFileURL, to: oldLogURL)
        didRotateMidSession = true
    }

    /// Set when rotation happened after startup rather than before it. A bug report scopes
    /// itself by counting session headers backwards, and a mid-session rotation leaves the
    /// fresh file with none -- the run that is actually being reported would look like it
    /// had never started.
    private var didRotateMidSession = false

    /// Re-emits the startup header if rotation just cut the current session in half.
    /// Called from the file-append path, so it happens on the log queue.
    private func reheaderAfterRotationIfNeeded() {
        guard didRotateMidSession else { return }
        didRotateMidSession = false
        let (version, build) = Self.sessionIdentity
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] 📝: 🚀 NoCorny Tracer v\(version) (\(build)) Started (log rotated)\n"
        // Append, never write: an atomic write here truncated the file, so on any launch
        // that rotated at startup the log was reduced to this single line - destroying the
        // session header, which the report scope depends on, on exactly the launches where
        // the log had grown big enough to matter.
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logFileURL, options: .atomic)
            }
        }
    }
    
    private func loadLogs() {
        if let content = try? String(contentsOf: logFileURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .reversed()
            self.lastLogs = Array(lines.prefix(500))
        }
    }
    
    private static let emailRegex = try? NSRegularExpression(
        pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", options: [])

    /// A Dropbox share link is not a reference to the recording, it IS access to it --
    /// the `rlkey` query parameter is the credential. Same for a /v/{slug} page. Callers
    /// are expected not to log these, but the log is now something users send us, so the
    /// sink redacts them too rather than trusting every future call site.
    private static let capabilityURLRegex = try? NSRegularExpression(
        pattern: "https?://[^\\s]*(dropbox\\.com|dropboxusercontent\\.com|tracer\\.nocorny\\.com)[^\\s]*",
        options: [.caseInsensitive])

    /// The slug is the credential, not a reference: the public page renders for anyone
    /// holding it, so pasting one after the domain is a working link to somebody's meeting.
    /// Redacting only full URLs left it in plain sight everywhere the pipeline mentions a
    /// recording without a host in front of it: the reservation, the Dropbox folder, the
    /// API path.
    private static let recordingSlugRegex = try? NSRegularExpression(
        pattern: "(slug[=/]|/api/videos/|/videos/|/v/)[A-Za-z0-9_-]{7,}",
        options: [.caseInsensitive])

    /// Two log lines shipped before this naming a recording by a bare slug, with no marker
    /// in front for the rule above to key off. Those logs are on a user's disk right now and
    /// a bug report reads them, so the exact phrasings that shipped are matched by name.
    /// Call sites write `slug=` today, which is why nothing new has to be added here.
    private static let legacySlugPhraseRegex = try? NSRegularExpression(
        pattern: "(Tracer: deleted |Tracer: delete |re-labelled )[A-Za-z0-9_-]{7,}",
        options: [])

    /// A generated title is a summary of what was said, which is most of what a transcript
    /// would have given away: "Layoff plan review with Sarah" needs no transcript to be a
    /// leak. Call sites log a length now; this covers logs written by an older build, and
    /// any future call site that forgets.
    /// Titles, matched by the line they sit on, with one carve-out.
    ///
    /// Matching by label alone missed five shapes the shipped build writes, because half of
    /// them have no label at all - `accepting "…"`, `holding "…"`, `best earlier result
    /// "…"`, `name "…"` with no colon, and the image-only path's bare `✅ "…"`. Matching
    /// every quoted run on a naming line caught those but destroyed the error payloads that
    /// make a report worth reading: `blocked(reason: "SAFETY")` became `"[TITLE]"`, which is
    /// the difference between diagnosing a refusal and guessing at one.
    ///
    /// So: on a naming line every quoted run goes, UNLESS the line is reporting an error,
    /// where the quoted runs are the diagnosis rather than the content. This build logs no
    /// titles at all and a report carries only this build's lines, so both of those are the
    /// real defence; this is the net under them.
    private static let namingContextRegex = try? NSRegularExpression(
        pattern: "(🤖\\s*(Combined|Chunked|Naming|AI Naming)|Final PATCH)", options: [])

    /// Proper nouns lifted off the recording's own frames - names of people and companies.
    /// Nothing else in either sanitizer matches this line.
    private static let glossaryTermsRegex = try? NSRegularExpression(
        pattern: "(Glossary: [0-9]+ terms)\\s*[—-].*$", options: [])

    /// The one title the shipped build logs without quotes around it.
    private static let bareTitleRegex = try? NSRegularExpression(
        pattern: "(Retrying previous upload for )\\S.*$", options: [])

    /// Internal rather than private so it can be tested directly. Going through `log()`
    /// does not work: the in-memory buffer is filled on the main queue, so a test reading
    /// it back immediately sees nothing and every "does not contain" assertion passes for
    /// the wrong reason.

    /// On a naming line, redact every quoted run EXCEPT the ones that are arguments of a
    ///an error value - `blocked(reason: "SAFETY")`, `serverError(status: 400, body: "…")`.
    ///
    /// The distinction is structural, not lexical. An earlier attempt exempted whole lines
    /// that contained words like "failed" or "error", and that was the same list-of-words
    /// mistake a third time: every shipped naming-FAILURE line contains "failed" AND a
    /// title, so the exemption handed back exactly the lines it was meant to clean. A title
    /// can also simply contain the word - "Error handling walkthrough" named itself out of
    /// redaction.
    ///
    /// What actually separates them is position: a payload sits inside parentheses behind a
    /// label, and a title does not.
    static func redactingQuotedTitles(in line: String) -> String {
        var out = ""
        var rest = Substring(line)
        var depth = 0

        while let quoteIdx = rest.firstIndex(of: "\"") {
            let before = rest[rest.startIndex..<quoteIdx]
            depth += before.filter { $0 == "(" }.count - before.filter { $0 == ")" }.count
            out += before

            // Skip escaped quotes. A JSON body inside an error argument is full of them,
            // and pairing on the first bare quote mis-splits the string - which both
            // corrupts the diagnostic and leaves parts of it exposed.
            var scan = rest.index(after: quoteIdx)
            var closeIdx: Substring.Index? = nil
            while scan < rest.endIndex {
                if rest[scan] == "\\" {
                    scan = rest.index(scan, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
                    continue
                }
                if rest[scan] == "\"" { closeIdx = scan; break }
                scan = rest.index(after: scan)
            }
            guard let closeIdx else {
                out += rest[quoteIdx...]
                return out
            }
            let run = rest[quoteIdx...closeIdx]

            // A labelled argument inside an open paren is a diagnosis, not content.
            let trimmed = before.reversed().drop { $0 == " " }
            let isLabelledArgument = depth > 0 && trimmed.first == ":"
            out += isLabelledArgument ? String(run) : "\"[TITLE]\""
            rest = rest[rest.index(after: closeIdx)...]
        }
        return out + rest
    }

    func sanitize(_ message: String) -> String {
        var result = message.replacingOccurrences(of: NSHomeDirectory(), with: "/Users/[USER]")
        // Redact email addresses so user PII never lands in the plaintext diagnostic
        // log (e.g. "Signed in as alice@example.com").
        if let regex = Self.emailRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[EMAIL]")
        }
        if let regex = Self.capabilityURLRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[LINK]")
        }
        for regex in [Self.recordingSlugRegex, Self.legacySlugPhraseRegex].compactMap({ $0 }) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1[SLUG]")
        }
        if let naming = Self.namingContextRegex,
           naming.firstMatch(in: result, options: [], range: NSRange(result.startIndex..., in: result)) != nil {
            result = Self.redactingQuotedTitles(in: result)
        }
        if let regex = Self.glossaryTermsRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1")
        }
        if let regex = Self.bareTitleRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1[TITLE]")
        }
        return result
    }
    
    private func getMachineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
    
    func clearLogs() {
        logQueue.async {
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.lastLogs = []
                self.log("🧹 Logs Cleared")
            }
        }
    }
    
    func getLogFileURL() -> URL {
        return logFileURL
    }
}
