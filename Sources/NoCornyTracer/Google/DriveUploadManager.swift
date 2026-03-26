import Foundation

/// Handles uploading recorded videos to Google Drive via REST API
final class DriveUploadManager {

    enum DriveError: LocalizedError {
        case invalidToken
        case uploadFailed(String)
        case noData

        var errorDescription: String? {
            switch self {
            case .invalidToken: return "Invalid or expired Google access token"
            case .uploadFailed(let msg): return "Upload failed: \(msg)"
            case .noData: return "No data received from server"
            }
        }
    }

    // MARK: - Upload

    /// Uploads a file to Google Drive using resumable upload
    /// Returns the Google Drive file ID on success
    func upload(fileURL: URL, fileName: String, accessToken: String, folderID: String? = nil) async throws -> String {
        guard !accessToken.isEmpty else {
            throw DriveError.invalidToken
        }

        let fileData = try Data(contentsOf: fileURL)

        // Step 1: Initiate resumable upload session
        let uploadURL = try await initiateUpload(
            fileName: fileName,
            mimeType: "video/mp4",
            fileSize: fileData.count,
            folderID: folderID,
            accessToken: accessToken
        )

        // Step 2: Upload the file data
        let fileID = try await uploadData(fileData, to: uploadURL, accessToken: accessToken)

        // Step 3: Make the file public (anyone with the link can view)
        do {
            try await makeFilePublic(fileID: fileID, accessToken: accessToken)
        } catch {
            print("⚠️ Failed to make file public: \(error)")
            // We still return the fileID because the upload itself succeeded
        }

        return fileID
    }

    // MARK: - Resumable Upload Flow

    private func initiateUpload(
        fileName: String,
        mimeType: String,
        fileSize: Int,
        folderID: String?,
        accessToken: String
    ) async throws -> URL {
        let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        request.setValue(mimeType, forHTTPHeaderField: "X-Upload-Content-Type")

        // File metadata
        var metadata: [String: Any] = ["name": fileName]
        if let folderID = folderID {
            metadata["parents"] = [folderID]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              let locationHeader = httpResponse.value(forHTTPHeaderField: "Location"),
              let uploadURL = URL(string: locationHeader) else {
            throw DriveError.uploadFailed("Failed to initiate upload session")
        }

        return uploadURL
    }

    private func uploadData(_ data: Data, to uploadURL: URL, accessToken: String) async throws -> String {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DriveError.uploadFailed("HTTP \(statusCode)")
        }

        // Parse response for file ID
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let fileID = json["id"] as? String else {
            throw DriveError.noData
        }

        return fileID
    }

    // MARK: - Folder Management

    /// Find an existing folder by name in Google Drive
    func findFolder(name: String, accessToken: String) async throws -> String? {
        let query = "name='\(name)' and mimeType='application/vnd.google-apps.folder' and trashed=false"
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://www.googleapis.com/drive/v3/files?q=\(encodedQuery)&fields=files(id)")!

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let files = json["files"] as? [[String: Any]] else {
            return nil
        }

        return files.first?["id"] as? String
    }

    /// Find or create a folder by name
    func findOrCreateFolder(name: String, accessToken: String) async throws -> String {
        if let existingID = try await findFolder(name: name, accessToken: accessToken) {
            return existingID
        }
        return try await createFolder(name: name, accessToken: accessToken)
    }

    func createFolder(name: String, accessToken: String) async throws -> String {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (responseData, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let folderID = json["id"] as? String else {
            throw DriveError.uploadFailed("Failed to create folder")
        }

        return folderID
    }

    // MARK: - Rename File

    /// Rename a file on Google Drive
    func renameFile(fileID: String, newName: String, accessToken: String) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)")!

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = ["name": newName]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DriveError.uploadFailed("Rename failed: HTTP \(statusCode)")
        }
    }

    // MARK: - Permissions

    /// Change file permissions to be visible to anyone with the link
    func makeFilePublic(fileID: String, accessToken: String) async throws {
        let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)/permissions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let metadata: [String: Any] = [
            "role": "reader",
            "type": "anyone"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DriveError.uploadFailed("Failed to set permissions: HTTP \(statusCode)")
        }
    }

    // MARK: - Upload Text File

    /// Upload a text file (e.g. subtitles SRT) to Google Drive
    func uploadTextFile(content: String, fileName: String, mimeType: String, folderID: String?, accessToken: String) async throws -> String {
        guard !accessToken.isEmpty else {
            throw DriveError.invalidToken
        }

        guard let fileData = content.data(using: .utf8) else {
            throw DriveError.noData
        }

        let uploadURL = try await initiateUpload(
            fileName: fileName,
            mimeType: mimeType,
            fileSize: fileData.count,
            folderID: folderID,
            accessToken: accessToken
        )

        let fileID = try await uploadData(fileData, to: uploadURL, accessToken: accessToken)
        
        // Make the file public (anyone with the link can view)
        do {
            try await makeFilePublic(fileID: fileID, accessToken: accessToken)
        } catch {
            print("⚠️ Failed to make text file public: \(error)")
        }
        
        return fileID
    }
}
