import Foundation

/// Handles uploading recorded videos to Dropbox via REST API (no SDK dependency)
final class DropboxUploadManager {

    enum DropboxError: LocalizedError {
        case invalidToken
        case uploadFailed(String)
        case noData

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "Invalid or expired Dropbox access token"
            case .uploadFailed(let msg): return "Upload failed: \(msg)"
            case .noData: return "No data received from server"
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

        let fileData = try Data(contentsOf: fileURL)
        let dropboxPath = "/\(fileName)"

        if fileData.count <= simpleUploadLimit {
            return try await simpleUpload(data: fileData, path: dropboxPath, accessToken: accessToken)
        } else {
            return try await sessionUpload(data: fileData, path: dropboxPath, accessToken: accessToken)
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

    private func sessionUpload(data: Data, path: String, accessToken: String) async throws -> String {
        // Start session with first chunk
        let firstChunkEnd = min(chunkSize, data.count)
        let firstChunk = data.subdata(in: 0..<firstChunkEnd)
        let sessionID = try await startUploadSession(data: firstChunk, accessToken: accessToken)

        // Upload middle chunks
        var offset = firstChunkEnd
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let isLast = (end == data.count)

            if isLast {
                // Finish with last chunk
                let lastChunk = data.subdata(in: offset..<end)
                return try await finishUploadSession(
                    sessionID: sessionID,
                    offset: offset,
                    data: lastChunk,
                    path: path,
                    accessToken: accessToken
                )
            } else {
                let chunk = data.subdata(in: offset..<end)
                try await appendUploadSession(sessionID: sessionID, offset: offset, data: chunk, accessToken: accessToken)
                offset = end
            }
        }

        // If file fit in first chunk, finish with empty data
        return try await finishUploadSession(
            sessionID: sessionID,
            offset: firstChunkEnd,
            data: Data(),
            path: path,
            accessToken: accessToken
        )
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
            return try await getExistingSharedLink(path: path, accessToken: accessToken)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let bodyStr = String(data: responseData, encoding: .utf8) ?? ""
        throw DropboxError.uploadFailed("Failed to create shared link: HTTP \(statusCode): \(bodyStr)")
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
}
