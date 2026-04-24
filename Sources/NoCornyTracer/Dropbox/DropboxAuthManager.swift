import Foundation
import AppKit
import CryptoKit

/// Manages Dropbox OAuth2 authentication using PKCE + system default browser.
///
/// Also supports **proxied mode**: when the user is signed in to Tracer
/// (tracer.nocorny.com) and has connected Dropbox there, the app skips its own
/// OAuth flow and obtains short-lived access tokens from the Tracer backend.
/// In proxied mode `isProxied == true`, `signIn()` opens the web settings, and
/// token refresh hits `/api/dropbox/access-token` instead of Dropbox directly.
@Observable
final class DropboxAuthManager: NSObject {
    // MARK: - State
    var isSignedIn = false
    var userName: String?
    var userEmail: String?
    var accessToken: String?
    var isLoading = false
    var errorMessage: String?
    var showConnectionConfirmation = false

    /// True when Dropbox credentials are sourced from the Tracer backend rather than local OAuth.
    var isProxied = false

    /// Async closure that fetches a fresh Dropbox access token from Tracer.
    /// Set by `AppState` after construction. Returns nil if server says not connected.
    var fetchProxiedToken: (() async -> (accessToken: String, expiresAt: Date?)?)?

    /// Opens the web settings page where the user manages their Dropbox connection.
    var openWebDropboxSettings: (() -> Void)?

    /// Indicates whether the user is signed in to Tracer. Controls whether the
    /// Dropbox sign-in button opens the web settings or falls back to local OAuth.
    var isTracerSignedIn: () -> Bool = { false }

    private var proxiedExpiresAt: Date?

    // MARK: - Configuration
    private let appKey = AppSecrets.dropboxAppKey

    private var redirectURI: String {
        "db-\(appKey)://oauth2callback"
    }

    /// Whether real Dropbox credentials have been configured
    var isConfigured: Bool {
        !appKey.contains("YOUR_DROPBOX_APP_KEY")
    }

    // Keychain keys (tokens are sensitive — never store in UserDefaults)
    private let tokenKey = "DropboxAccessToken"
    private let refreshTokenKey = "DropboxRefreshToken"
    // Expiry is not sensitive, fine in UserDefaults
    private let expiresAtKey = "DropboxTokenExpiry"

    /// Stored between signIn() and handleCallback()
    private var pendingCodeVerifier: String?

    override init() {
        super.init()
        restorePreviousSignIn()
    }

    // MARK: - Sign In (opens default browser)

