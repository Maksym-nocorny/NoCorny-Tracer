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
        processingStatus: String = "ready"
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

    /// Phase 2: Updates an existing video with AI-generated title, subtitles, and thumbnail.
    /// Called after Gemini finishes; flips processingStatus to "ready" so the web page updates live.
    func updateVideo(
        slug: String,
        title: String,
        dropboxPath: String?,
        transcriptSrt: String?,
        thumbnailURL: String?
    ) async {
        guard let token = KeychainHelper.load(key: Self.tokenKey), !token.isEmpty else { return }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/videos/\(slug)")!)
        request.httpMethod = "PATCH"
        request.timeoutInterval = 120  // description gen can take up to ~60s
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "title": title,
            "processingStatus": "ready",
        ]
        if let path = dropboxPath { body["dropboxPath"] = path }
        if let srt = transcriptSrt, !srt.isEmpty { body["transcriptSrt"] = srt }
        if let thumb = thumbnailURL { body["thumbnailUrl"] = thumb }

        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                LogManager.shared.log("🌐 Tracer: Phase 2 update → \(http.statusCode)")
            }
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: Phase 2 update failed")
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

    // MARK: - List Videos

    /// Lists the signed-in user's registered videos from the Tracer backend.
    func listVideos() async -> [TracerVideo] {
        guard let token = apiToken else { return [] }

        var request = URLRequest(url: URL(string: "\(Self.baseURL)/api/videos")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([TracerVideo].self, from: data)
        } catch {
            LogManager.shared.log(error: error, message: "🌐 Tracer: list videos failed")
            return []
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
        let recordedAt: Date?
        let createdAt: Date?
    }

    struct RegisteredVideo: Codable {
        let id: String
        let slug: String
        let url: String
    }

    struct TokenInfo: Codable {
        let email: String
        let name: String?
        let image: String?
    }
}
