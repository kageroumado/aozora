import Foundation

/// Resolves ``ModelProviding`` instances from model identifier strings.
///
/// The registry maps model identifiers to their backing providers using a prefix-based
/// scheme. Model IDs can include an explicit provider prefix (e.g., `openai/gpt-4o`,
/// `openrouter/deepseek/deepseek-chat`) or be bare names that are matched against
/// known model families.
///
/// Credentials are resolved from a chain: explicit config → environment variables → fallback.
/// Provider instances are cached after creation to avoid repeated credential resolution.
public actor ProviderRegistry {
    /// Registered provider configurations.
    private var configs: [String: ProviderConfig] = [:]

    /// Cached provider instances, keyed by config name.
    private var providers: [String: any ModelProviding] = [:]

    /// The fallback provider used when no configuration matches.
    private let fallbackProvider: (any ModelProviding)?

    /// Known model family → provider name mappings.
    private static let modelFamilies: [(prefix: String, provider: String)] = [
        ("claude-", "anthropic"),
        ("gpt-", "openai"),
        ("o1-", "openai"),
        ("o3-", "openai"),
        ("o4-", "openai"),
        ("deepseek-", "deepseek"),
        ("gemini-", "google"),
        ("llama", "ollama"),
        ("mistral", "openrouter"),
        ("qwen", "openrouter"),
    ]

    /// Configuration for a single provider endpoint.
    public struct ProviderConfig: Sendable {
        /// Human-readable name (e.g., "openai", "openrouter").
        public let name: String

        /// The provider type.
        public let type: ProviderType

        /// API key or token. Resolved from config, env, or keychain.
        public let apiKey: String?

        /// Environment variable name to check for the API key.
        public let envVar: String?

        /// Base URL override (for OpenAI-compatible endpoints).
        public let baseURL: URL?

        /// Per-tier model overrides specific to this provider.
        public let modelOverrides: [ModelTier: String]

        public init(
            name: String,
            type: ProviderType,
            apiKey: String? = nil,
            envVar: String? = nil,
            baseURL: URL? = nil,
            modelOverrides: [ModelTier: String] = [:],
        ) {
            self.name = name
            self.type = type
            self.apiKey = apiKey
            self.envVar = envVar
            self.baseURL = baseURL
            self.modelOverrides = modelOverrides
        }
    }

    /// The type of provider backend.
    public enum ProviderType: String, Sendable {
        /// Anthropic Messages API.
        case anthropic
        /// OpenAI-compatible `/v1/chat/completions` endpoint.
        case openai
    }

    /// Errors specific to provider resolution.
    public enum ProviderError: Error, Sendable {
        /// No API key found for the provider in any credential source.
        case noCredentials(provider: String)
        /// No provider configuration matches the given model ID.
        case unknownModel(String)
        /// The provider type is not supported.
        case unsupportedProvider(String)
    }

    /// Create a provider registry.
    ///
    /// - Parameter fallbackProvider: Optional provider to use when no config matches.
    public init(fallbackProvider: (any ModelProviding)? = nil) {
        self.fallbackProvider = fallbackProvider
    }

    // MARK: - Configuration

    /// Register a provider configuration.
    ///
    /// - Parameter config: The provider configuration to register.
    public func register(_ config: ProviderConfig) {
        configs[config.name] = config
        providers[config.name] = nil
    }

    /// Register multiple provider configurations at once.
    ///
    /// - Parameter configs: The provider configurations to register.
    public func registerAll(_ configs: [ProviderConfig]) {
        for config in configs {
            register(config)
        }
    }

    // MARK: - Resolution

    /// Resolve a ``ModelProviding`` instance for a model identifier.
    ///
    /// Resolution order:
    /// 1. Check for explicit `provider/model` prefix (e.g., `openai/gpt-4o`)
    /// 2. Match model name against known families (e.g., `gpt-4o` → "openai")
    /// 3. Fall back to the default provider if configured
    ///
    /// - Parameter modelId: The model identifier to resolve.
    /// - Returns: A ``ModelProviding`` instance configured for the model.
    /// - Throws: ``ProviderError/unknownModel(_:)`` if no provider matches.
    public func resolve(for modelId: String) throws -> any ModelProviding {
        let providerName = resolveProviderName(for: modelId)

        if let name = providerName, let provider = try resolveByName(name) {
            return provider
        }

        if let fallback = fallbackProvider {
            return fallback
        }

        throw ProviderError.unknownModel(modelId)
    }

    /// Resolve a provider by its registered name.
    ///
    /// - Parameter name: The provider name (e.g., "openai", "anthropic").
    /// - Returns: The cached or freshly created provider, or `nil` if no config exists.
    /// - Throws: ``ProviderError/noCredentials(provider:)`` if no API key is available.
    public func resolveByName(_ name: String) throws -> (any ModelProviding)? {
        if let cached = providers[name] {
            return cached
        }

        guard let config = configs[name] else {
            return nil
        }

        let provider = try createProvider(from: config)
        providers[name] = provider
        return provider
    }

    /// List all registered provider names.
    public var registeredProviders: [String] {
        Array(configs.keys.sorted())
    }

    // MARK: - Provider Creation

    /// Create a provider instance from a configuration.
    private func createProvider(from config: ProviderConfig) throws -> any ModelProviding {
        let apiKey = resolveAPIKey(for: config)

        switch config.type {
        case .openai:
            guard let key = apiKey else {
                throw ProviderError.noCredentials(provider: config.name)
            }
            let baseURL = config.baseURL
                ?? OpenAIProvider.forEndpoint(config.name, apiKey: "").baseURL
            return OpenAIProvider(
                baseURL: baseURL,
                apiKey: key,
                modelOverrides: config.modelOverrides,
            )

        case .anthropic:
            throw ProviderError.unsupportedProvider(
                "Anthropic provider must be created externally via AnthropicProvider — "
                    + "it requires credential store integration not available through ProviderRegistry.",
            )
        }
    }

    /// Resolve an API key from the config chain.
    ///
    /// Resolution order:
    /// 1. Explicit `apiKey` in the config
    /// 2. Environment variable named by `envVar`
    /// 3. Standard env var for the provider (e.g., `OPENAI_API_KEY`)
    private func resolveAPIKey(for config: ProviderConfig) -> String? {
        if let key = config.apiKey, !key.isEmpty {
            return key
        }

        if let envVar = config.envVar,
           let value = ProcessInfo.processInfo.environment[envVar],
           !value.isEmpty {
            return value
        }

        let standardEnvVar = standardEnvVarName(for: config.name)
        if let value = ProcessInfo.processInfo.environment[standardEnvVar], !value.isEmpty {
            return value
        }

        return nil
    }

    /// Map a provider name to its standard environment variable.
    private func standardEnvVarName(for provider: String) -> String {
        switch provider.lowercased() {
        case "openai": "OPENAI_API_KEY"
        case "openrouter": "OPENROUTER_API_KEY"
        case "groq": "GROQ_API_KEY"
        case "deepseek": "DEEPSEEK_API_KEY"
        case "together": "TOGETHER_API_KEY"
        case "google": "GOOGLE_API_KEY"
        default: "\(provider.uppercased())_API_KEY"
        }
    }

    // MARK: - Model → Provider Mapping

    /// Resolve a provider name from a model identifier.
    ///
    /// Checks for explicit `provider/model` prefix first, then matches against
    /// known model families.
    private func resolveProviderName(for modelId: String) -> String? {
        if let slashIndex = modelId.firstIndex(of: "/") {
            let prefix = String(modelId[..<slashIndex])
            if configs[prefix] != nil {
                return prefix
            }
        }

        let bareModel = stripProviderPrefix(from: modelId)
        for (prefix, provider) in Self.modelFamilies {
            if bareModel.hasPrefix(prefix) {
                return provider
            }
        }

        return nil
    }

    /// Strip a `provider/` prefix from a model identifier.
    private func stripProviderPrefix(from model: String) -> String {
        guard let slash = model.firstIndex(of: "/") else { return model }
        return String(model[model.index(after: slash)...])
    }
}

