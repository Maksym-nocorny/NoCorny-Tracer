import Foundation
import AppKit

/// Client for the Tracer web backend at tracer.nocorny.com.
/// Handles API token storage (Keychain) and video registration.
@Observable
final class TracerAPIClient {
    // MARK: - Configuration
    static let baseURL = "https://tracer.nocorny.com"
    static let callbackURL = "nocornytracer://auth/callback"

    // Keychain / UserDefaults keys
    private static let tokenKey = "TracerAPIToken"
    private static let emailKey = "TracerUserEmail"
    private static let nameKey = "TracerUserName"
    private static let imageKey = "TracerUserImage"

    // MARK: - State
    var isSignedIn: Bool = false
    var userName: String?
    var userEmail: String?
    var userImageURL: String?
    var errorMessage: String?
    var isLoading: Bool = false

    /// Random state generated for the current browser sign-in flow, if any.
    /// Used to verify the callback URL came from our initiated flow.
    private var pendingBrowserState: String?

    init() {
        if let token = KeychainHelper.load(key: Self.tokenKey), !token.isEmpty {
            self.isSignedIn = true
            self.userEmail = Self.nonEmpty(UserDefaults.standard.string(forKey: Self.emailKey))
            self.userName = Self.nonEmpty(UserDefaults.standard.string(forKey: Self.nameKey))
            self.userImageURL = Self.nonEmpty(UserDefaults.standard.string(forKey: Self.imageKey))

            // Refresh profile from server in the background so renames/avatar changes
            // made on tracer.nocorny.com show up without requiring a re-sign-in.
            Task { await self.refreshProfile() }
        }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Sign In (paste token)

    /// Validates a user-pasted token against /api/tokens/me and persists it on success.
    @MainActor
    func signIn(token: String) async -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.errorMessage = "Token is empty"
            return false
        }

