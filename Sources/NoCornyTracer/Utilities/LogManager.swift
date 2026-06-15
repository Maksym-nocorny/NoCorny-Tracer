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
        }
    }
    
    private func rotateLogsIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
              let size = attributes[.size] as? Int64,
              size > maxLogSize else { return }
        
        let oldLogURL = logFileURL.deletingLastPathComponent().appendingPathComponent("app.old.log")
        try? FileManager.default.removeItem(at: oldLogURL)
        try? FileManager.default.moveItem(at: logFileURL, to: oldLogURL)
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

    private func sanitize(_ message: String) -> String {
        var result = message.replacingOccurrences(of: NSHomeDirectory(), with: "/Users/[USER]")
        // Redact email addresses so user PII never lands in the plaintext diagnostic
        // log (e.g. "Signed in as alice@example.com").
        if let regex = Self.emailRegex {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[EMAIL]")
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
