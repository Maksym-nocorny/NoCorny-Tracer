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
        let data = (line + "\n").data(using: .utf8)!
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logFileURL)
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
    
    private func sanitize(_ message: String) -> String {
        let homeDir = NSHomeDirectory()
        return message.replacingOccurrences(of: homeDir, with: "/Users/[USER]")
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