        self.isLoading = true
        self.errorMessage = nil
        defer { self.isLoading = false }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/tokens/me")!)
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                self.errorMessage = "Invalid token"
                return false
            }

            let info = try JSONDecoder().decode(TokenInfo.self, from: data)

            try? KeychainHelper.save(key: Self.tokenKey, value: trimmed)
            UserDefaults.standard.set(info.email, forKey: Self.emailKey)
            UserDefaults.standard.set(info.name ?? "", forKey: Self.nameKey)
            UserDefaults.standard.set(info.image ?? "", forKey: Self.imageKey)

            self.isSignedIn = true
            self.userEmail = info.email
            self.userName = Self.nonEmpty(info.name)
            self.userImageURL = Self.nonEmpty(info.image)
            LogManager.shared.log("🔐 Tracer: Signed in as \(info.email)")
            return true
        } catch {
            self.errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Sign In (browser)

    /// Opens the device-authorization page in the user's default browser.
    /// The web page signs the user in (Google/email) and redirects to
    /// `nocornytracer://auth/callback?token=…&state=…`, which is captured by the
    /// app's URL-scheme handler and passed to `completeBrowserSignIn(url:)`.
    @MainActor
    func startBrowserSignIn() {
        let state = UUID().uuidString
        self.pendingBrowserState = state
        self.errorMessage = nil

        var components = URLComponents(string: "\(Self.baseURL)/auth/device")!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "redirect", value: Self.callbackURL),
        ]
        guard let url = components.url else {
            self.errorMessage = "Failed to build authorization URL"
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Called by the app's URL-scheme handler when a `nocornytracer://auth/callback`
    /// URL is received. Validates `state` and exchanges the token via `signIn(token:)`.
    @MainActor
    func completeBrowserSignIn(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            self.errorMessage = "Invalid callback URL"
            return
        }
        let token = items.first(where: { $0.name == "token" })?.value
        let state = items.first(where: { $0.name == "state" })?.value

        if let expected = self.pendingBrowserState, state != expected {
            self.errorMessage = "Authorization state mismatch"
            return
        }
        self.pendingBrowserState = nil

        guard let token = token, !token.isEmpty else {
            if let err = items.first(where: { $0.name == "error" })?.value, !err.isEmpty {
                self.errorMessage = err
            } else {
                self.errorMessage = "No token received"
            }
            return
        }

        _ = await signIn(token: token)
    }

    // MARK: - Sign Out

    @MainActor
    func signOut() {
        KeychainHelper.delete(key: Self.tokenKey)
        UserDefaults.standard.removeObject(forKey: Self.emailKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        UserDefaults.standard.removeObject(forKey: Self.imageKey)
        self.isSignedIn = false
        self.userEmail = nil
        self.userName = nil
        self.userImageURL = nil
        AvatarCache.shared.clear()
        LogManager.shared.log("🔐 Tracer: Signed out")
    }

    // MARK: - Refresh Profile

    /// Re-fetches the user's profile from /api/tokens/me and updates UI state.
    /// Called after sign-in and on app launch so the displayed name/avatar stay
    /// in sync with changes made on tracer.nocorny.com.
    @MainActor
    func refreshProfile() async {
        guard let token = apiToken else { return }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/tokens/me")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            let info = try JSONDecoder().decode(TokenInfo.self, from: data)

            UserDefaults.standard.set(info.email, forKey: Self.emailKey)
            UserDefaults.standard.set(info.name ?? "", forKey: Self.nameKey)
            UserDefaults.standard.set(info.image ?? "", forKey: Self.imageKey)

            self.userEmail = info.email
            self.userName = Self.nonEmpty(info.name)
            self.userImageURL = Self.nonEmpty(info.image)
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: refresh profile failed")
        }
    }

    // MARK: - AI Usage payload (cost tracking)

    /// Token usage + metadata sent alongside video registration/updates so the backend
    /// can write an `ai_events` row for cost analytics.
    struct AIUsagePayload {
        let kind: String
        let model: String
        let promptTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        let modalityBreakdown: [(modality: String, tokenCount: Int)]
        let latencyMs: Int
        let attempts: Int
        let success: Bool
        let errorCode: String?

        /// JSON dictionary suitable for embedding under `aiUsage` in API requests.
        /// Returns nil if there's nothing meaningful to report (no tokens AND no error).
        func toJSON() -> [String: Any]? {
            let hasUsage = promptTokens > 0 || outputTokens > 0 || totalTokens > 0
            let hasError = !success && errorCode != nil
            guard hasUsage || hasError else { return nil }
            var dict: [String: Any] = [
                "kind": kind,
                "model": model,
                "promptTokens": promptTokens,
                "outputTokens": outputTokens,
                "totalTokens": totalTokens,
                "latencyMs": latencyMs,
                "attempts": attempts,
                "success": success,
            ]
            dict["modalityBreakdown"] = modalityBreakdown.map { ["modality": $0.modality, "tokenCount": $0.tokenCount] }
            if let err = errorCode { dict["errorCode"] = err }
            return dict
        }
    }

    // MARK: - Init Video (slug reservation)

    /// Phase 0: Reserves a slug + per-video Dropbox folder *before* uploading bytes.
    /// The macOS app calls this immediately after Stop so it can both open the
    /// browser to /v/{slug} and start uploading in parallel.
    /// Returns nil on failure (e.g. unauthorized, network).
    func initVideo(recordedAt: Date, durationEstimate: TimeInterval?) async -> InitVideoResponse? {
        guard let token = KeychainHelper.load(key: Self.tokenKey), !token.isEmpty else { return nil }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/videos/init")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "recordedAt": ISO8601DateFormatter().string(from: recordedAt),
        ]
        if let d = durationEstimate, d > 0 { body["durationEstimate"] = d }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if let http = response as? HTTPURLResponse {
                    LogManager.shared.log("🌐 Tracer: initVideo failed with status \(http.statusCode)", type: .error)
                }
                return nil
            }
            let resp = try JSONDecoder().decode(InitVideoResponse.self, from: data)
            LogManager.shared.log("🌐 Tracer: ✅ initVideo — slug=\(resp.slug) folder=\(resp.uploadFolder)")
            return resp
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: initVideo failed")
            return nil
        }
    }

    // MARK: - Register Video

    /// Phase 1: Registers an uploaded video with the Tracer backend immediately after upload.
    /// Returns the slug + full share URL, or nil on failure.
    func registerVideo(
        title: String,
        dropboxPath: String,
        dropboxSharedURL: String?,
        duration: TimeInterval,
        fileSize: UInt64?,
        recordedAt: Date,
        thumbnailURL: String? = nil,
        subtitlesSrt: String? = nil,
        processingStatus: String = "ready",
        aiUsage: AIUsagePayload? = nil
    ) async -> RegisteredVideo? {
        guard let token = KeychainHelper.load(key: Self.tokenKey), !token.isEmpty else {
            return nil
        }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/videos")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "title": title,
            "dropboxPath": dropboxPath,
            "duration": duration,
            "recordedAt": ISO8601DateFormatter().string(from: recordedAt),
            "processingStatus": processingStatus,
        ]
        if let url = dropboxSharedURL { body["dropboxSharedUrl"] = url }
        if let size = fileSize { body["fileSize"] = size }
        if let thumb = thumbnailURL { body["thumbnailUrl"] = thumb }
        if let srt = subtitlesSrt, !srt.isEmpty { body["transcriptSrt"] = srt }
        if let usage = aiUsage?.toJSON() { body["aiUsage"] = usage }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                if let http = response as? HTTPURLResponse {
                    LogManager.shared.log("🌐 Tracer: Register video failed with status \(http.statusCode)", type: .error)
                }
                return nil
            }
            let video = try JSONDecoder().decode(RegisteredVideo.self, from: data)
            LogManager.shared.log("🌐 Tracer: ✅ Registered video — \(video.url)")
            return video
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: Register video failed")
            return nil
        }
    }

    /// Generic PATCH /api/videos/{slug}. Every parameter is optional so callers
    /// can update just one slice of state — used both for "upload finished"
    /// (sharedURL/fileSize/duration) and "AI finished" (title/transcript/thumb).
    func updateVideo(
        slug: String,
        title: String? = nil,
        dropboxPath: String? = nil,
        dropboxSharedURL: String? = nil,
        fileSize: UInt64? = nil,
        duration: TimeInterval? = nil,
        transcriptSrt: String? = nil,
        thumbnailURL: String? = nil,
        processingStatus: String? = nil,
        aiUsage: AIUsagePayload? = nil
    ) async {
        guard let token = KeychainHelper.load(key: Self.tokenKey), !token.isEmpty else { return }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/videos/\(slug)")!)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 120  // description gen can take up to ~60s
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let path = dropboxPath { body["dropboxPath"] = path }
        if let url = dropboxSharedURL { body["dropboxSharedUrl"] = url }
        if let size = fileSize { body["fileSize"] = size }
        if let d = duration { body["duration"] = d }
        if let srt = transcriptSrt, !srt.isEmpty { body["transcriptSrt"] = srt }
        if let thumb = thumbnailURL { body["thumbnailUrl"] = thumb }
        if let status = processingStatus { body["processingStatus"] = status }
        if let usage = aiUsage?.toJSON() { body["aiUsage"] = usage }

        // Don't fire an empty PATCH — server will reject with 400.
        guard !body.isEmpty else { return }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                LogManager.shared.log("🌐 Tracer: PATCH /api/videos/\(slug) → \(http.statusCode)")
            }
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: updateVideo failed")
        }
    }

    // MARK: - Token accessor

    /// Returns the currently stored API token, or nil if not signed in.
    var apiToken: String? {
        KeychainHelper.load(key: Self.tokenKey)
    }

    // MARK: - Dropbox proxy

    /// Fetches a short-lived Dropbox access token from the Tracer backend.
    /// Requires the user to be signed in to Tracer AND to have connected Dropbox
    /// on tracer.nocorny.com. Returns nil if either is missing.
    func fetchDropboxAccessToken() async -> DropboxProxyToken? {
        guard let token = apiToken else { return nil }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/dropbox/access-token")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(DropboxProxyToken.self, from: data)
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: fetch Dropbox token failed")
            return nil
        }
    }

    /// Removes the user's Dropbox connection from the Tracer backend.
    @discardableResult
    func disconnectDropbox() async -> Bool {
        guard let token = apiToken else { return false }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/dropbox/disconnect")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: disconnect Dropbox failed")
            return false
        }
    }

    // MARK: - List Videos

    /// Lists the user's videos. When `since` is non-nil the server returns only
    /// rows whose `updatedAt > since` (including soft-deleted rows). The envelope
    /// also carries the new cursor (`serverTime`) and current storage usage so
    /// the app never has to call Dropbox for quota at runtime.
    func listVideos(since: Date? = nil) async -> VideosEnvelope? {
        guard let token = apiToken else { return nil }

        var components = URLComponents(string: "\(Self.baseURL)/api/videos")!
        if let since {
            components.queryItems = [
                URLQueryItem(name: "since", value: ISO8601DateFormatter().string(from: since)),
            ]
        }
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(VideosEnvelope.self, from: data)
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: list videos failed")
            return nil
        }
    }

    // MARK: - Delete Video

    /// Soft-deletes the video on the server, which also asks Dropbox to delete
    /// the underlying file. The macOS app never talks to Dropbox for deletion.
    @discardableResult
    func deleteVideo(slug: String) async -> Bool {
        guard let token = apiToken else { return false }
        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/videos/\(slug)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: delete video failed")
            return false
        }
    }

    // MARK: - Types

    struct DropboxProxyToken: Codable {
        let connected: Bool
        let accessToken: String?
        let expiresAt: String?

        private enum CodingKeys: String, CodingKey {
            case connected, accessToken, expiresAt
        }
    }

    struct TracerVideo: Codable {
        let id: String
        let slug: String
        let title: String
        let processingStatus: String?
        let dropboxPath: String
        let dropboxSharedUrl: String?
        let duration: Double?
        let fileSize: Int64?
        let thumbnailUrl: String?
        let isDeleted: Bool?
        let recordedAt: Date?
        let createdAt: Date?
        let updatedAt: Date?
    }

    struct VideosEnvelope: Codable {
        let videos: [TracerVideo]
        let serverTime: Date?
        let usage: Usage?

        struct Usage: Codable {
            let usedBytes: Int64?
            let allocatedBytes: Int64?
        }
    }

    struct RegisteredVideo: Codable {
        let id: String
        let slug: String
        let url: String
    }

    /// Response from `POST /api/videos/init`. The server picks the canonical
    /// filenames inside the slug folder so the client doesn't drift if we ever
    /// change them. Compose the Dropbox path as `"\(uploadFolder)/\(videoFilename)"`.
    struct InitVideoResponse: Codable {
        let slug: String
        let uploadFolder: String       // e.g. "/videos/xFel134"
        let videoFilename: String      // e.g. "video.mp4"
        let transcriptFilename: String // e.g. "transcript.srt"
        let thumbnailFilename: String  // e.g. "thumbnail.jpg"
        let url: String                // e.g. "https://tracer.nocorny.com/v/xFel134"
    }

    struct TokenInfo: Codable {
        let email: String
        let name: String?
        let image: String?
    }
}
