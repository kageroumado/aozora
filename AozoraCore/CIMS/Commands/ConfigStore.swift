import Foundation

// MARK: - Config Keys

/// All configurable settings for the CIMS architecture.
///
/// Each key has a default value from ``CIMSDefaults``, a type, and a human-readable description.
/// Settings are persisted to a JSON file and loaded on startup.
public nonisolated enum ConfigKey: String, CaseIterable, Sendable {
    // Model
    case executiveModel = "model.executive"
    case workerModel = "model.worker"
    case consolidationModel = "model.consolidation"

    // Context
    case contextBudget = "context.budget"
    case protectedTailCount = "context.protectedTailCount"
    case retrievalBudget = "context.retrievalBudget"
    case contextSoftThreshold = "context.softThreshold"
    case contextHardThreshold = "context.hardThreshold"
    case contextMaxPassesPerTurn = "context.maxPassesPerTurn"

    // Observer
    case observerEnabled = "observer.enabled"
    case observerCycleInterval = "observer.cycleIntervalSeconds"
    case observerInjectionStrength = "observer.injectionStrength"
    case observerNoveltyInterval = "observer.noveltyCycleInterval"

    /// Heartbeat
    case heartbeatIntervalMinutes = "heartbeat.intervalMinutes"

    /// Consolidation
    case consolidationIdleTimeout = "consolidation.idleTimeoutMinutes"

    /// Allostasis
    case allostasisEnabled = "allostasis.enabled"

    // Provider
    case providerMaxTokens = "provider.maxTokens"
    case providerThinking = "provider.thinking"
    case providerEffort = "provider.effort"
    case providerMaxRetries = "provider.maxRetries"

    /// Tool backgrounding
    case toolBackgroundTimeout = "tool.backgroundTimeoutSeconds"

    // Daemon
    case daemonDiscordUserId = "daemon.discordUserId"
    case daemonGuildId = "daemon.guildId"

    /// Skills
    case skillPaths = "skills.paths"

    /// Agents
    case agentDirectory = "agents.directory"

    /// Provider Failover
    /// Comma-separated fallback model IDs tried in order when the primary fails.
    case providerFallbackChain = "provider.fallbackChain"

    /// Deploy
    /// Code-signing identity for self-rebuilds (empty = ad-hoc signing).
    case deploySigningIdentity = "deploy.signingIdentity"

    /// Coalescer
    /// Debounce window in milliseconds for message coalescing.
    case coalescerDebounceMs = "coalescer.debounceMs"
    /// Maximum messages per coalesced batch.
    case coalescerMaxBatchSize = "coalescer.maxBatchSize"
    /// Maximum total messages before overflow summarization.
    case coalescerOverflowCap = "coalescer.overflowCap"

    /// Proactive Outreach
    /// Whether proactive outreach is enabled.
    case proactiveEnabled = "proactive.enabled"
    /// Interval in minutes between proactive outreach checks.
    case proactiveIntervalMinutes = "proactive.intervalMinutes"
    /// Quiet hours start (24h format, e.g., "23").
    case proactiveQuietStart = "proactive.quietStart"
    /// Quiet hours end (24h format, e.g., "8").
    case proactiveQuietEnd = "proactive.quietEnd"
    /// Hours of silence before check-in (0 = disabled).
    case proactiveSilenceThresholdHours = "proactive.silenceThresholdHours"
    /// TCP port for the WebSocket IPC server.
    case wsPort = "ipc.wsPort"

    public var description: String {
        switch self {
        case .executiveModel: "Model for coordinator inference (e.g., claude-opus-4-6)"
        case .workerModel: "Model for worker tasks (e.g., claude-sonnet-4-6)"
        case .consolidationModel: "Model for offline consolidation"
        case .contextBudget: "Total token budget for assembled context"
        case .protectedTailCount: "Number of recent meaningful messages kept verbatim"
        case .retrievalBudget: "Max summary nodes to retrieve per turn"
        case .contextSoftThreshold: "Frontier token count triggering async compaction"
        case .contextHardThreshold: "Assembled context token count triggering blocking compaction"
        case .contextMaxPassesPerTurn: "Maximum compaction passes per pressure-gated cycle"
        case .observerEnabled: "Whether the subcortical observer is active"
        case .observerCycleInterval: "Observer cycle interval in seconds"
        case .observerInjectionStrength: "Plate injection strength (β)"
        case .observerNoveltyInterval: "Cycles between novelty injections"
        case .heartbeatIntervalMinutes: "Minutes between heartbeat checks"
        case .consolidationIdleTimeout: "Minutes of idle before consolidation runs"
        case .allostasisEnabled: "Whether allostatic mode switching is active"
        case .providerMaxTokens: "Maximum output tokens per completion"
        case .providerThinking: "Thinking mode: disabled, adaptive, or token budget (integer)"
        case .providerEffort: "Model effort level: low, medium, high"
        case .providerMaxRetries: "Maximum retry attempts for transient API errors"
        case .toolBackgroundTimeout: "Seconds before a tool call moves to background"
        case .deploySigningIdentity: "Code-signing identity for self-rebuilds (empty = ad-hoc)"
        case .daemonDiscordUserId: "Discord user ID of the primary user (for DM notifications)"
        case .daemonGuildId: "Discord guild ID filter (empty = DMs only)"
        case .skillPaths: "Comma-separated directories to search for skills"
        case .agentDirectory: "Directory containing agent definition JSON files"
        case .providerFallbackChain: "Comma-separated fallback model IDs (e.g., gpt-4o,claude-sonnet-4-6)"
        case .coalescerDebounceMs: "Debounce window in milliseconds for message coalescing"
        case .coalescerMaxBatchSize: "Maximum messages per coalesced batch"
        case .coalescerOverflowCap: "Maximum total messages before overflow summarization"
        case .proactiveEnabled: "Whether proactive outreach is enabled"
        case .proactiveIntervalMinutes: "Minutes between proactive outreach checks"
        case .proactiveQuietStart: "Quiet hours start (24h format, e.g., 23)"
        case .proactiveQuietEnd: "Quiet hours end (24h format, e.g., 8)"
        case .proactiveSilenceThresholdHours: "Hours of silence before check-in (0 = disabled)"
        case .wsPort: "TCP port for WebSocket IPC server (default 19877)"
        }
    }

    public var defaultValue: String {
        switch self {
        case .executiveModel: "claude-opus-4-6"
        case .workerModel: "claude-sonnet-4-6"
        case .consolidationModel: "claude-sonnet-4-6"
        case .contextBudget: "\(CIMSDefaults.defaultContextBudget)"
        case .protectedTailCount: "\(CIMSDefaults.protectedTailCount)"
        case .retrievalBudget: "\(CIMSDefaults.defaultRetrievalBudget)"
        case .contextSoftThreshold: "\(CIMSDefaults.softThreshold)"
        case .contextHardThreshold: "\(CIMSDefaults.hardThreshold)"
        case .contextMaxPassesPerTurn: "5"
        case .observerEnabled: "true"
        case .observerCycleInterval: "\(CIMSDefaults.observerDefaultCycleInterval)"
        case .observerInjectionStrength: "\(CIMSDefaults.observerInjectionStrength)"
        case .observerNoveltyInterval: "\(CIMSDefaults.observerNoveltyCycleInterval)"
        case .heartbeatIntervalMinutes: "4"
        case .consolidationIdleTimeout: "15"
        case .allostasisEnabled: "true"
        case .providerMaxTokens: "32000"
        case .providerThinking: "adaptive"
        case .providerEffort: "high"
        case .providerMaxRetries: "5"
        case .toolBackgroundTimeout: "\(CIMSDefaults.toolBackgroundTimeout)"
        case .deploySigningIdentity: ""
        case .daemonDiscordUserId: ""
        case .daemonGuildId: ""
        case .skillPaths: "~/.aozora/skills"
        case .agentDirectory: "~/.aozora/agents"
        case .providerFallbackChain: ""
        case .coalescerDebounceMs: "1500"
        case .coalescerMaxBatchSize: "20"
        case .coalescerOverflowCap: "50"
        case .proactiveEnabled: "false"
        case .proactiveIntervalMinutes: "240"
        case .proactiveQuietStart: "23"
        case .proactiveQuietEnd: "8"
        case .proactiveSilenceThresholdHours: "0"
        case .wsPort: "19877"
        }
    }

    public var valueType: ConfigValueType {
        switch self {
        case .executiveModel, .workerModel, .consolidationModel,
             .providerThinking, .providerEffort,
             .daemonDiscordUserId, .daemonGuildId,
             .skillPaths, .agentDirectory,
             .providerFallbackChain,
             .deploySigningIdentity:
            .string
        case .contextBudget, .protectedTailCount, .retrievalBudget,
             .contextSoftThreshold, .contextHardThreshold, .contextMaxPassesPerTurn,
             .observerCycleInterval, .observerNoveltyInterval,
             .heartbeatIntervalMinutes, .consolidationIdleTimeout,
             .providerMaxTokens, .providerMaxRetries,
             .toolBackgroundTimeout,
             .coalescerDebounceMs, .coalescerMaxBatchSize, .coalescerOverflowCap,
             .proactiveIntervalMinutes, .proactiveQuietStart, .proactiveQuietEnd,
             .proactiveSilenceThresholdHours,
             .wsPort:
            .integer
        case .observerInjectionStrength:
            .double
        case .observerEnabled, .allostasisEnabled,
             .proactiveEnabled:
            .boolean
        }
    }
}

