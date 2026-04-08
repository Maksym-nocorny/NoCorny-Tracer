import Foundation

/// Handles uploading recorded videos to Dropbox via REST API (no SDK dependency)
final class DropboxUploadManager {

    enum DropboxError: LocalizedError {
        case invalidToken
        case uploadFailed(String)
        case noData
        case fileError(String)

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "Invalid or expired Dropbox access token"
            case .uploadFailed(let msg): return "Upload failed: \(msg)"
            case .noData: return "No data received from server"
            case .fileError(let msg): return "File operation failed: \(msg)"
            }
        }
    }

    /// Maximum file size for simple upload (150MB)
    private let simpleUploadLimit = 150 * 1024 * 1024
    /// Chunk size for session uploads (50MB)
    private let chunkSize = 50 * 1024 * 1024

    // MARK: - Upload

    /// Uploads a file to Dropbox. Returns the Dropbox path on success.
    func upload(fileURL: URL, fileName: String, accessToken: String) async throws -> String {
        guard !accessToken.isEmpty else {
            throw DropboxError.invalidToken
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let fileSize = attributes[.size] as? UInt64 ?? 0
        let dropboxPath = "/\(fileName)"

        if fileSize <= UInt64(simpleUploadLimit) {
            let fileData = try Data(contentsOf: fileURL)
            return try await withRetry(taskName: "Upload") {
                try await self.simpleUpload(data: fileData, path: dropboxPath, accessToken: accessToken)
            }
        } else {
            return try await sessionUpload(fileURL: fileURL, fileSize: fileSize, path: dropboxPath, accessToken: accessToken)
        }
    }

    // MARK: - Simple Upload

    private func simpleUpload(data: Data, path: String, accessToken: String) async throws -> String {
        let url = URL(string: "https://content.dropboxapi.com/2/files/upload")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let apiArg: [String: Any] = [
            "path": path,
            "mode": "add",
            "autorename": true,
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
            throw DropboxError.uploadFailed("HTTP \(statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let pathDisplay = json["path_display"] as? String else {
            throw DropboxError.noData
        }

        return pathDisplay
    }

    // MARK: - Session Upload (for files > 150MB)

    private func sessionUpload(fileURL: URL, fileSize: UInt64, path: String, accessToken: String) async throws -> String {
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
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let sessionID = json["session_id"] as? String else {
            throw DropboxError.uploadFailed("Failed to start upload session")
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

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DropboxError.uploadFailed("Failed to append upload session chunk")
        }
    }

    private func finishUploadSession(sessionID: String, offset: Int, data: Data, path: String, accessToken: String) async throws -> String {
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
                "mode": "add",
                "autorename": true,
                "mute": false
            ]
        ]
        try setDropboxAPIArg(request: &request, arguments: apiArg)
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let pathDisplay = json["path_display"] as? String else {
            throw DropboxError.uploadFailed("Failed to finish upload session")
        }

        return pathDisplay
    }

    // MARK: - Retry Logic

    private func withRetry<T>(taskName: String = "Operation", attempts: Int = 3, delay: UInt64 = 1_000_000_000, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                LogManager.shared.log(error: error, message: "⚠️ \(taskName) Attempt \(attempt) failed")
                if attempt < attempts {
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError ?? DropboxError.uploadFailed("\(taskName) failed after \(attempts) attempts")
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
            throw DropboxError.uploadFailed("Failed to create shared link: HTTP \(statusCode): \(bodyStr)")
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

    // MARK: - File Metadata

    /// Fetch duration for a single file via get_metadata (fallback when list_folder doesn't include media_info)
    func getFileDuration(path: String, accessToken: String) async -> TimeInterval? {
        guard !accessToken.isEmpty else { return nil }

        let url = URL(string: "https://api.dropboxapi.com/2/files/get_metadata")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "include_media_info": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mediaInfo = json["media_info"] as? [String: Any],
              let tag = mediaInfo[".tag"] as? String, tag == "metadata",
              let metadata = mediaInfo["metadata"] as? [String: Any],
              let durRaw = metadata["duration"] else {
            return nil
        }
        let durationMs = (durRaw as? NSNumber)?.doubleValue ?? 0
        return durationMs / 1000.0
    }

    // MARK: - API Structs
    
    // Simple struct for recordings list
    struct DropboxFileSimple {
        let name: String
        let pathDisplay: String
        let clientModified: String
        let size: UInt64
        let duration: TimeInterval?
    }

    // MARK: - App State Syncing methods

    /// Gets used and allocated space in bytes
    func getSpaceUsage(accessToken: String) async throws -> (used: UInt64, allocated: UInt64) {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }
        let url = URL(string: "https://api.dropboxapi.com/2/users/get_space_usage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let used = json["used"] as? NSNumber,
              let allocation = json["allocation"] as? [String: Any],
              let allocated = allocation["allocated"] as? NSNumber else {
            throw DropboxError.noData
        }
        
        return (used: used.uint64Value, allocated: allocated.uint64Value)
    }

    /// List files in the NoCorny Tracer folder, handling pagination
    func listFolder(path: String = "", accessToken: String) async throws -> [DropboxFileSimple] {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }

        // Initial request
        let listUrl = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
        var request = URLRequest(url: listUrl)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "path": path,
            "recursive": false,
            "include_media_info": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 409 {
            return []
        }
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw DropboxError.noData
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else {
            return []
        }

        var allEntries = entries
        var hasMore = (json["has_more"] as? Bool) ?? false
        var cursor = json["cursor"] as? String

        // Paginate with list_folder/continue
        while hasMore, let cur = cursor {
            let continueUrl = URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
            var contRequest = URLRequest(url: continueUrl)
            contRequest.httpMethod = "POST"
            contRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            contRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            contRequest.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cur])

            let (contData, contResponse) = try await URLSession.shared.data(for: contRequest)
            guard let contHttp = contResponse as? HTTPURLResponse,
                  (200...299).contains(contHttp.statusCode),
                  let contJson = try? JSONSerialization.jsonObject(with: contData) as? [String: Any],
                  let moreEntries = contJson["entries"] as? [[String: Any]] else {
                break
            }

            allEntries.append(contentsOf: moreEntries)
            hasMore = (contJson["has_more"] as? Bool) ?? false
            cursor = contJson["cursor"] as? String
        }

        // Parse entries into files
        var files: [DropboxFileSimple] = []
        for entry in allEntries {
            guard let name = entry["name"] as? String,
                  let entryPath = entry["path_display"] as? String,
                  let modified = entry["client_modified"] as? String else { continue }

            if !entryPath.lowercased().hasSuffix(".mp4") { continue }

            let size = (entry["size"] as? NSNumber)?.uint64Value ?? 0

            var duration: TimeInterval?
            if let mediaInfo = entry["media_info"] as? [String: Any],
               let tag = mediaInfo[".tag"] as? String,
               tag == "metadata",
               let metadata = mediaInfo["metadata"] as? [String: Any],
               let durRaw = metadata["duration"] {
                let durationMs = (durRaw as? NSNumber)?.doubleValue ?? 0
                duration = durationMs / 1000.0
            }

            files.append(DropboxFileSimple(name: name, pathDisplay: entryPath, clientModified: modified, size: size, duration: duration))
        }
        return files
    }

    /// Fetches all shared links dict (path_lower -> url), handling pagination
    func listAllSharedLinks(accessToken: String) async throws -> [String: String] {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }
        let url = URL(string: "https://api.dropboxapi.com/2/sharing/list_shared_links")!

        var map: [String: String] = [:]
        var cursor: String? = nil
        var hasMore = true

        while hasMore {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            var body: [String: Any] = [:]
            if let cursor = cursor {
                body["cursor"] = cursor
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (responseData, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let links = json["links"] as? [[String: Any]] else {
                throw DropboxError.noData
            }

            for link in links {
                if let path = link["path_lower"] as? String,
                   let linkUrl = link["url"] as? String {
                    map[path] = linkUrl
                }
            }

            hasMore = (json["has_more"] as? Bool) ?? false
            if hasMore {
                cursor = json["cursor"] as? String
                if cursor == nil { hasMore = false }
            }
        }

        return map
    }

    /// Deletes a file at path
    func deleteFile(path: String, accessToken: String) async throws {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }
        let url = URL(string: "https://api.dropboxapi.com/2/files/delete_v2")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["path": path]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await withRetry(taskName: "Delete") {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw DropboxError.noData
            }
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
                throw DropboxError.noData
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
