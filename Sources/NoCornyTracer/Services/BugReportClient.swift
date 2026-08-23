import Foundation

/// Sends a problem report to tracer.nocorny.com.
///
/// The bearer token is attached when there is one, but a report goes out either way:
/// a broken sign-in is exactly the sort of thing worth reporting, and requiring an
/// account to complain about the account would silence that class of report entirely.
enum BugReportClient {

    enum ReportError: LocalizedError {
        case nothingToSend
        case onlyOlderVersions
        case rateLimited
        case server(Int)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .nothingToSend:
                return "There is nothing in the log to send yet."
            case .onlyOlderVersions:
                return "Everything in the log so far was written by the previous version, and reports only carry entries from the current one. Use the app for a moment and try again."
            case .rateLimited:
                return "You have sent several reports recently. Try again in an hour."
            case .server(let code):
                return "The server could not accept the report (\(code))."
            case .transport(let message):
                return message
            }
        }
    }

    /// What the report carries. Shown to the user before sending, so it stays short
    /// enough to actually read.
    struct Payload: Identifiable {
        let id = UUID()
        let appVersion: String
        let macosVersion: String
        let macModel: String
        let logTail: String

        var logSizeKB: Int { max(1, Data(logTail.utf8).count / 1024) }
    }

    static func makePayload() -> Payload {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return Payload(
            appVersion: "\(short) (\(build))",
            macosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            macModel: machineModel(),
            logTail: BugReportComposer.composeLogTail()
        )
    }

    static func send(_ payload: Payload, token: String?) async throws {
        switch BugReportComposer.availability {
        case .ready: break
        case .noLogYet: throw ReportError.nothingToSend
        case .onlyOlderVersions: throw ReportError.onlyOlderVersions
        }

        var request = URLRequest(url: URL(string: "\(TracerAPIClient.baseURL)/api/bug-reports")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "appVersion": payload.appVersion,
            "macosVersion": payload.macosVersion,
            "macModel": payload.macModel,
            "logTail": payload.logTail,
        ])

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ReportError.transport(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299:
            LogManager.shared.log("🐞 Report: ✅ sent (\(payload.logSizeKB) KB)")
        case 429:
            throw ReportError.rateLimited
        default:
            throw ReportError.server(status)
        }
    }

    private static func machineModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
