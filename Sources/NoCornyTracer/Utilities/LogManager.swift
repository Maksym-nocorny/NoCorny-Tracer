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
    
    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = appSupport.appendingPathComponent("NoCornyTracer/Logs", isDirectory: true)
        
        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        self.logFileURL = logDir.appendingPathComponent("app.log")
        
        rotateLogsIfNeeded()
        loadLogs()
        logSystemHeader()
    }
    
    private func logSystemHeader() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
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
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] 📝: 🚀 NoCorny Tracer v\(version) (\(build)) Started (log rotated)\n"
        if let data = line.data(using: .utf8) {
            try? data.write(to: logFileURL, options: .atomic)
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
    private static let quotedTitleRegex = try? NSRegularExpression(
        pattern: "\\b(title|names?|named)\\b\\s*[:=]?\\s*\"[^\"]*\"",
        options: [.caseInsensitive])

    /// Internal rather than private so it can be tested directly. Going through `log()`
    /// does not work: the in-memory buffer is filled on the main queue, so a test reading
    /// it back immediately sees nothing and every "does not contain" assertion passes for
    /// the wrong reason.
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
        if let regex = Self.quotedTitleRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1: \"[TITLE]\"")
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
