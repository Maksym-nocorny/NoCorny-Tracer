import Foundation
import AuthenticationServices
import AppKit
import CryptoKit

/// Manages Google OAuth2 authentication for Drive access without using the Google Sign-In SDK
@Observable
final class GoogleAuthManager: NSObject {
    // MARK: - State
    var isSignedIn = false
    var userName: String?
    var userEmail: String?
    var userPhotoURL: URL?
    var accessToken: String?
    var isLoading = false
    var errorMessage: String?

    // MARK: - Configuration
    private let clientID = AppSecrets.googleClientID
    private let driveScope = "https://www.googleapis.com/auth/drive.file"
    private let emailScope = "email"
    private let profileScope = "profile"
    
    private var redirectURI: String {
        "com.googleusercontent.apps." + clientID.components(separatedBy: ".").first! + ":/oauth2callback"
    }

    /// Whether real Google credentials have been configured
    var isConfigured: Bool {
        !clientID.contains("YOUR_GOOGLE_CLIENT_ID")
    }

    // UserDefaults keys
    private let tokenKey = "GoogleAuthAccessToken"
    private let refreshTokenKey = "GoogleAuthRefreshToken"
    private let expiresAtKey = "GoogleAuthTokenExpiry"

    private var authSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        restorePreviousSignIn()
    }

    // MARK: - Sign In
    func signIn() {
        guard isConfigured else {
            errorMessage = "Google Client ID not configured."
            return
        }

        isLoading = true
        errorMessage = nil

        let codeVerifier = generateCodeVerifier()
        let codeChallenge = generateCodeChallenge(verifier: codeVerifier)
        
        var comp = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "\(driveScope) \(emailScope) \(profileScope)"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        
        guard let authURL = comp.url else {
            errorMessage = "Failed to construct auth URL"
            isLoading = false
            return
        }
        
        let scheme = redirectURI.components(separatedBy: ":").first!
        
        authSession = ASWebAuthenticationSession(url: authURL, callbackURLScheme: scheme) { [weak self] callbackURL, error in
            print("Auth session returned callback: \(String(describing: callbackURL)), error: \(String(describing: error))")
            
            DispatchQueue.main.async {
                self?.isLoading = false
                if let error = error {
                    if let asError = error as? ASWebAuthenticationSessionError, asError.code == .canceledLogin {
                        // User canceled, no error message needed
                    } else {
                        self?.errorMessage = error.localizedDescription
                    }
                    return
                }
                
                guard let callbackURL = callbackURL,
                      let comp = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = comp.queryItems?.first(where: { $0.name == "code" })?.value else {
                    self?.errorMessage = "Invalid callback URL"
                    return
                }
                
                self?.exchangeCodeForToken(code: code, codeVerifier: codeVerifier)
            }
        }
        
        authSession?.presentationContextProvider = self
        // This makes it skip the permission alert if possible, or shows it anchored to the window
        authSession?.prefersEphemeralWebBrowserSession = false
        
        if authSession?.start() == false {
            errorMessage = "Failed to start authentication session."
            isLoading = false
        }
    }

    // MARK: - Sign Out
    func signOut() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: expiresAtKey)
        
        isSignedIn = false
        userName = nil
        userEmail = nil
        userPhotoURL = nil
        accessToken = nil
    }

    // MARK: - Restore Session
    private func restorePreviousSignIn() {
        guard isConfigured,
              let _ = UserDefaults.standard.string(forKey: refreshTokenKey) else { return }
        
        Task {
            if let token = await refreshTokenIfNeeded() {
                self.accessToken = token
                await fetchUserInfo(token: token)
            }
        }
    }

    // MARK: - Token Refresh
    func refreshTokenIfNeeded() async -> String? {
        guard let refreshToken = UserDefaults.standard.string(forKey: refreshTokenKey) else { return nil }
        
        // Check if token is still valid (add 5 min buffer)
        if let expiry = UserDefaults.standard.object(forKey: expiresAtKey) as? Date,
           let currentToken = UserDefaults.standard.string(forKey: tokenKey),
           Date().addingTimeInterval(300) < expiry {
            return currentToken
        }
        
        var comp = URLComponents(string: "https://oauth2.googleapis.com/token")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        
        var request = URLRequest(url: comp.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let newAccessToken = json["access_token"] as? String {
                
                if let expiresIn = json["expires_in"] as? TimeInterval {
                    UserDefaults.standard.set(Date().addingTimeInterval(expiresIn), forKey: expiresAtKey)
                }
                UserDefaults.standard.set(newAccessToken, forKey: tokenKey)
                
                DispatchQueue.main.async {
                    self.accessToken = newAccessToken
                }
                return newAccessToken
            }
        } catch {
            print("Failed to refresh token: \(error)")
        }
        
        return nil
    }

    // MARK: - Private API Calls
    private func exchangeCodeForToken(code: String, codeVerifier: String) {
        isLoading = true
        var comp = URLComponents(string: "https://oauth2.googleapis.com/token")!
        comp.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: codeVerifier),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        
        var request = URLRequest(url: comp.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
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
                        if let errorMsg = json["error_description"] as? String ?? json["error"] as? String {
                            self?.errorMessage = errorMsg
                            return
                        }
                        
                        guard let token = json["access_token"] as? String else {
                            self?.errorMessage = "No access token in response"
                            return
                        }
                        
                        // Save tokens
                        UserDefaults.standard.set(token, forKey: self?.tokenKey ?? "")
                        if let refreshToken = json["refresh_token"] as? String {
                            UserDefaults.standard.set(refreshToken, forKey: self?.refreshTokenKey ?? "")
                        }
                        if let expiresIn = json["expires_in"] as? TimeInterval {
                            UserDefaults.standard.set(Date().addingTimeInterval(expiresIn), forKey: self?.expiresAtKey ?? "")
                        }
                        
                        self?.accessToken = token
                        
                        // Fetch user info
                        Task { [weak self] in
                            await self?.fetchUserInfo(token: token)
                        }
                    }
                } catch {
                    self?.errorMessage = "Failed to parse token response"
                }
            }
        }.resume()
    }
    
    private func fetchUserInfo(token: String) async {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                DispatchQueue.main.async {
                    self.isSignedIn = true
                    self.userEmail = json["email"] as? String
                    self.userName = json["name"] as? String
                    if let picURL = json["picture"] as? String {
                        self.userPhotoURL = URL(string: picURL)
                    }
                }
            }
        } catch {
            print("Failed to fetch user info: \(error)")
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
            .trimmingCharacters(in: .whitespaces)
    }

    private func generateCodeChallenge(verifier: String) -> String {
        let data = verifier.data(using: .utf8)!
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding
extension GoogleAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Return the main window if available, otherwise a generic empty window
        return NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}