// MARK: - ModelCatalog Extensions

extension ModelCatalog {
    /// Model capability metadata.
    public struct ModelInfo: Sendable {
        /// Maximum context window in tokens.
        public let contextWindow: Int

        /// Whether the model supports tool/function calling.
        public let supportsTools: Bool

        /// Whether the model supports streaming.
        public let supportsStreaming: Bool

        /// Whether the model supports vision (image inputs).
        public let supportsVision: Bool

        /// The pricing for this model.
        public let pricing: Pricing
    }

    /// Known model metadata entries.
    private static let modelInfo: [(prefix: String, info: ModelInfo)] = [
        ("claude-opus-4-6", ModelInfo(contextWindow: 200_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "claude-opus-4-6"))),
        ("claude-sonnet-4-6", ModelInfo(contextWindow: 200_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "claude-sonnet-4-6"))),
        ("claude-haiku-4-5", ModelInfo(contextWindow: 200_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "claude-haiku-4-5"))),
        ("gpt-5", ModelInfo(contextWindow: 1_000_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "gpt-5"))),
        ("gpt-4o-mini", ModelInfo(contextWindow: 128_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "gpt-4o-mini"))),
        ("gpt-4o", ModelInfo(contextWindow: 128_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "gpt-4o"))),
        ("o3-mini", ModelInfo(contextWindow: 200_000, supportsTools: true, supportsStreaming: true, supportsVision: false, pricing: pricing(for: "o3-mini"))),
        ("o3", ModelInfo(contextWindow: 200_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "o3"))),
        ("deepseek-chat", ModelInfo(contextWindow: 64_000, supportsTools: true, supportsStreaming: true, supportsVision: false, pricing: pricing(for: "deepseek-chat"))),
        ("deepseek-reasoner", ModelInfo(contextWindow: 64_000, supportsTools: false, supportsStreaming: true, supportsVision: false, pricing: pricing(for: "deepseek-reasoner"))),
        ("gemini-2.5-pro", ModelInfo(contextWindow: 1_000_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "gemini-2.5-pro"))),
        ("gemini-2.5-flash", ModelInfo(contextWindow: 1_000_000, supportsTools: true, supportsStreaming: true, supportsVision: true, pricing: pricing(for: "gemini-2.5-flash"))),
    ]

    /// Look up metadata for a model, using longest-prefix matching.
    ///
    /// - Parameter model: The model identifier (optionally including `provider/` prefix).
    /// - Returns: The ``ModelInfo`` if the model is known, or `nil`.
    public static func info(for model: String) -> ModelInfo? {
        let name = stripProviderPrefix(from: model)

        var bestMatch: (length: Int, info: ModelInfo)? = nil
        for entry in modelInfo {
            if name.hasPrefix(entry.prefix) {
                let length = entry.prefix.count
                if bestMatch == nil || length > bestMatch!.length {
                    bestMatch = (length, entry.info)
                }
            }
        }
        return bestMatch?.info
    }

    /// Strip a `provider/` prefix from a model name.
    ///
    /// Duplicated here from the private pricing method for use by ``info(for:)``.
    private static func stripProviderPrefix(from model: String) -> String {
        guard let slash = model.firstIndex(of: "/") else { return model }
        return String(model[model.index(after: slash)...])
    }
}