public nonisolated enum ConfigValueType: Sendable {
    case string
    case integer
    case double
    case boolean
}

// MARK: - Config Store

/// Persisted, typed configuration for the CIMS architecture.
///
/// Settings are stored in a JSON file at the configured path. Changes are written
/// immediately and can be observed by subsystems that need to react to config changes.
///
/// Thread-safe via actor isolation. All reads and writes go through async methods.
public actor ConfigStore {
    private var values: [String: String] = [:]
    private let storagePath: String
    private var observers: [String: [(String) -> Void]] = [:]

    public init(storagePath: String) {
        self.storagePath = storagePath

        // Load existing config from disk during init.
        let url = URL(fileURLWithPath: storagePath)
        if FileManager.default.fileExists(atPath: storagePath),
           let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            self.values = dict
        }
    }

    /// Get a typed config value, falling back to the default.
    public func get(_ key: ConfigKey) -> String {
        values[key.rawValue] ?? key.defaultValue
    }

    /// Get an integer config value.
    public func getInt(_ key: ConfigKey) -> Int {
        Int(get(key)) ?? Int(key.defaultValue) ?? 0
    }

    /// Get a double config value.
    public func getDouble(_ key: ConfigKey) -> Double {
        Double(get(key)) ?? Double(key.defaultValue) ?? 0.0
    }

    /// Get a boolean config value.
    public func getBool(_ key: ConfigKey) -> Bool {
        let v = get(key).lowercased()
        return v == "true" || v == "1" || v == "yes"
    }

    /// Get a raw value by string key (for the command interface).
    public func getRaw(_ key: String) -> String? {
        if let configKey = ConfigKey(rawValue: key) {
            return get(configKey)
        }
        return values[key]
    }

    /// Set a raw value by string key (for the command interface).
    public func setRaw(_ key: String, value: String) throws {
        // Validate if it's a known key
        if let configKey = ConfigKey(rawValue: key) {
            try validate(value, for: configKey)
        }
        values[key] = value
        saveToDisk()
        notifyObservers(key: key, value: value)
    }

    /// Set a typed config value.
    public func set(_ key: ConfigKey, value: String) throws {
        try validate(value, for: key)
        values[key.rawValue] = value
        saveToDisk()
        notifyObservers(key: key.rawValue, value: value)
    }

    /// Reset a key to its default value.
    public func reset(_ key: String) {
        values.removeValue(forKey: key)
        saveToDisk()
        if let configKey = ConfigKey(rawValue: key) {
            notifyObservers(key: key, value: configKey.defaultValue)
        }
    }

    /// Get all current config values (including defaults for unset keys).
    public func all() -> [String: String] {
        var result: [String: String] = [:]
        for key in ConfigKey.allCases {
            result[key.rawValue] = get(key)
        }
        // Include any custom (non-enum) keys
        for (k, v) in values where ConfigKey(rawValue: k) == nil {
            result[k] = v
        }
        return result
    }

    /// Register an observer for config changes.
    public func observe(_ key: String, handler: @escaping (String) -> Void) {
        observers[key, default: []].append(handler)
    }

    // MARK: - Validation

    private func validate(_ value: String, for key: ConfigKey) throws {
        switch key.valueType {
        case .integer:
            guard Int(value) != nil else {
                throw ConfigError.invalidType(key: key.rawValue, expected: "integer", got: value)
            }
        case .double:
            guard Double(value) != nil else {
                throw ConfigError.invalidType(key: key.rawValue, expected: "number", got: value)
            }
        case .boolean:
            let lower = value.lowercased()
            guard ["true", "false", "1", "0", "yes", "no"].contains(lower) else {
                throw ConfigError.invalidType(key: key.rawValue, expected: "boolean", got: value)
            }
        case .string:
            break // All strings are valid
        }

        // Range checks
        switch key {
        case .contextBudget:
            if let n = Int(value), n < 1_000 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be >= 1000")
            }
        case .protectedTailCount:
            if let n = Int(value), n < 1 || n > 512 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be 1-512")
            }
        case .contextSoftThreshold, .contextHardThreshold:
            if let n = Int(value), n < 10_000 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be >= 10000")
            }
        case .contextMaxPassesPerTurn:
            if let n = Int(value), n < 1 || n > 20 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be 1-20")
            }
        case .observerCycleInterval:
            if let n = Int(value), n < 10 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be >= 10 seconds")
            }
        case .observerInjectionStrength:
            if let n = Double(value), n < 0 || n > 100 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be 0-100")
            }
        case .providerMaxTokens:
            if let n = Int(value), n < 256 || n > 128_000 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be 256-128000")
            }
        case .providerMaxRetries:
            if let n = Int(value), n < 0 || n > 10 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be 0-10")
            }
        case .providerEffort:
            if !["low", "medium", "high"].contains(value) {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be low, medium, or high")
            }
        case .providerThinking:
            if value != "disabled", value != "adaptive", Int(value) == nil {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be disabled, adaptive, or a token budget (integer)")
            }
        case .toolBackgroundTimeout:
            if let n = Int(value), n < 5 || n > 600 {
                throw ConfigError.outOfRange(key: key.rawValue, value: value, reason: "must be 5-600")
            }
        default:
            break
        }
    }

    // MARK: - Persistence

    private func saveToDisk() {
        let url = URL(fileURLWithPath: storagePath)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: url)
        }
    }

    // MARK: - Observers

    private func notifyObservers(key: String, value: String) {
        for handler in observers[key, default: []] {
            handler(value)
        }
    }
}

// MARK: - Config Errors

public nonisolated enum ConfigError: Error, Sendable, CustomStringConvertible {
    case invalidType(key: String, expected: String, got: String)
    case outOfRange(key: String, value: String, reason: String)

    public var description: String {
        switch self {
        case let .invalidType(key, expected, got):
            "\(key): expected \(expected), got '\(got)'"
        case let .outOfRange(key, value, reason):
            "\(key) = \(value): \(reason)"
        }
    }
}
