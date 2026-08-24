import Foundation

/// Handles uploading recorded videos to Dropbox via REST API (no SDK dependency)
final class DropboxUploadManager {

    enum DropboxError: LocalizedError {
        case invalidToken
        case uploadFailed(String)
        case noData
        case fileError(String)
        /// Dropbox refused because the ACCOUNT is full. Split out from the generic HTTP
        /// case because it is the one upload failure the user can fix themselves, and it
        /// was reaching them as a raw JSON blob - or, worse, not reaching them at all: the
        /// row quietly turned into a small grey icon while the recording sat on this Mac.
        case outOfSpace
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
            case .outOfSpace:
                return "Your Dropbox is full, so the video stayed on this Mac. Free up space in Dropbox (or upgrade it), then tap the recording to retry."
            }
        }
    }

    /// One climbing number across a chunked upload.
    ///
    /// `chunkFraction` is URLSession's counter for the chunk in flight; completed bytes are
    /// what previous chunks already delivered. The last chunk is usually short, so the
    /// in-flight portion is capped at what actually remains - otherwise the bar overshoots
    /// past 1 near the end and snaps back, which reads as the upload breaking.
    static func overallFraction(completedBytes: UInt64, chunkFraction: Double, chunkBytes: UInt64, totalBytes: UInt64) -> Double {
        guard totalBytes > 0 else { return 0 }
        let remaining = totalBytes - min(completedBytes, totalBytes)
        let inFlight = Double(min(chunkBytes, remaining)) * min(max(chunkFraction, 0), 1)
        return min((Double(completedBytes) + inFlight) / Double(totalBytes), 1)
    }

    /// True when a Dropbox error body says the account itself is out of room.
    /// Checked wherever an HTTP error is about to be thrown, because the session path can
    /// hit it on start, append or finish just as the simple path can.
    static func isOutOfSpace(_ body: String) -> Bool {
        body.contains("insufficient_space")
    }

    static func isOutOfSpace(_ body: Data) -> Bool {
        isOutOfSpace(String(data: body, encoding: .utf8) ?? "")
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
    /// - Parameter progress: called with 0...1 as bytes actually leave the machine. On the
    ///   simple path that is URLSession's own byte counter; on the session path, bytes per
    ///   chunk plus the offset of the chunks already sent. Optional because thumbnails and
    ///   transcripts are too small for a bar to mean anything - the video is the upload
    ///   someone sits and watches, and it had no indicator at all.
    func upload(
        fileURL: URL,
        dropboxPath: String,
        mode: UploadMode = .overwrite,
        accessToken: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard !accessToken.isEmpty else {
            throw DropboxError.invalidToken
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0

        if fileSize <= UInt64(simpleUploadLimit) {
            let fileData = try Data(contentsOf: fileURL)
            return try await withRetry(taskName: "Upload") {
                try await self.simpleUpload(data: fileData, path: dropboxPath, mode: mode, accessToken: accessToken, progress: progress)
            }
        } else {
            return try await sessionUpload(fileURL: fileURL, fileSize: fileSize, path: dropboxPath, mode: mode, accessToken: accessToken, progress: progress)
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

    private func simpleUpload(data: Data, path: String, mode: UploadMode, accessToken: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
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

        // upload(for:from:) rather than httpBody + data(for:): only an upload task reports
        // didSendBodyData, which is where the progress a person watches comes from.
        let (responseData, response) = try await URLSession.shared.upload(
            for: request, from: data, delegate: progress.map { UploadProgressDelegate(onFraction: $0) }
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            LogManager.shared.log("Dropbox simpleUpload Error: HTTP \(statusCode) - \(body)", type: .error)
            if Self.isOutOfSpace(responseData) { throw DropboxError.outOfSpace }
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

    private func sessionUpload(fileURL: URL, fileSize: UInt64, path: String, mode: UploadMode, accessToken: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? fileHandle.close() }

        // Per-request progress covers bytes of the chunk in flight; the completed offset is
        // added so a 500 MB file reads as one climbing number, not ten separate 0-to-100s.
        // The helper is pure so the arithmetic can be held by a test.
        func chunkProgress(completed: UInt64) -> (@Sendable (Double) -> Void)? {
            guard let progress else { return nil }
            let total = fileSize
            return { fraction in
                progress(Self.overallFraction(completedBytes: completed, chunkFraction: fraction, chunkBytes: UInt64(self.chunkSize), totalBytes: total))
            }
        }

        // Start session with first chunk
        let firstChunkData = try fileHandle.read(upToCount: chunkSize) ?? Data()
        let sessionID = try await withRetry(taskName: "Session Start") {
            try await self.startUploadSession(data: firstChunkData, accessToken: accessToken, progress: chunkProgress(completed: 0))
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
                        accessToken: accessToken,
                        progress: chunkProgress(completed: offset)
                    )
                }
            } else {
                try await withRetry(taskName: "Session Append") {
                    try await self.appendUploadSession(sessionID: sessionID, offset: Int(offset), data: chunkData, accessToken: accessToken, progress: chunkProgress(completed: offset))
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

    private func startUploadSession(data: Data, accessToken: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload_session/start")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArg: [String: Any] = ["close": false]
        try setDropboxAPIArg(request: &request, arguments: apiArg)
        let (responseData, response) = try await URLSession.shared.upload(
            for: request, from: data, delegate: progress.map { UploadProgressDelegate(onFraction: $0) }
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            if Self.isOutOfSpace(responseData) { throw DropboxError.outOfSpace }
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

    private func appendUploadSession(sessionID: String, offset: Int, data: Data, accessToken: String, progress: (@Sendable (Double) -> Void)? = nil) async throws {
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
        let (responseData, response) = try await URLSession.shared.upload(
            for: request, from: data, delegate: progress.map { UploadProgressDelegate(onFraction: $0) }
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            if Self.isOutOfSpace(responseData) { throw DropboxError.outOfSpace }
            throw DropboxError.httpError(
                status: statusCode,
                retryAfter: Self.retryAfter(from: response, body: responseData),
                body: "Failed to append upload session chunk: \(body)"
            )
        }
    }

    private func finishUploadSession(sessionID: String, offset: Int, data: Data, path: String, mode: UploadMode, accessToken: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
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
        let (responseData, response) = try await URLSession.shared.upload(
            for: request, from: data, delegate: progress.map { UploadProgressDelegate(onFraction: $0) }
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
            if Self.isOutOfSpace(responseData) { throw DropboxError.outOfSpace }
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
    ///
    /// `visibility` is "public" by default because the Tracer web player streams the
    /// file via this shared link (a non-public link wouldn't render for viewers).
    /// Exposed as a parameter so visibility can be tightened in one place once the
    /// web side switches to authenticated streaming — that change must be coordinated
    /// with nocorny-tracer-web first, so this is parameterization only (no behavior
    /// change here).
    func createSharedLink(path: String, accessToken: String, visibility: String = "public") async throws -> String {
        let url = URL(string: "https://api.dropboxapi.com/2/sharing/create_shared_link_with_settings")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "settings": [
                "requested_visibility": visibility,
                "audience": visibility,
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
            if Self.isOutOfSpace(responseData) { throw DropboxError.outOfSpace }
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

    // MARK: - Download

    /// Pulls a file back out of Dropbox and writes it to `destination`.
    ///
    /// Streamed to a temporary file by URLSession rather than buffered as `Data`: the one
    /// caller is speaker separation fetching an hour or more of cached audio, and holding
    /// that in memory to write it straight back out helps nobody.
    func download(path: String, to destination: URL, accessToken: String) async throws {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }

        try await withRetry(taskName: "Download") {
            var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            try self.setDropboxAPIArg(request: &request, arguments: ["path": path])

            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                // The body of a failed download is the error JSON, and it is small; on
                // success it is the file, which is why this only reads it when we already
                // know the request failed.
                let body = (try? Data(contentsOf: tempURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                try? FileManager.default.removeItem(at: tempURL)
                throw DropboxError.httpError(
                    status: statusCode,
                    retryAfter: Self.retryAfter(from: response, body: nil),
                    body: body
                )
            }

            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        }
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
                if Self.isOutOfSpace(data) { throw DropboxError.outOfSpace }
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

/// Forwards URLSession's own byte counter as a 0...1 fraction.
///
/// This is the only layer that knows how many bytes have genuinely left the machine; anything
/// computed above it is a guess dressed as a number.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let onFraction: @Sendable (Double) -> Void

    init(onFraction: @escaping @Sendable (Double) -> Void) {
        self.onFraction = onFraction
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        onFraction(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
