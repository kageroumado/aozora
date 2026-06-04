import Foundation
#if canImport(CryptoKit)
    import CryptoKit
#endif

/// Generic OAuth 2.0 client with PKCE support.
///
/// Handles the authorization code flow: generates authorization URLs with PKCE,
/// exchanges codes for tokens, and refreshes expired tokens. Works with any
/// OAuth 2.0 provider (Clerk, Auth0, etc.).
///
/// **Flow:**
/// 1. Call ``authorize()`` to get a URL + start the callback server
/// 2. User opens URL in browser, completes login
/// 3. Provider redirects to localhost callback with authorization code
/// 4. Client exchanges code for access + refresh tokens
/// 5. Tokens are stored via ``OAuthTokenStore``
public struct OAuthClient: Sendable {
    /// Configuration for an OAuth service.
    public struct ServiceConfig: Codable, Sendable {
        /// Human-readable service name (e.g., "alphaxiv").
        public let name: String

        /// OAuth authorization endpoint.
        public let authorizeURL: String

        /// OAuth token endpoint.
        public let tokenURL: String

        /// Client ID (registered with the provider).
        public let clientID: String

        /// Client secret (optional — not needed for public clients with PKCE).
        public let clientSecret: String?

        /// Requested scopes (space-separated).
        public let scopes: String

        /// Local callback port for the redirect URI.
        public let callbackPort: Int

        /// The redirect URI (computed from callbackPort).
        public var redirectURI: String {
            "http://127.0.0.1:\(callbackPort)/oauth/callback"
        }

        public init(
            name: String,
            authorizeURL: String,
            tokenURL: String,
            clientID: String,
            clientSecret: String? = nil,
            scopes: String = "profile email",
            callbackPort: Int = 19_876,
        ) {
            self.name = name
            self.authorizeURL = authorizeURL
            self.tokenURL = tokenURL
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.scopes = scopes
            self.callbackPort = callbackPort
        }
    }

    /// Errors that can occur during the OAuth flow.
    public enum OAuthError: Error, CustomStringConvertible {
        case invalidURL(String)
        case tokenExchangeFailed(String)
        case refreshFailed(String)
        case callbackTimeout
        case userDenied(String)
        case networkError(String)

        public var description: String {
            switch self {
            case let .invalidURL(url): "Invalid URL: \(url)"
            case let .tokenExchangeFailed(msg): "Token exchange failed: \(msg)"
            case let .refreshFailed(msg): "Token refresh failed: \(msg)"
            case .callbackTimeout: "Authorization timed out — user didn't complete login within 5 minutes"
            case let .userDenied(msg): "User denied authorization: \(msg)"
            case let .networkError(msg): "Network error: \(msg)"
            }
        }
    }

    /// Token response from the OAuth provider.
    public struct TokenResponse: Codable, Sendable {
        public let access_token: String
        public let refresh_token: String?
        public let expires_in: Int?
        public let token_type: String?
        public let scope: String?
    }

    private let config: ServiceConfig

    public init(config: ServiceConfig) {
        self.config = config
    }

    // MARK: - Authorization

    /// Generate a PKCE code verifier and challenge.
    ///
    /// Returns (verifier, challenge) where the verifier is stored locally
    /// and the challenge is sent to the provider in the authorization URL.
    public static func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()

        let challengeData = Data(SHA256.hash(data: Data(verifier.utf8)))
        let challenge = challengeData.base64URLEncoded()

        return (verifier, challenge)
    }

    /// Build the authorization URL with PKCE parameters.
    ///
    /// - Parameters:
    ///   - state: Random state parameter for CSRF protection.
    ///   - challenge: PKCE code challenge (S256).
    /// - Returns: The full authorization URL to open in a browser.
    public func buildAuthorizeURL(state: String, challenge: String) throws -> URL {
        guard var components = URLComponents(string: config.authorizeURL) else {
            throw OAuthError.invalidURL(config.authorizeURL)
        }

        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "scope", value: config.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]

        guard let url = components.url else {
            throw OAuthError.invalidURL("Failed to build authorization URL")
        }

        return url
    }

    // MARK: - Token Exchange

    /// Exchange an authorization code for tokens.
    ///
    /// - Parameters:
    ///   - code: The authorization code from the callback.
    ///   - verifier: The PKCE code verifier (generated during authorization).
    /// - Returns: The token response with access + refresh tokens.
    public func exchangeCode(_ code: String, verifier: String) async throws -> TokenResponse {
        guard let url = URL(string: config.tokenURL) else {
            throw OAuthError.invalidURL(config.tokenURL)
        }

        var body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "redirect_uri": config.redirectURI,
            "code_verifier": verifier,
        ]

        if let secret = config.clientSecret {
            body["client_secret"] = secret
        }

        return try await postTokenRequest(url: url, body: body)
    }

    /// Refresh an expired access token using the refresh token.
    ///
    /// - Parameter refreshToken: The refresh token from the initial authorization.
    /// - Returns: A new token response with a fresh access token.
    public func refreshAccessToken(_ refreshToken: String) async throws -> TokenResponse {
        guard let url = URL(string: config.tokenURL) else {
            throw OAuthError.invalidURL(config.tokenURL)
        }

        var body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": config.clientID,
            "refresh_token": refreshToken,
        ]

        if let secret = config.clientSecret {
            body["client_secret"] = secret
        }

        return try await postTokenRequest(url: url, body: body)
    }

    // MARK: - HTTP

    private func postTokenRequest(url: URL, body: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let encoded = body.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }.joined(separator: "&")
        request.httpBody = encoded.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OAuthError.networkError("Invalid response type")
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("access_denied") || body.contains("user_denied") {
                throw OAuthError.userDenied(body)
            }
            throw OAuthError.tokenExchangeFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed("Failed to decode response: \(body)")
        }
    }
}

// MARK: - Data Extensions

extension Data {
    /// Base64 URL-safe encoding (no padding, URL-safe characters).
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
