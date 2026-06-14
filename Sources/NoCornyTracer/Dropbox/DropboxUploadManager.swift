import Foundation

/// Handles uploading recorded videos to Dropbox via REST API (no SDK dependency)
final class DropboxUploadManager {

    enum DropboxError: LocalizedError {
        case invalidToken
        case uploadFailed(String)
        case noData
        case fileError(String)
        /// A non-success HTTP response with its status code, optional parsed
        /// `Retry-After` hint (seconds) and response body. Lets `withRetry`
        /// classify retryable vs permanent failures without string-parsing.
        case httpError(status: Int, retryAfter: TimeInterval?, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "Invalid or expired Dropbox access token"
            case .uploadFailed(let msg): return "Upload failed: \(msg)"
            case .noData: return "No data received from server"
            case .fileError(let msg): return "File operation failed: \(msg)"
            case .httpError(let status, _, let body): return "HTTP \(status): \(body)"
            }
        }
    }

    /// Conflict-resolution mode for `files/upload` requests.
    /// - `.add`: refuse if a file already exists (combined with autorename, Dropbox
    ///   appends "(1)" to avoid collisions). Used for legacy flat-root uploads.
    /// - `.overwrite`: replace any existing file at `dropboxPath`. Used for
    ///   slug-keyed uploads where the path itself guarantees uniqueness.
    enum UploadMode {
        case add
        case overwrite

        fileprivate var apiValue: String {
            switch self {
            case .add: return "add"
            case .overwrite: return "overwrite"
            }
        }

        fileprivate var autorename: Bool {
            switch self {
            case .add: return true
            case .overwrite: return false
            }
        }
    }

    /// Files at or below this size use the cheap single-request `files/upload`
    /// path; anything larger streams from disk in chunks via the session path so
    /// we never hold the whole file in memory (and never re-hold it across
    /// retries). Dropbox permits simple upload up to 150MB, but routing large
    /// files through the streaming path bounds memory to roughly `chunkSize`.
    private let simpleUploadLimit = 16 * 1024 * 1024
    /// Chunk size for session uploads (50MB)
    private let chunkSize = 50 * 1024 * 1024

    // MARK: - Upload

    /// Uploads a file to Dropbox at an explicit path. Returns the resulting
    /// Dropbox `path_display` on success (which may differ from the requested
    /// path if `mode == .add` and Dropbox auto-renamed on conflict).
    func upload(
        fileURL: URL,
        dropboxPath: String,
        mode: UploadMode = .overwrite,
        accessToken: String
    ) async throws -> String {
        guard !accessToken.isEmpty else {
            throw DropboxError.invalidToken
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0

        if fileSize <= UInt64(simpleUploadLimit) {
            let fileData = try Data(contentsOf: fileURL)
            return try await withRetry(taskName: "Upload") {
                try await self.simpleUpload(data: fileData, path: dropboxPath, mode: mode, accessToken: accessToken)
            }
        } else {
            return try await sessionUpload(fileURL: fileURL, fileSize: fileSize, path: dropboxPath, mode: mode, accessToken: accessToken)
        }
    }

    /// Uploads in-memory data (e.g. a thumbnail JPEG) to an explicit Dropbox path.
    func uploadData(
        _ data: Data,
        dropboxPath: String,
        mode: UploadMode = .overwrite,
        accessToken: String
    ) async throws -> String {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }
        return try await withRetry(taskName: "Upload Data") {
            try await self.simpleUpload(data: data, path: dropboxPath, mode: mode, accessToken: accessToken)
        }
    }

    /// Convenience wrapper for uploading a UTF-8 text file (e.g. transcript.srt).
    @discardableResult
    func uploadText(
        _ text: String,
        dropboxPath: String,
        accessToken: String
    ) async throws -> String {
        let bytes = Data(text.utf8)
        return try await uploadData(
            bytes,
            dropboxPath: dropboxPath,
            mode: .overwrite,
            accessToken: accessToken
        )
    }

    // MARK: - Simple Upload

    private func simpleUpload(data: Data, path: String, mode: UploadMode, accessToken: String) async throws -> String {
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArg: [String: Any] = [
            "path": path,
            "mode": mode.apiValue,
            "autorename": mode.autorename,
            "mute": false
        ]
        try setDropboxAPIArg(request: &request, arguments: apiArg)
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            LogManager.shared.log("Dropbox simpleUpload Error: HTTP \(statusCode) - \(body)", type: .error)
            throw DropboxError.httpError(
                status: statusCode,
                retryAfter: Self.retryAfter(from: response, body: responseData),
                body: body
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let pathDisplay = json["path_display"] as? String else {
            throw DropboxError.noData
        }

        return pathDisplay
    }

    // MARK: - Session Upload (for files > 150MB)

    private func sessionUpload(fileURL: URL, fileSize: UInt64, path: String, mode: UploadMode, accessToken: String) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        // Start session with first chunk
        let firstChunkData = try fileHandle.read(upToCount: chunkSize) ?? Data()
        let sessionID = try await withRetry(taskName: "Session Start") {
            try await self.startUploadSession(data: firstChunkData, accessToken: accessToken)
        }

        var offset = UInt64(firstChunkData.count)

        while offset < fileSize {
            let remaining = fileSize - offset
            let currentChunkSize = Int(min(UInt64(chunkSize), remaining))
            let isLast = (remaining <= UInt64(chunkSize))

            guard let chunkData = try fileHandle.read(upToCount: currentChunkSize) else {
                throw DropboxError.fileError("Could not read chunk at offset \(offset)")
            }

            if isLast {
                // Finish with last chunk
                return try await withRetry(taskName: "Session Finish") {
                    try await self.finishUploadSession(
                        sessionID: sessionID,
                        offset: Int(offset),
                        data: chunkData,
                        path: path,
                        mode: mode,
                        accessToken: accessToken
                    )
                }
            } else {
                try await withRetry(taskName: "Session Append") {
                    try await self.appendUploadSession(sessionID: sessionID, offset: Int(offset), data: chunkData, accessToken: accessToken)
                }
                offset += UInt64(chunkData.count)
            }
        }

        // If we somehow didn't finish (shouldn't happen with total flow above)
        return try await withRetry(taskName: "Session Finish Fallback") {
            try await self.finishUploadSession(
                sessionID: sessionID,
                offset: Int(offset),
                data: Data(),
                path: path,
                mode: mode,
                accessToken: accessToken
            )
        }
    }

    private func startUploadSession(data: Data, accessToken: String) async throws -> String {
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload_session/start")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArg: [String: Any] = ["close": false]
        try setDropboxAPIArg(request: &request, arguments: apiArg)
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw DropboxError.httpError(
                status: statusCode,
                retryAfter: Self.retryAfter(from: response, body: responseData),
                body: "Failed to start upload session: \(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let sessionID = json["session_id"] as? String else {
            throw DropboxError.noData
        }

        return sessionID
    }

    private func appendUploadSession(sessionID: String, offset: Int, data: Data, accessToken: String) async throws {
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload_session/append_v2")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArg: [String: Any] = [
            "cursor": [
                "session_id": sessionID,
                "offset": offset
            ],
            "close": false
        ]
        try setDropboxAPIArg(request: &request, arguments: apiArg)
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw DropboxError.httpError(
                status: statusCode,
                retryAfter: Self.retryAfter(from: response, body: responseData),
                body: "Failed to append upload session chunk: \(body)"
            )
        }
    }

    private func finishUploadSession(sessionID: String, offset: Int, data: Data, path: String, mode: UploadMode, accessToken: String) async throws -> String {
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload_session/finish")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArg: [String: Any] = [
            "cursor": [
                "session_id": sessionID,
                "offset": offset
            ],
            "commit": [
                "path": path,
                "mode": mode.apiValue,
                "autorename": mode.autorename,
                "mute": false
            ]
        ]
        try setDropboxAPIArg(request: &request, arguments: apiArg)
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw DropboxError.httpError(
                status: statusCode,
                retryAfter: Self.retryAfter(from: response, body: responseData),
                body: "Failed to finish upload session: \(body)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let pathDisplay = json["path_display"] as? String else {
            throw DropboxError.noData
        }

        return pathDisplay
    }

    // MARK: - Retry Logic

    /// Upper bound on any single inter-attempt wait, including a server-supplied
    /// `Retry-After`, so a buggy/hostile huge value can't stall the upload Task.
    private static let maxRetryDelay: TimeInterval = 60
    /// Base backoff (seconds) for retryable failures with no `Retry-After`.
    private static let baseRetryDelay: TimeInterval = 1

    private func withRetry<T>(taskName: String = "Operation", attempts: Int = 3, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                LogManager.shared.log(error: error, message: "⚠️ \(taskName) Attempt \(attempt) failed")

                // Classify: permanent 4xx (except 408 timeout / 429 rate-limit)
                // are not retryable — fail fast instead of sleeping and retrying.
                if case let DropboxError.httpError(status, _, _) = error,
                   (400...499).contains(status), status != 408, status != 429 {
                    throw error
                }

                if attempt < attempts {
                    let seconds = Self.retryDelaySeconds(for: error, attempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
            }
        }
        throw lastError ?? DropboxError.uploadFailed("\(taskName) failed after \(attempts) attempts")
    }

    /// Computes how long to wait before the next attempt: honor a server
    /// `Retry-After` (e.g. on 429) capped at `maxRetryDelay`, otherwise use
    /// exponential backoff so successive transient failures don't hammer the
    /// server.
    private static func retryDelaySeconds(for error: Error, attempt: Int) -> TimeInterval {
        let backoff = baseRetryDelay * pow(2, Double(attempt - 1))
        if case let DropboxError.httpError(_, retryAfter, _) = error, let retryAfter {
            return min(max(retryAfter, backoff), maxRetryDelay)
        }
        return min(backoff, maxRetryDelay)
    }

    /// Parses a `Retry-After` hint (in seconds) from an HTTP response header or
    /// a Dropbox JSON `retry_after` field. Returns nil if absent/unparseable.
    private static func retryAfter(from response: URLResponse?, body: Data?) -> TimeInterval? {
        if let http = response as? HTTPURLResponse,
           let header = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return seconds
        }
        // Dropbox sometimes returns { "error": { "retry_after": N } } on 429.
        if let body,
           let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let errorObj = json["error"] as? [String: Any],
               let seconds = errorObj["retry_after"] as? Double {
                return seconds
            }
            if let seconds = json["retry_after"] as? Double {
                return seconds
            }
        }
        return nil
    }

    // MARK: - Shared Links

    /// Creates a shared link for a file. Returns the shared URL string.
    func createSharedLink(path: String, accessToken: String) async throws -> String {
        let url = URL(string: "https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "settings": [
                "requested_visibility": "public",
                "audience": "public",
                "access": "viewer"
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        return try await withRetry(taskName: "Shared Link") {
            let (responseData, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode),
               let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let sharedURL = json["url"] as? String {
                return sharedURL
            }

            // If shared link already exists, try to get it
            if let responseStr = String(data: responseData, encoding: .utf8),
               responseStr.contains("shared_link_already_exists") {
                return try await self.getExistingSharedLink(path: path, accessToken: accessToken)
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyStr = String(data: responseData, encoding: .utf8) ?? ""
            throw DropboxError.httpError(
                status: statusCode,
                retryAfter: Self.retryAfter(from: response, body: responseData),
                body: "Failed to create shared link: \(bodyStr)"
            )
        }
    }

    /// Gets existing shared links for a path
    private func getExistingSharedLink(path: String, accessToken: String) async throws -> String {
        let url = URL(string: "https://api.dropboxapi.com/2/sharing/list_shared_links")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "direct_only": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let links = json["links"] as? [[String: Any]],
              let firstLink = links.first,
              let sharedURL = firstLink["url"] as? String else {
            throw DropboxError.uploadFailed("Failed to get existing shared link")
        }

        return sharedURL
    }

    // MARK: - Rename File

    /// Rename a file on Dropbox by moving it. Returns the new path.
    func renameFile(fromPath: String, toNewName: String, accessToken: String) async throws -> String {
        let url = URL(string: "https://api.dropboxapi.com/2/files/move_v2")!

        // Keep the same directory, just change the filename
        let directory = (fromPath as NSString).deletingLastPathComponent
        let toPath = (directory as NSString).appendingPathComponent(toNewName)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "from_path": fromPath,
            "to_path": toPath,
            "autorename": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let metadata = json["metadata"] as? [String: Any],
              let newPath = metadata["path_display"] as? String else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DropboxError.uploadFailed("Rename failed: HTTP \(statusCode)")
        }

        return newPath
    }

    /// Fetches a thumbnail for a file
    func getThumbnail(path: String, accessToken: String) async throws -> Data {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }
        let url = URL(string: "https://content.dropboxapi.com/2/files/get_thumbnail_v2")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let arg: [String: Any] = [
            "resource": [".tag": "path", "path": path],
            "format": "jpeg",
            "size": "w128h128",
            "mode": "bestfit"
        ]
        try setDropboxAPIArg(request: &request, arguments: arg)
        
        return try await withRetry(taskName: "Thumbnail") {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let body = String(data: data, encoding: .utf8) ?? ""
                throw DropboxError.httpError(
                    status: statusCode,
                    retryAfter: Self.retryAfter(from: response, body: data),
                    body: body
                )
            }
            return data
        }
    }

    private func setDropboxAPIArg(request: inout URLRequest, arguments: [String: Any]) throws {
        let argData = try JSONSerialization.data(withJSONObject: arguments)
        guard let argString = String(data: argData, encoding: .utf8) else {
            throw DropboxError.uploadFailed("Failed to encode arguments")
        }
        
        // Escape non-ASCII characters to ensure ASCII-safe headers.
        // Dropbox-API-Arg must be either pure ASCII or URL-encoded.
        // Unicode escaping (\uXXXX) is valid JSON and effectively makes it ASCII.
        let escaped = argString.unicodeScalars.map {
            if $0.isASCII { return String($0) }
            return String(format: "\\u%04x", $0.value)
        }.joined()
        
        request.setValue(escaped, forHTTPHeaderField: "Dropbox-API-Arg")
    }
}
