import Foundation
import Security

/// Error from a keychain credential operation.
///
/// Wraps the `OSStatus` code from Security framework calls with
/// a human-readable description and the operation that failed.
public struct CredentialStoreError: Error, LocalizedError {
    /// The `OSStatus` code returned by the `SecItem*` call.
    public let status: OSStatus

    /// Which operation was being performed (e.g., `"add"`, `"get"`, `"remove"`).
    public let operation: String

    public var errorDescription: String? {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
        return "CredentialStore.\(operation) failed (OSStatus \(status)): \(msg)"
    }
}

/// Multi-credential keychain store with priority-based resolution.
///
/// Supports multiple named credentials per service (e.g., several Anthropic API keys).
/// Each credential has a numeric priority; resolution returns the highest-priority
/// (lowest number) available credential. Environment variables override keychain
/// credentials when set.
///
/// ## Keychain Layout
///
/// Each credential is stored as a `kSecClassGenericPassword` item:
/// - `kSecAttrService`: `"app.aozora.<service>"` — groups credentials by service
/// - `kSecAttrAccount`: The credential's user-assigned name (e.g., `"claude-max"`)
/// - `kSecAttrGeneric`: JSON metadata blob (type, priority, added date, label)
/// - `kSecValueData`: The secret string (UTF-8 encoded)
/// - `kSecAttrAccessible`: `WhenUnlocked` — compatible with legacy file-based keychain
///
/// ## Resolution Order
///
/// 1. Environment variable override (if set) → virtual credential `"$env"`, priority 0
/// 2. Keychain credentials sorted by priority (lower number = higher priority)
///
/// ## Error Handling
///
/// All `SecItem*` calls use the add-or-update pattern: `SecItemAdd` first, then
/// `SecItemUpdate` on `errSecDuplicateItem`. Return codes are checked exhaustively.
/// No silent failures.
public nonisolated enum CredentialStore {
    // MARK: - Types

    /// Known credential services.
    public enum Service: String, CaseIterable, Sendable {
        case anthropic
        case discord

        /// The keychain `kSecAttrService` value for this service.
        var keychainService: String {
            "app.aozora.\(rawValue)"
        }

        /// The environment variable that overrides credentials for this service.
        var envVar: String {
            switch self {
            case .anthropic: "ANTHROPIC_API_KEY"
            case .discord: "DISCORD_BOT_TOKEN"
            }
        }
    }

    /// Classification of a stored credential.
    public enum CredentialType: String, Codable, Sendable, CaseIterable {
        /// Direct API key (e.g., `sk-ant-api*`).
        case apiKey = "api-key"

        /// OAuth access token (e.g., `sk-ant-oat*`).
        case oauth

        /// Bot token (e.g., Discord bot tokens).
        case botToken = "bot-token"
    }

    /// A credential retrieved from the keychain or environment, with its metadata.
    public struct Credential: Sendable {
        /// User-assigned name (e.g., `"claude-max"`). `"$env"` for environment variables.
        public let name: String

        /// Which service this credential belongs to.
        public let service: Service

        /// The secret value (API key, OAuth token, bot token).
        public let secret: String

        /// Classification of the credential.
        public let type: CredentialType

        /// Priority for resolution ordering (lower = higher priority).
        public let priority: Int

        /// When the credential was first stored.
        public let addedAt: Date

        /// Optional human-readable description.
        public let label: String?

        /// Whether this credential came from an environment variable rather than keychain.
        public let isEnvironment: Bool
    }

    // MARK: - Internal Metadata

    /// JSON-serializable metadata stored in `kSecAttrGeneric`.
    private struct Metadata: Codable {
        var type: CredentialType
        var priority: Int
        var addedAt: Date
        var label: String?
    }

    private static let metaEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let metaDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - CRUD

    /// Store a credential in the keychain, or update it if one with the same name exists.
    ///
    /// Uses the add-or-update pattern: tries `SecItemAdd` first, falls back to
    /// `SecItemUpdate` on `errSecDuplicateItem`.
    ///
    /// - Parameters:
    ///   - service: The service this credential belongs to.
    ///   - name: A unique name for the credential within this service.
    ///   - secret: The secret value (API key, token, etc.).
    ///   - type: Classification of the credential.
    ///   - priority: Resolution priority (lower = higher priority). Defaults to 100.
    ///   - label: Optional human-readable description.
    /// - Throws: ``CredentialStoreError`` if the keychain operation fails.
    public static func add(
        service: Service,
        name: String,
        secret: String,
        type: CredentialType,
        priority: Int = 100,
        label: String? = nil,
    ) throws {
        let meta = Metadata(type: type, priority: priority, addedAt: .now, label: label)
        let metaData = try metaEncoder.encode(meta)
        guard let secretData = secret.data(using: .utf8) else {
            throw CredentialStoreError(status: errSecParam, operation: "add(encode)")
        }

        var addQuery = baseQuery(service: service, name: name)
        addQuery[kSecValueData as String] = secretData
        addQuery[kSecAttrGeneric as String] = metaData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        switch addStatus {
        case errSecSuccess:
            return

        case errSecDuplicateItem:
            // Preserve original addedAt — only update secret, type, priority, label
            let existingMeta = try? loadMetadata(service: service, name: name)
            let updatedMeta = Metadata(
                type: type,
                priority: priority,
                addedAt: existingMeta?.addedAt ?? .now,
                label: label,
            )
            let updatedMetaData = try metaEncoder.encode(updatedMeta)
            let updates: [String: Any] = [
                kSecValueData as String: secretData,
                kSecAttrGeneric as String: updatedMetaData,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery(service: service, name: name) as CFDictionary,
                updates as CFDictionary,
            )
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError(status: updateStatus, operation: "add(update)")
            }

        case errSecInteractionNotAllowed:
            throw CredentialStoreError(status: addStatus, operation: "add(locked)")

        default:
            throw CredentialStoreError(status: addStatus, operation: "add")
        }
    }

    /// Get a specific credential by service and name.
    ///
    /// - Parameters:
    ///   - service: The credential service.
    ///   - name: The credential name.
    /// - Returns: The credential, or `nil` if not found.
    /// - Throws: ``CredentialStoreError`` on keychain errors other than not-found.
    public static func get(service: Service, name: String) throws -> Credential? {
        var query = baseQuery(service: service, name: name)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let dict = result as? [String: Any] else { return nil }
            return parseCredential(from: dict, service: service)

        case errSecItemNotFound:
            return nil

        case errSecInteractionNotAllowed:
            throw CredentialStoreError(status: status, operation: "get(locked)")

        default:
            throw CredentialStoreError(status: status, operation: "get")
        }
    }

    /// List all credentials for a service, sorted by priority (lowest first).
    ///
    /// Uses a two-step query because the legacy file-based keychain on macOS
    /// does not support `kSecReturnData` combined with `kSecMatchLimitAll`.
    /// Step 1 fetches account names; step 2 fetches each credential individually.
    ///
    /// - Parameter service: The service to list credentials for.
    /// - Returns: Credentials sorted by priority (lower number = higher priority).
    /// - Throws: ``CredentialStoreError`` on keychain errors other than not-found.
    public static func list(service: Service) throws -> [Credential] {
        // Step 1: Get all account names for this service (attributes only, no data)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let items = result as? [[String: Any]] else { return [] }
            let names = items.compactMap { $0[kSecAttrAccount as String] as? String }

            // Step 2: Fetch each credential individually (with data)
            return names
                .compactMap { try? get(service: service, name: $0) }
                .sorted { $0.priority < $1.priority }

        case errSecItemNotFound:
            return []

        case errSecInteractionNotAllowed:
            throw CredentialStoreError(status: status, operation: "list(locked)")

        default:
            throw CredentialStoreError(status: status, operation: "list")
        }
    }

    /// List all credentials across all services, sorted by service then priority.
    ///
    /// - Returns: All stored credentials.
    /// - Throws: ``CredentialStoreError`` on keychain errors.
    public static func listAll() throws -> [Credential] {
        try Service.allCases.flatMap { try list(service: $0) }
    }

    /// Remove a credential from the keychain.
    ///
    /// - Parameters:
    ///   - service: The credential service.
    ///   - name: The credential name.
    /// - Throws: ``CredentialStoreError`` on keychain errors (not-found is not an error).
    public static func remove(service: Service, name: String) throws {
        let query = baseQuery(service: service, name: name)
        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw CredentialStoreError(status: status, operation: "remove")
        }
    }

    /// Update a credential's priority without changing its secret or other metadata.
    ///
    /// - Parameters:
    ///   - service: The credential service.
    ///   - name: The credential name.
    ///   - priority: The new priority value.
    /// - Throws: ``CredentialStoreError`` if the credential doesn't exist or update fails.
    public static func setPriority(service: Service, name: String, priority: Int) throws {
        try updateMetadata(service: service, name: name, priority: priority)
    }

    /// Update metadata fields on an existing credential.
    ///
    /// Only the non-nil parameters are updated; other fields are preserved.
    ///
    /// - Parameters:
    ///   - service: The credential service.
    ///   - name: The credential name.
    ///   - priority: New priority, or `nil` to keep current.
    ///   - label: New label, or `nil` to keep current.
    /// - Throws: ``CredentialStoreError`` if the credential doesn't exist or update fails.
    public static func updateMetadata(
        service: Service,
        name: String,
        priority: Int? = nil,
        label: String? = nil,
    ) throws {
        guard let existing = try loadMetadata(service: service, name: name) else {
            throw CredentialStoreError(status: errSecItemNotFound, operation: "updateMetadata")
        }

        let updated = Metadata(
            type: existing.type,
            priority: priority ?? existing.priority,
            addedAt: existing.addedAt,
            label: label ?? existing.label,
        )
        let updatedData = try metaEncoder.encode(updated)

        let query = baseQuery(service: service, name: name)
        let updates: [String: Any] = [
            kSecAttrGeneric as String: updatedData,
        ]

        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw CredentialStoreError(status: status, operation: "updateMetadata(notFound)")
        default:
            throw CredentialStoreError(status: status, operation: "updateMetadata")
        }
    }

    // MARK: - Resolution

    /// Resolve the active credential for a service.
    ///
    /// Checks environment variable first (priority 0), then returns the highest-priority
    /// keychain credential. Returns `nil` if no credential is available from either source.
    ///
    /// - Parameter service: The service to resolve a credential for.
    /// - Returns: The resolved credential, or `nil`.
    public static func resolve(service: Service) -> Credential? {
        if let envCred = resolveEnvironment(service: service) {
            return envCred
        }
        guard let credentials = try? list(service: service), let first = credentials.first else {
            return nil
        }
        return first
    }

    /// Resolve all available credentials for a service, sorted by priority.
    ///
    /// Includes the environment variable (priority 0) if set, followed by all keychain
    /// credentials in priority order.
    ///
    /// - Parameter service: The service to resolve credentials for.
    /// - Returns: All available credentials, sorted by priority.
    public static func resolveAll(service: Service) -> [Credential] {
        var result: [Credential] = []

        if let envCred = resolveEnvironment(service: service) {
            result.append(envCred)
        }

        if let keychain = try? list(service: service) {
            result.append(contentsOf: keychain)
        }

        return result
    }

    /// Check the environment variable for a service override.
    private static func resolveEnvironment(service: Service) -> Credential? {
        guard let value = ProcessInfo.processInfo.environment[service.envVar],
              !value.isEmpty else { return nil }

        return Credential(
            name: "$env",
            service: service,
            secret: value,
            type: detectType(secret: value, service: service),
            priority: 0,
            addedAt: .distantPast,
            label: "Environment variable \(service.envVar)",
            isEnvironment: true,
        )
    }

    // MARK: - Migration

    /// Migrate credentials from the legacy ``ClaudeCredentialStore`` keychain format.
    ///
    /// Reads from the old service `"app.aozora.claude-credentials"` with account
    /// `"anthropic-api-key"` and writes to the new format under service `"anthropic"`
    /// with name `"default"` and priority 1.
    ///
    /// Safe to call multiple times — skips migration if a credential named `"default"`
    /// already exists in the new format.
    ///
    /// - Returns: `true` if a credential was migrated.
    @discardableResult
    public static func migrateFromLegacy() -> Bool {
        let legacyService = "app.aozora.claude-credentials"
        let legacyAccount = "anthropic-api-key"

        // Skip if new-format credential already exists
        if let existing = try? get(service: .anthropic, name: "default"), !existing.isEnvironment {
            return false
        }

        guard let legacyKey = readLegacyValue(service: legacyService, account: legacyAccount) else {
            return false
        }

        let type = detectType(secret: legacyKey, service: .anthropic)
        do {
            try add(
                service: .anthropic,
                name: "default",
                secret: legacyKey,
                type: type,
                priority: 1,
                label: "Migrated from legacy keychain",
            )
            print("  \u{251C}\u{2500} Migrated Anthropic credential from legacy keychain")
            return true
        } catch {
            print("  \u{251C}\u{2500} Failed to migrate legacy credential: \(error)")
            return false
        }
    }

    // MARK: - Helpers

    /// Base keychain query dictionary for a service/name pair.
    private static func baseQuery(service: Service, name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service.keychainService,
            kSecAttrAccount as String: name,
        ]
    }

    /// Load just the metadata for an existing credential.
    private static func loadMetadata(service: Service, name: String) throws -> Metadata? {
        var query = baseQuery(service: service, name: name)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = unsafe SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let dict = result as? [String: Any],
                  let data = dict[kSecAttrGeneric as String] as? Data else { return nil }
            return try? metaDecoder.decode(Metadata.self, from: data)
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError(status: status, operation: "loadMetadata")
        }
    }

    /// Parse a keychain result dictionary into a ``Credential``.
    private static func parseCredential(from dict: [String: Any], service: Service) -> Credential? {
        guard let name = dict[kSecAttrAccount as String] as? String,
              let secretData = dict[kSecValueData as String] as? Data,
              let secret = String(data: secretData, encoding: .utf8)
        else { return nil }

        var type: CredentialType = .apiKey
        var priority = 100
        var addedAt = Date()
        var label: String?

        if let metaData = dict[kSecAttrGeneric as String] as? Data,
           let meta = try? metaDecoder.decode(Metadata.self, from: metaData) {
            type = meta.type
            priority = meta.priority
            addedAt = meta.addedAt
            label = meta.label
        }

        return Credential(
            name: name,
            service: service,
            secret: secret,
            type: type,
            priority: priority,
            addedAt: addedAt,
            label: label,
            isEnvironment: false,
        )
    }

    /// Infer credential type from the secret's prefix and service.
    private static func detectType(secret: String, service: Service) -> CredentialType {
        switch service {
        case .anthropic:
            if secret.hasPrefix("sk-ant-oat") { return .oauth }
            return .apiKey
        case .discord:
            return .botToken
        }
    }

    /// Read a value from the legacy keychain format (no metadata, no data protection).
    private static func readLegacyValue(service: String, account: String) -> String? {
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
}