    func signIn() {
        // When user is signed in to Tracer, Dropbox is managed on the web.
        // Redirect to the web settings page instead of triggering a second OAuth flow.
        if isTracerSignedIn(), let openWeb = openWebDropboxSettings {
            openWeb()
            return
        }

        guard isConfigured else {
            errorMessage = "Dropbox App Key not configured."
            return
        }

        isLoading = true
        errorMessage = nil

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(verifier: codeVerifier)
        self.pendingCodeVerifier = codeVerifier

        var comp = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "token_access_type", value: "offline"),
        ]

        guard let authURL = comp.url else {
            errorMessage = "Failed to construct auth URL"
            isLoading = false
            return
        }

        // Open in the user's default browser (Chrome, Firefox, Arc, etc.)
        NSWorkspace.shared.open(authURL)
    }

    // MARK: - Handle OAuth Callback (called by onOpenURL in App)

    /// Call this when the app receives a URL via the registered URL scheme.
    func handleCallback(_ url: URL) {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let code = comp.queryItems?.first(where: { $0.name == "code" })?.value,
              let codeVerifier = pendingCodeVerifier else {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "Invalid callback URL or missing code verifier"
            }
            return
        }

        pendingCodeVerifier = nil
        exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
    }

    // MARK: - Sign Out

    func signOut() {
        // Proxied sign-out means "manage connection on the web" — open the settings page
        // and clear the in-memory token. The actual Dropbox link is removed on the web.
        if isProxied {
            openWebDropboxSettings?()
            isSignedIn = false
            accessToken = nil
            proxiedExpiresAt = nil
            userName = nil
            userEmail = nil
            return
        }

        KeychainHelper.delete(key: tokenKey)
        KeychainHelper.delete(key: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: expiresAtKey)

        isSignedIn = false
        userName = nil
        userEmail = nil
        accessToken = nil
    }

    // MARK: - Restore Session

    private func restorePreviousSignIn() {
        // Migrate tokens from UserDefaults to Keychain (one-time, for existing users)
        migrateTokensToKeychain()

        guard isConfigured,
              let _ = KeychainHelper.load(key: refreshTokenKey) else { return }

        Task {
            if let token = await refreshTokenIfNeeded() {
                self.accessToken = token
                await fetchAccountInfo(token: token)
            }
        }
    }

    // MARK: - Proxied Mode (Tracer backend issues Dropbox tokens)

    /// Activates proxied mode with an initial token. Subsequent refreshes go through `fetchProxiedToken`.
    @MainActor
    func applyProxiedToken(accessToken: String, expiresAt: Date?) async {
        self.isProxied = true
        self.accessToken = accessToken
        self.proxiedExpiresAt = expiresAt
        self.isSignedIn = true
        await fetchAccountInfo(token: accessToken)
    }

    /// Clears proxied state when the user signs out of Tracer.
    @MainActor
    func clearProxiedState() {
        guard isProxied else { return }
        isProxied = false
        accessToken = nil
        proxiedExpiresAt = nil
        isSignedIn = false
        userName = nil
        userEmail = nil
    }

    // MARK: - Token Refresh

    func refreshTokenIfNeeded() async -> String? {
        // Proxied mode — refresh via Tracer backend, not Dropbox OAuth.
        if isProxied {
            if let current = accessToken,
               let expiry = proxiedExpiresAt,
               Date().addingTimeInterval(300) < expiry {
                return current
            }
            guard let fetch = fetchProxiedToken, let result = await fetch() else {
                DispatchQueue.main.async {
                    self.isSignedIn = false
                    self.accessToken = nil
                }
                return nil
            }
            DispatchQueue.main.async {
                self.accessToken = result.accessToken
                self.proxiedExpiresAt = result.expiresAt
            }
            return result.accessToken
        }

        guard let refreshToken = KeychainHelper.load(key: refreshTokenKey) else { return nil }

        // Use current token if still valid (5 min buffer)
        if let expiry = UserDefaults.standard.object(forKey: expiresAtKey) as? Date,
           let currentToken = KeychainHelper.load(key: tokenKey),
           Date().addingTimeInterval(300) < expiry {
            return currentToken
        }

        let url = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComp = URLComponents()
        bodyComp.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: appKey),
        ]
        request.httpBody = bodyComp.query?.data(using: .utf8)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newAccessToken = json["access_token"] as? String {

                if let expiresIn = json["expires_in"] as? TimeInterval {
                    UserDefaults.standard.set(Date().addingTimeInterval(expiresIn), forKey: expiresAtKey)
                }
                try? KeychainHelper.save(key: tokenKey, value: newAccessToken)

                DispatchQueue.main.async { self.accessToken = newAccessToken }
                return newAccessToken
            }
        } catch {
            print("Failed to refresh Dropbox token: \(error)")
        }

        return nil
    }

    // MARK: - Token Exchange

    private func exchangeCodeForToken(code: String, codeVerifier: String) {
        let url = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComp = URLComponents()
        bodyComp.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
        ]
        request.httpBody = bodyComp.query?.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    self?.errorMessage = "Token exchange failed: \(error.localizedDescription)"
                    return
                }

                guard let data = data else {
                    self?.errorMessage = "No data from token exchange"
                    return
                }

                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let errMsg = json["error_description"] as? String ?? json["error"] as? String {
                            self?.errorMessage = errMsg
                            return
                        }

                        guard let token = json["access_token"] as? String else {
                            self?.errorMessage = "No access token in response"
                            return
                        }

                        try? KeychainHelper.save(key: self?.tokenKey ?? "", value: token)
                        if let refreshToken = json["refresh_token"] as? String {
                            try? KeychainHelper.save(key: self?.refreshTokenKey ?? "", value: refreshToken)
                        }
                        if let expiresIn = json["expires_in"] as? TimeInterval {
                            UserDefaults.standard.set(Date().addingTimeInterval(expiresIn), forKey: self?.expiresAtKey ?? "")
                        }

                        self?.accessToken = token

                        Task { [weak self] in
                            await self?.fetchAccountInfo(token: token, isNewConnection: true)
                        }
                    }
                } catch {
                    self?.errorMessage = "Failed to parse token response"
                }
            }
        }.resume()
    }

    // MARK: - Account Info

    private func fetchAccountInfo(token: String, isNewConnection: Bool = false) async {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async {
                    self.isSignedIn = true
                    self.userEmail = json["email"] as? String
                    if let name = json["name"] as? [String: Any] {
                        self.userName = name["display_name"] as? String
                    }
                    if isNewConnection {
                        self.showConnectionConfirmation = true
                    }
                }
            }
        } catch {
            print("Failed to fetch Dropbox account info: \(error)")
        }
    }

    // MARK: - Migration (UserDefaults → Keychain, one-time)

    private func migrateTokensToKeychain() {
        if let token = UserDefaults.standard.string(forKey: tokenKey) {
            try? KeychainHelper.save(key: tokenKey, value: token)
            UserDefaults.standard.removeObject(forKey: tokenKey)
        }
        if let refresh = UserDefaults.standard.string(forKey: refreshTokenKey) {
            try? KeychainHelper.save(key: refreshTokenKey, value: refresh)
            UserDefaults.standard.removeObject(forKey: refreshTokenKey)
        }
    }

    // MARK: - PKCE Helpers

    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateCodeChallenge(verifier: String) -> String {
        let data = verifier.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
