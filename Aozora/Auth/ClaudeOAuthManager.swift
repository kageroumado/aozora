import AozoraCore
import CryptoKit
import Foundation
import OSLog

/// Logger for OAuth operations.
private let logger = Logger(subsystem: "app.aozora", category: "oauth")

/// Manages PKCE OAuth flow with Anthropic's authorization server.
///
/// Presents a WKWebView for the user to sign in to Claude, intercepts
/// the OAuth callback, exchanges the authorization code for tokens,
/// and stores them in the Keychain.
@MainActor
final class ClaudeOAuthManager {
    // MARK: - Constants

    /// Anthropic OAuth client ID (shared with Claude Code Chrome extension).
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Authorization endpoint URL.
    static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!

    /// Token exchange endpoint URL.
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    /// OAuth redirect URI for code callback.
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"

    /// OAuth scopes requested during authorization.
    static let scopes = "org:create_api_key user:profile user:inference"

    // MARK: - State

    /// Whether an OAuth flow is currently in progress.
    private(set) var isAuthenticating = false

    /// Error from the last auth attempt, if any.
    private(set) var authError: String?

    /// PKCE verifier for the current flow.
    private var codeVerifier: String?

    // MARK: - PKCE

    /// Generates a cryptographically random PKCE code verifier.
    ///
    /// - Returns: A base64url-encoded 32-byte random string.
    private func generateCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = unsafe SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    /// Computes the S256 PKCE code challenge from a verifier.
    ///
    /// - Parameter verifier: The code verifier string.
    /// - Returns: The base64url-encoded SHA-256 hash of the verifier.
    private func computeCodeChallenge(from verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    /// Builds the full authorization URL with PKCE challenge parameters.
    ///
    /// Generates a new code verifier and stores it for later token exchange.
    ///
    /// - Returns: The complete authorization URL to load in a web view.
    func buildAuthorizeURL() -> URL {
        let verifier = generateCodeVerifier()
        codeVerifier = verifier
        let challenge = computeCodeChallenge(from: verifier)

        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier),
        ]

        return components.url!
    }

    /// Handles an OAuth callback URL by extracting the authorization code and exchanging it for tokens.
    ///
    /// - Parameter url: The callback URL intercepted from the web view navigation.
    /// - Returns: `true` if the URL was recognized as an OAuth callback, `false` otherwise.
    func handleCallback(url: URL) async -> Bool {
        guard url.absoluteString.hasPrefix(Self.redirectURI) else { return false }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        guard var code = components?.queryItems?.first(where: { $0.name == "code" })?.value else {
            authError = "No authorization code in callback"
            isAuthenticating = false
            return true
        }

        var state: String?
        if let hashIndex = code.firstIndex(of: "#") {
            state = String(code[code.index(after: hashIndex)...])
            code = String(code[code.startIndex ..< hashIndex])
        }
        if state == nil {
            state = components?.queryItems?.first(where: { $0.name == "state" })?.value
        }

        await exchangeCodeForTokens(code: code, state: state ?? "")
        return true
    }

    /// Exchanges an authorization code for access and refresh tokens.
    ///
    /// On success, stores the tokens in ``ClaudeCredentialStore``.
    ///
    /// - Parameters:
    ///   - code: The authorization code from the callback.
    ///   - state: The state parameter from the callback.
    private func exchangeCodeForTokens(code: String, state: String) async {
        guard let verifier = codeVerifier else {
            authError = "Missing PKCE verifier"
            isAuthenticating = false
            return
        }

        isAuthenticating = true
        authError = nil

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Self.clientId,
            "code": code,
            "state": state,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                authError = "Invalid response from token endpoint"
                isAuthenticating = false
                return
            }

            guard httpResponse.statusCode == 200 else {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                logger.error("Token exchange failed (\(httpResponse.statusCode)): \(errorBody)")
                authError = "Token exchange failed (\(httpResponse.statusCode))"
                isAuthenticating = false
                return
            }

            let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)

            let expiresAt = Date.now.addingTimeInterval(TimeInterval(tokenResponse.expires_in))
            ClaudeCredentialStore.storeOAuthTokens(
                access: tokenResponse.access_token,
                refresh: tokenResponse.refresh_token,
                expiresAt: expiresAt,
            )

            logger.info("OAuth token exchange succeeded, expires at \(expiresAt)")
            isAuthenticating = false
            codeVerifier = nil

        } catch {
            logger.error("Token exchange error: \(error.localizedDescription)")
            authError = "Token exchange failed: \(error.localizedDescription)"
            isAuthenticating = false
        }
    }

    /// Refreshes an expired access token using a refresh token.
    ///
    /// On success, stores the new tokens in ``ClaudeCredentialStore``.
    ///
    /// - Parameter refreshToken: The refresh token to use.
    /// - Returns: The new token set, or `nil` if refresh failed.
    static func refreshToken(refreshToken: String) async -> OAuthTokens? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let tokenResponse = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
            let expiresAt = Date.now.addingTimeInterval(TimeInterval(tokenResponse.expires_in))

            ClaudeCredentialStore.storeOAuthTokens(
                access: tokenResponse.access_token,
                refresh: tokenResponse.refresh_token,
                expiresAt: expiresAt,
            )

            return OAuthTokens(
                accessToken: tokenResponse.access_token,
                refreshToken: tokenResponse.refresh_token,
                expiresAt: expiresAt,
            )
        } catch {
            return nil
        }
    }
}

/// Response from Anthropic's OAuth token endpoint.
private struct OAuthTokenResponse: Decodable {
    /// The access token for API authentication.
    let access_token: String

    /// The refresh token for obtaining new access tokens.
    let refresh_token: String

    /// Token lifetime in seconds.
    let expires_in: Int

    /// The token type (typically "bearer").
    let token_type: String
}

private extension Data {
    /// Returns a base64url-encoded string (RFC 4648 Section 5).
    ///
    /// Replaces `+` with `-`, `/` with `_`, and strips padding `=` characters.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
