import Foundation
import Testing
@testable import Aozora

struct ProviderRegistryTests {
    // MARK: - Registration

    @Test
    func `Registers and lists providers`() async {
        let registry = ProviderRegistry()
        await registry.register(.init(
            name: "openai",
            type: .openai,
            apiKey: "sk-test",
        ))

        let providers = await registry.registeredProviders
        #expect(providers == ["openai"])
    }

    @Test
    func `Register multiple providers`() async {
        let registry = ProviderRegistry()
        await registry.registerAll([
            .init(name: "openai", type: .openai, apiKey: "sk-1"),
            .init(name: "groq", type: .openai, apiKey: "gsk-1"),
        ])

        let providers = await registry.registeredProviders
        #expect(providers.count == 2)
        #expect(providers.contains("openai"))
        #expect(providers.contains("groq"))
    }

    // MARK: - Resolution by Model ID

    @Test
    func `Resolves OpenAI model by family prefix`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(name: "openai", type: .openai, apiKey: "sk-test"))

        let provider = try await registry.resolve(for: "gpt-4o")
        #expect(provider is OpenAIProvider)
    }

    @Test
    func `Resolves model with explicit provider prefix`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(name: "openai", type: .openai, apiKey: "sk-test"))

        let provider = try await registry.resolve(for: "openai/gpt-4o")
        #expect(provider is OpenAIProvider)
    }

    @Test
    func `Resolves OpenRouter model`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(
            name: "openrouter",
            type: .openai,
            apiKey: "sk-or-test",
            baseURL: URL(string: "https://openrouter.ai/api"),
        ))

        let provider = try await registry.resolve(for: "openrouter/anthropic/claude-3.5-sonnet")
        #expect(provider is OpenAIProvider)
    }

    @Test
    func `Resolves local Ollama model`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(
            name: "ollama",
            type: .openai,
            apiKey: "ollama",
            baseURL: URL(string: "http://localhost:11434"),
        ))

        let provider = try await registry.resolve(for: "ollama/llama3")
        #expect(provider is OpenAIProvider)
    }

    @Test
    func `Throws unknownModel when no provider matches and no fallback`() async {
        let registry = ProviderRegistry()

        do {
            _ = try await registry.resolve(for: "totally-unknown-model")
            Issue.record("Expected ProviderError.unknownModel")
        } catch is ProviderRegistry.ProviderError {
            // expected
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func `Falls back to default provider when no config matches`() async throws {
        let mock = MockModelProvider()
        let registry = ProviderRegistry(fallbackProvider: mock)

        let provider = try await registry.resolve(for: "unknown-model")
        #expect(provider is MockModelProvider)
    }

    // MARK: - Credential Resolution

    @Test
    func `Uses explicit API key from config`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(name: "openai", type: .openai, apiKey: "sk-explicit"))

        let provider = try await registry.resolve(for: "gpt-4o")
        let openai = try #require(provider as? OpenAIProvider)
        #expect(openai.apiKey == "sk-explicit")
    }

    @Test
    func `Throws noCredentials when no key available`() async {
        let registry = ProviderRegistry()
        await registry.register(.init(name: "openai", type: .openai))

        do {
            _ = try await registry.resolve(for: "gpt-4o")
            Issue.record("Expected ProviderError.noCredentials")
        } catch let error as ProviderRegistry.ProviderError {
            if case .noCredentials = error {
                // expected
            } else {
                Issue.record("Expected noCredentials, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `Anthropic provider type throws unsupported`() async {
        let registry = ProviderRegistry()
        await registry.register(.init(name: "anthropic", type: .anthropic, apiKey: "sk-ant"))

        do {
            _ = try await registry.resolve(for: "anthropic/claude-opus-4-6")
            Issue.record("Expected ProviderError.unsupportedProvider")
        } catch let error as ProviderRegistry.ProviderError {
            if case .unsupportedProvider = error {
                // expected
            } else {
                Issue.record("Expected unsupportedProvider, got \(error)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Caching

    @Test
    func `Provider instances are cached after creation`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(name: "openai", type: .openai, apiKey: "sk-test"))

        let p1 = try await registry.resolve(for: "gpt-4o")
        let p2 = try await registry.resolve(for: "gpt-4o-mini")

        let addr1 = ObjectIdentifier(type(of: p1))
        let addr2 = ObjectIdentifier(type(of: p2))
        #expect(addr1 == addr2)
    }

    // MARK: - Model Family Recognition

    @Test
    func `Recognizes DeepSeek model family`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(
            name: "deepseek",
            type: .openai,
            apiKey: "sk-ds",
            baseURL: URL(string: "https://api.deepseek.com"),
        ))

        let provider = try await registry.resolve(for: "deepseek-chat")
        #expect(provider is OpenAIProvider)
    }

    @Test
    func `Recognizes o3/o4 model families as OpenAI`() async throws {
        let registry = ProviderRegistry()
        await registry.register(.init(name: "openai", type: .openai, apiKey: "sk-test"))

        let p1 = try await registry.resolve(for: "o3-mini")
        #expect(p1 is OpenAIProvider)

        let p2 = try await registry.resolve(for: "o4-mini")
        #expect(p2 is OpenAIProvider)
    }
}

// MARK: - ModelCatalog.ModelInfo Tests

struct ModelCatalogInfoTests {
    @Test
    func `Known model returns info with correct context window`() {
        let info = ModelCatalog.info(for: "gpt-4o")
        #expect(info != nil)
        #expect(info?.contextWindow == 128_000)
        #expect(info?.supportsTools == true)
    }

    @Test
    func `Versioned model name matches family`() {
        let info = ModelCatalog.info(for: "gpt-4o-2024-08-06")
        #expect(info != nil)
        #expect(info?.contextWindow == 128_000)
    }

    @Test
    func `Model with provider prefix resolves correctly`() {
        let info = ModelCatalog.info(for: "openai/gpt-4o")
        #expect(info != nil)
        #expect(info?.supportsStreaming == true)
    }

    @Test
    func `Unknown model returns nil`() {
        let info = ModelCatalog.info(for: "totally-unknown")
        #expect(info == nil)
    }

    @Test
    func `Claude model info has correct window`() {
        let info = ModelCatalog.info(for: "claude-opus-4-6")
        #expect(info != nil)
        #expect(info?.contextWindow == 200_000)
        #expect(info?.supportsVision == true)
    }

    @Test
    func `DeepSeek reasoner doesn't support tools`() {
        let info = ModelCatalog.info(for: "deepseek-reasoner")
        #expect(info != nil)
        #expect(info?.supportsTools == false)
    }

    @Test
    func `Pricing is populated in model info`() throws {
        let info = ModelCatalog.info(for: "gpt-4o")
        #expect(info != nil)
        #expect(info?.pricing.isKnown == true)
        #expect(try #require(info?.pricing.inputPerMillion) > 0)
    }
}
