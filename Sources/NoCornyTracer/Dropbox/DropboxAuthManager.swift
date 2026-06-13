import Foundation
import AppKit

/// Dropbox auth state for the macOS app — proxied mode only.
///
/// All Dropbox connection management (connecting an account, disconnecting,
/// switching accounts) happens on the web (tracer.nocorny.com). This object
/// just mirrors the backend's state and obtains short-lived access tokens
/// from `/api/dropbox/access-token` for upload/rename/delete calls.
///
/// `signIn()` simply opens the web settings page; there is no longer a local
/// OAuth flow inside the app.
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

    /// Always true once a token has been issued. Kept for API parity with
    /// older callers that still inspect `isProxied`.
    var isProxied = false

    /// Async closure that fetches a fresh Dropbox access token from Tracer.
    /// Set by `AppState` after construction. Returns a tri-state so a transient
    /// network failure is never mistaken for a real disconnect.
    var fetchProxiedToken: (() async -> APIResult<DropboxTokenResult>)?

    /// Disconnects Dropbox on the backend (called by sign-out).
    var disconnectProxied: (() async -> Void)?

    /// Opens the web settings page where the user manages their Dropbox connection.
    var openWebDropboxSettings: (() -> Void)?

    /// Indicates whether the user is signed in to Tracer. The Dropbox UI uses
    /// this to decide whether to show "Connect via web" or "Sign in to Tracer first".
    var isTracerSignedIn: () -> Bool = { false }

    private var proxiedExpiresAt: Date?

    override init() {
        super.init()
    }

    // MARK: - Sign In / Sign Out

    /// Dropbox is managed on the web. Always opens the Tracer settings page.
    func signIn() {
        openWebDropboxSettings?()
    }

    func signOut() {
        isProxied = false
        isSignedIn = false
        accessToken = nil
        proxiedExpiresAt = nil
        userName = nil
        userEmail = nil
        Task { await self.disconnectProxied?() }
    }

    // MARK: - Proxied token lifecycle

    @MainActor
    func applyProxiedToken(accessToken: String, expiresAt: Date?) async {
        self.isProxied = true
        self.accessToken = accessToken
        self.proxiedExpiresAt = expiresAt
        self.isSignedIn = true
        await fetchAccountInfo(token: accessToken)
    }

    @MainActor
    func clearProxiedState() {
        guard isProxied || isSignedIn else { return }
        isProxied = false
        accessToken = nil
        proxiedExpiresAt = nil
        isSignedIn = false
        userName = nil
        userEmail = nil
    }

    // MARK: - Token Refresh (proxied)

    func refreshTokenIfNeeded() async -> String? {
        if let current = accessToken,
           let expiry = proxiedExpiresAt,
           Date().addingTimeInterval(300) < expiry {
            return current
        }
        guard let fetch = fetchProxiedToken else { return accessToken }

        switch await fetch() {
        case .success(let result):
            await MainActor.run {
                self.accessToken = result.token
                self.proxiedExpiresAt = result.expiresAt
                self.isProxied = true
                self.isSignedIn = true
            }
            return result.token

        case .authoritativeNegative:
            // Server definitively says Dropbox is not connected — tear down.
            await MainActor.run {
                self.isSignedIn = false
                self.accessToken = nil
                self.isProxied = false
                self.proxiedExpiresAt = nil
            }
            return nil

        case .transientFailure:
            // Could not reach/understand the server. Do NOT sign out on a network
            // blip — keep existing state and just report no fresh token. If the
            // current token is still within its validity window the caller can
            // keep using it; otherwise it gets nil and treats it as a retryable miss.
            return accessToken
        }
    }

    // MARK: - Account Info

    private func fetchAccountInfo(token: String) async {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                LogManager.shared.log("Dropbox get_current_account failed: HTTP \(code)", type: .error)
                return
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                await MainActor.run {
                    self.isSignedIn = true
                    self.userEmail = json["email"] as? String
                    if let name = json["name"] as? [String: Any] {
                        self.userName = name["display_name"] as? String
                    }
                }
            }
        } catch {
            print("Failed to fetch Dropbox account info: \(error)")
        }
    }
}
