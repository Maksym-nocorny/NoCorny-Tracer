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
            return try await withRetry {
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
        let apiArgData = try JSONSerialization.data(withJSONObject: apiArg)
        request.setValue(String(data: apiArgData, encoding: .utf8)!, forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: responseData, encoding: .utf8) ?? ""
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
        let sessionID = try await withRetry {
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
                return try await withRetry {
                    try await self.finishUploadSession(
                        sessionID: sessionID,
                        offset: Int(offset),
                        data: chunkData,
                        path: path,
                        accessToken: accessToken
                    )
                }
            } else {
                try await withRetry {
                    try await self.appendUploadSession(sessionID: sessionID, offset: Int(offset), data: chunkData, accessToken: accessToken)
                }
                offset += UInt64(chunkData.count)
            }
        }

        // If we somehow didn't finish (shouldn't happen with total flow above)
        return try await withRetry {
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
        let apiArgData = try JSONSerialization.data(withJSONObject: apiArg)
        request.setValue(String(data: apiArgData, encoding: .utf8)!, forHTTPHeaderField: "Dropbox-API-Arg")
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
        let apiArgData = try JSONSerialization.data(withJSONObject: apiArg)
        request.setValue(String(data: apiArgData, encoding: .utf8)!, forHTTPHeaderField: "Dropbox-API-Arg")
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
        let apiArgData = try JSONSerialization.data(withJSONObject: apiArg)
        request.setValue(String(data: apiArgData, encoding: .utf8)!, forHTTPHeaderField: "Dropbox-API-Arg")
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

    private func withRetry<T>(attempts: Int = 3, delay: UInt64 = 1_000_000_000, operation: @escaping () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                return try await operation()
            } catch {
                lastError = error
                print("⚠️ Upload Attempt \(attempt) failed: \(error.localizedDescription). Retrying in \(Double(delay)/1_000_000_000)s...")
                if attempt < attempts {
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError ?? DropboxError.uploadFailed("Unknown retry error")
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

        return try await withRetry {
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

    // MARK: - Upload Text File

    /// Upload a text file (e.g. subtitles SRT) to Dropbox. Returns the Dropbox path.
    func uploadTextFile(content: String, fileName: String, accessToken: String) async throws -> String {
        guard !accessToken.isEmpty else {
            throw DropboxError.invalidToken
        }

        guard let fileData = content.data(using: .utf8) else {
            throw DropboxError.noData
        }

        let dropboxPath = "/\(fileName)"
        return try await simpleUpload(data: fileData, path: dropboxPath, accessToken: accessToken)
    }

    // MARK: - API Structs
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

    /// List files in the NoCorny Tracer folder
    func listFolder(path: String = "", accessToken: String) async throws -> [DropboxFileSimple] {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }
        let url = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
        var request = URLRequest(url: url)
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
            // Folder likely doesn't exist yet, return empty list
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
        
        var files: [DropboxFileSimple] = []
        for entry in entries {
            guard let name = entry["name"] as? String,
                  let path = entry["path_display"] as? String,
                  let modified = entry["client_modified"] as? String,
                  let size = entry["size"] as? UInt64 else { continue }
            
            if !path.lowercased().hasSuffix(".mp4") { continue }
            
            var duration: TimeInterval?
            if let mediaInfo = entry["media_info"] as? [String: Any],
               let metadata = mediaInfo["metadata"] as? [String: Any],
               let durRaw = metadata["duration"] {
                // Dropbox returns duration in milliseconds — convert to seconds
                let durationMs = (durRaw as? NSNumber)?.doubleValue ?? (durRaw as? Double) ?? 0
                duration = durationMs / 1000.0
            }
            
            files.append(DropboxFileSimple(name: name, pathDisplay: path, clientModified: modified, size: size, duration: duration))
        }
        return files
    }

    /// Fetches all shared links dict (path_display -> url)
    func listAllSharedLinks(accessToken: String) async throws -> [String: String] {
        guard !accessToken.isEmpty else { throw DropboxError.invalidToken }
        let url = URL(string: "https://api.dropboxapi.com/2/sharing/list_shared_links")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Don't pass path to get ALL links, we can filter locally or let the response contain what we need
        request.httpBody = try JSONSerialization.data(withJSONObject: [:])

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let links = json["links"] as? [[String: Any]] else {
            throw DropboxError.noData
        }
        
        var map: [String: String] = [:]
        for link in links {
            if let path = link["path_lower"] as? String,
               let url = link["url"] as? String {
                map[path] = url
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

        try await withRetry {
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
        let argData = try JSONSerialization.data(withJSONObject: arg)
        
        if let jsonString = String(data: argData, encoding: .utf8) {
            request.setValue(jsonString, forHTTPHeaderField: "Dropbox-API-Arg")
        }
        
        return try await withRetry {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                throw DropboxError.noData
            }
            return data
        }
    }
}
