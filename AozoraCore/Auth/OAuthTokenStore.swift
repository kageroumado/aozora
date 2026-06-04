import Foundation

/// Persistent storage for OAuth tokens, one file per service.
///
/// Tokens are stored in `~/.aozora/oauth/<service>.json` with restrictive
/// file permissions (0600). The store handles automatic refresh when the
/// access token is expired and a refresh token is available.
///
/// **Usage:**
/// ```swift
/// let store = OAuthTokenStore(service: "alphaxiv")
/// if let token = try await store.validAccessToken(client: client) {
///     // Use token for API requests
/// }
/// ```
public struct OAuthTokenStore: Sendable {
    /// Stored credential for an OAuth service.
    public struct StoredCredential: Codable, Sendable {
        /// The current access token.
        public var accessToken: String

        /// The refresh token for renewal.
        public var refreshToken: String?

        /// When the access token expires (Unix timestamp).
        public var expiresAt: Double

        /// Scopes that were granted.
        public var scope: String?

        /// When the credential was first created.
        public var createdAt: Double

        /// When the credential was last refreshed.
        public var lastRefreshedAt: Double?

        /// Whether the access token is expired (with 60s buffer).
        public var isExpired: Bool {
            Date().timeIntervalSince1970 >= expiresAt - 60
        }
    }

    /// The service name (used for the file path).
    public let service: String

    /// Path to the token file.
    private var filePath: String {
        NSHomeDirectory() + "/.aozora/oauth/\(service).json"
    }

    public init(service: String) {
        self.service = service
    }

    // MARK: - Read/Write

    /// Load the stored credential, if any.
    public func load() -> StoredCredential? {
        guard let data = FileManager.default.contents(atPath: filePath) else { return nil }
        return try? JSONDecoder().decode(StoredCredential.self, from: data)
    }

    /// Save a credential from a token response.
    public func save(from response: OAuthClient.TokenResponse) throws {
        let credential = StoredCredential(
            accessToken: response.access_token,
            refreshToken: response.refresh_token,
            expiresAt: Date().timeIntervalSince1970 + Double(response.expires_in ?? 86_400),
            scope: response.scope,
            createdAt: Date().timeIntervalSince1970,
        )
        try save(credential)
    }

    /// Save a credential directly.
    public func save(_ credential: StoredCredential) throws {
        let dir = (filePath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONEncoder().encode(credential)
        let url = URL(fileURLWithPath: filePath)
        try data.write(to: url)

        // Restrictive permissions (owner read/write only)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
    }

    /// Delete the stored credential.
    public func delete() {
        try? FileManager.default.removeItem(atPath: filePath)
    }

    // MARK: - Token Access

    /// Get a valid access token, refreshing if expired.
    ///
    /// Returns nil if no credential is stored. Throws if refresh fails.
    ///
    /// - Parameter client: The OAuth client to use for refreshing.
    /// - Returns: A valid access token, or nil if not authenticated.
    public func validAccessToken(client: OAuthClient) async throws -> String? {
        guard var credential = load() else { return nil }

        if !credential.isExpired {
            return credential.accessToken
        }

        // Token expired — try to refresh
        guard let refreshToken = credential.refreshToken else {
            // No refresh token — need to re-authenticate
            delete()
            return nil
        }

        let response = try await client.refreshAccessToken(refreshToken)

        credential.accessToken = response.access_token
        credential.expiresAt = Date().timeIntervalSince1970 + Double(response.expires_in ?? 86_400)
        credential.lastRefreshedAt = Date().timeIntervalSince1970
        if let newRefresh = response.refresh_token {
            credential.refreshToken = newRefresh
        }

        try save(credential)
        return credential.accessToken
    }

    /// Check if a credential exists (may be expired).
    public var hasCredential: Bool {
        load() != nil
    }

    /// Human-readable status for display.
    public var status: String {
        guard let cred = load() else { return "not authenticated" }
        if cred.isExpired {
            return cred.refreshToken != nil ? "expired (can refresh)" : "expired (need re-login)"
        }
        let remaining = Int(cred.expiresAt - Date().timeIntervalSince1970)
        let hours = remaining / 3_600
        let mins = (remaining % 3_600) / 60
        return "authenticated (\(hours)h \(mins)m remaining)"
    }
}
