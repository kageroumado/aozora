import Foundation
import Security

/// Keychain-backed credential store for Anthropic API authentication.
///
/// Handles both API key and OAuth token storage. Credentials are stored
/// in the macOS Keychain, not in UserDefaults or files.
///
/// > Deprecated: Use ``CredentialStore`` instead, which supports multiple named
/// > credentials with priority-based resolution and environment variable overrides.
/// > This type is retained for the macOS app's OAuth flow and legacy migration.
@available(*, deprecated, message: "Use CredentialStore instead")
public nonisolated enum ClaudeCredentialStore {
    private static let service = "app.aozora.claude-credentials"
    private static let apiKeyAccount = "anthropic-api-key"
    private static let oauthAccessAccount = "anthropic-oauth-access"
    private static let oauthRefreshAccount = "anthropic-oauth-refresh"
    private static let oauthExpiryAccount = "anthropic-oauth-expiry"

    // MARK: - API Key

    /// Stores an API key in the Keychain, replacing any existing one.
    public static func storeAPIKey(_ key: String) {
        setKeychainValue(key, account: apiKeyAccount)
    }

    /// Loads the stored API key from the Keychain, if one exists.
    public static func loadAPIKey() -> String? {
        getKeychainValue(account: apiKeyAccount)
    }

    /// Deletes the stored API key from the Keychain.
    public static func deleteAPIKey() {
        deleteKeychainValue(account: apiKeyAccount)
    }

    // MARK: - OAuth Tokens

    /// Stores a complete OAuth token set in the Keychain.
    ///
    /// Each component (access token, refresh token, expiry) is stored as a
    /// separate Keychain item under the same service.
    ///
    /// - Parameters:
    ///   - access: The OAuth access token.
    ///   - refresh: The OAuth refresh token.
    ///   - expiresAt: When the access token expires.
    public static func storeOAuthTokens(access: String, refresh: String, expiresAt: Date) {
        setKeychainValue(access, account: oauthAccessAccount)
        setKeychainValue(refresh, account: oauthRefreshAccount)
        setKeychainValue(String(expiresAt.timeIntervalSince1970), account: oauthExpiryAccount)
    }

    /// Loads the stored OAuth tokens from the Keychain.
    ///
    /// - Returns: The token set, or `nil` if any component is missing.
    public static func loadOAuthTokens() -> OAuthTokens? {
        guard let access = getKeychainValue(account: oauthAccessAccount),
              let refresh = getKeychainValue(account: oauthRefreshAccount),
              let expiryString = getKeychainValue(account: oauthExpiryAccount),
              let expiryInterval = TimeInterval(expiryString)
        else { return nil }

        return OAuthTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: Date(timeIntervalSince1970: expiryInterval),
        )
    }

    /// Deletes all stored OAuth tokens from the Keychain.
    public static func deleteOAuthTokens() {
        deleteKeychainValue(account: oauthAccessAccount)
        deleteKeychainValue(account: oauthRefreshAccount)
        deleteKeychainValue(account: oauthExpiryAccount)
    }

    // MARK: - Unified Credential

    /// Returns the active credential based on what's stored.
    ///
    /// Checks OAuth first (preferred), falls back to API key.
    public static func activeCredential() -> ClaudeCredential? {
        if let tokens = loadOAuthTokens() {
            return .oauthToken(tokens.accessToken, refresh: tokens.refreshToken, expiresAt: tokens.expiresAt)
        }
        if let apiKey = loadAPIKey() {
            return .apiKey(apiKey)
        }
        return nil
    }

    /// Whether any credential is stored.
    public static var hasCredential: Bool {
        activeCredential() != nil
    }

    /// Deletes all stored credentials (both API key and OAuth tokens).
    public static func deleteAll() {
        deleteAPIKey()
        deleteOAuthTokens()
    }

    // MARK: - Keychain Helpers

    /// Stores a string value in the Keychain under the given account.
    ///
    /// Deletes any existing item first, then adds the new value.
    ///
    /// - Parameters:
    ///   - value: The string value to store.
    ///   - account: The Keychain account identifier.
    private static func setKeychainValue(_ value: String, account: String) {
        guard let data = value.data(using: .utf8) else { return }

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    /// Retrieves a string value from the Keychain for the given account.
    ///
    /// - Parameter account: The Keychain account identifier.
    /// - Returns: The stored string, or `nil` if not found.
    private static func getKeychainValue(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Deletes a Keychain item for the given account.
    ///
    /// - Parameter account: The Keychain account identifier.
    private static func deleteKeychainValue(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Types

/// OAuth token set returned from Anthropic's authorization server.
public nonisolated struct OAuthTokens: Sendable {
    /// The access token used to authenticate API requests.
    public let accessToken: String

    /// The refresh token used to obtain new access tokens.
    public let refreshToken: String

    /// When the access token expires.
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// Whether the access token has expired.
    public var isExpired: Bool {
        Date.now >= expiresAt
    }

    /// Whether the token expires within the given interval.
    ///
    /// - Parameter interval: The time interval to check against.
    /// - Returns: `true` if the token will expire within the interval.
    public func expiresWithin(_ interval: TimeInterval) -> Bool {
        Date.now.addingTimeInterval(interval) >= expiresAt
    }
}

/// Unified credential type for Anthropic API authentication.
///
/// Supports both direct API key authentication and OAuth token-based
/// authentication. OAuth is preferred when available.
public nonisolated enum ClaudeCredential: Sendable {
    /// Direct API key authentication.
    case apiKey(String)

    /// OAuth token-based authentication with refresh capability.
    case oauthToken(String, refresh: String, expiresAt: Date)

    /// Whether this credential uses OAuth authentication.
    public var isOAuth: Bool {
        if case .oauthToken = self { return true }
        return false
    }

    /// The token string for API requests.
    ///
    /// Returns the API key for `.apiKey` credentials, or the access
    /// token for `.oauthToken` credentials.
    public var token: String {
        switch self {
        case let .apiKey(key): key
        case let .oauthToken(access, _, _): access
        }
    }
}
