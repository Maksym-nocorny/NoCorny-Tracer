import Foundation
import OSLog

/// Manages application logs and persists them to a file for diagnostics
@Observable
final class LogManager {
    static let shared = LogManager()
    
    private let logger = Logger(subsystem: "com.maksym.NoCornyTracer", category: "App")
    private let logFileURL: URL
    
    var lastLogs: [String] = []
    
    private init() {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDir = appSupport.appendingPathComponent("NoCornyTracer/Logs", isDirectory: true)
        
        try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        self.logFileURL = logDir.appendingPathComponent("app.log")
        
        // Load existing logs
        loadLogs()
        log("🚀 App Started")
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
        
        let logLine = "[\(timestamp)] \(prefix): \(message)"
        
        // Console log
        logger.log(level: type, "\(logLine)")
        
        // Memory log
        DispatchQueue.main.async {
            self.lastLogs.insert(logLine, at: 0)
            if self.lastLogs.count > 500 {
                self.lastLogs.removeLast()
            }
        }
        
        // File log
        appendToFile(logLine)
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
    
    private func loadLogs() {
        if let content = try? String(contentsOf: logFileURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .reversed()
            self.lastLogs = Array(lines.prefix(500))
        }
    }
    
    func clearLogs() {
        try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        lastLogs = []
        log("🧹 Logs Cleared")
    }
    
    func getLogFileURL() -> URL {
        return logFileURL
    }
}
