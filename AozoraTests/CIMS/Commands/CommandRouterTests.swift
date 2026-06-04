import XCTest
@testable import Aozora

/// Swift 6.2 strict concurrency: XCTestCase must not be @MainActor-isolated.
final nonisolated class CommandRouterTests: XCTestCase {
    // MARK: - Helpers

    /// Create a temporary config store scoped to this test.
    private func makeConfig() -> (ConfigStore, String) {
        let path = TestFixtures.tempConfigPath()
        return (ConfigStore(storagePath: path), path)
    }

    // MARK: - Parser Tests

    nonisolated func testParseSimpleCommand() {
        let parsed = CommandParser.parse("/status")
        XCTAssertEqual(parsed.name, "status")
        XCTAssertTrue(parsed.arguments.isEmpty)
        XCTAssertTrue(parsed.flags.isEmpty)
    }

    nonisolated func testParseBareCommand() {
        let parsed = CommandParser.parse("status")
        XCTAssertEqual(parsed.name, "status")
    }

    nonisolated func testParseWithArguments() {
        let parsed = CommandParser.parse("/memory search consciousness qualia")
        XCTAssertEqual(parsed.name, "memory")
        XCTAssertEqual(parsed.arguments, ["search", "consciousness", "qualia"])
    }

    nonisolated func testParseWithQuotedArgument() {
        let parsed = CommandParser.parse("/memory search \"hello world\"")
        XCTAssertEqual(parsed.name, "memory")
        XCTAssertEqual(parsed.arguments, ["search", "hello world"])
    }

    nonisolated func testParseWithFlags() {
        let parsed = CommandParser.parse("/memory search test --limit 10 --format json")
        XCTAssertEqual(parsed.name, "memory")
        XCTAssertEqual(parsed.arguments, ["search", "test"])
        XCTAssertEqual(parsed.flags["limit"], "10")
        XCTAssertEqual(parsed.flags["format"], "json")
    }

    nonisolated func testParseBooleanFlag() {
        let parsed = CommandParser.parse("/config show --verbose")
        XCTAssertEqual(parsed.flags["verbose"], "true")
    }

    nonisolated func testParseEmptyInput() {
        let parsed = CommandParser.parse("")
        XCTAssertEqual(parsed.name, "")
    }

    nonisolated func testParseSingleQuotes() {
        let parsed = CommandParser.parse("/memory search 'multi word query'")
        XCTAssertEqual(parsed.arguments, ["search", "multi word query"])
    }

    // MARK: - Config Store Tests

    func testConfigDefaults() async {
        let (config, path) = makeConfig()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let budget = await config.get(.contextBudget)
        XCTAssertEqual(budget, "\(CIMSDefaults.defaultContextBudget)")
    }

    func testConfigSetAndGet() async throws {
        let (config, path) = makeConfig()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await config.set(.contextBudget, value: "500000")
        let budget = await config.get(.contextBudget)
        XCTAssertEqual(budget, "500000")
    }

    func testConfigValidationRejectsInvalidType() async {
        let (config, path) = makeConfig()
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            try await config.set(.contextBudget, value: "not_a_number")
            XCTFail("Should have thrown")
        } catch {
            // Expected -- any error is fine, we just verify it throws
        }
    }

    func testConfigValidationRejectsOutOfRange() async {
        let (config, path) = makeConfig()
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            try await config.set(.contextBudget, value: "100")
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }

    func testConfigReset() async throws {
        let (config, path) = makeConfig()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await config.set(.contextBudget, value: "500000")
        await config.reset(ConfigKey.contextBudget.rawValue)
        let budget = await config.get(.contextBudget)
        XCTAssertEqual(budget, "\(CIMSDefaults.defaultContextBudget)")
    }

    func testConfigPersistence() async throws {
        let (config1, path) = makeConfig()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await config1.set(.executiveModel, value: "claude-opus-5")

        let config2 = ConfigStore(storagePath: path)
        let model = await config2.get(.executiveModel)
        XCTAssertEqual(model, "claude-opus-5")
    }

    func testConfigAll() async {
        let (config, path) = makeConfig()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let all = await config.all()

        for key in ConfigKey.allCases {
            XCTAssertNotNil(all[key.rawValue], "Missing key: \(key.rawValue)")
        }
    }

    // MARK: - Command Router Integration

    private func makeRouter() async throws -> CommandRouter {
        let gateway = try await CIMSGateway.inMemory()
        let config = ConfigStore(storagePath: TestFixtures.tempConfigPath())
        return await CommandRouter(
            memoryStore: gateway.memoryStore,
            identityStore: gateway.identityStore,
            config: config,
        )
    }

    func testUnknownCommand() async throws {
        let router = try await makeRouter()
        let result = await router.execute("/nonexistent")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.displayText.contains("Unknown command"))
    }

    func testHelpCommand() async throws {
        let router = try await makeRouter()
        let result = await router.execute("/help")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.displayText.contains("/status"))
        XCTAssertTrue(result.displayText.contains("/memory"))
    }

    func testStatusCommand() async throws {
        let router = try await makeRouter()
        let result = await router.execute("/status")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.displayText.contains("Aozora Status"))
        XCTAssertTrue(result.displayText.contains("Context budget"))
    }

    func testConfigShowCommand() async throws {
        let router = try await makeRouter()
        let result = await router.execute("/config show")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.displayText.contains("Configuration"))
    }

    func testConfigSetCommand() async throws {
        let router = try await makeRouter()

        let result = await router.execute("/config set context.budget 800000")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.displayText.contains("800000"))

        let get = await router.execute("/config get context.budget")
        XCTAssertTrue(get.displayText.contains("800000"))
    }

    func testIdentityShowCommand() async throws {
        let router = try await makeRouter()
        let result = await router.execute("/identity show")
        XCTAssertFalse(result.isError)
    }

    func testObserverCommandRemoved() async throws {
        let router = try await makeRouter()
        let result = await router.execute("/observer status")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.displayText.contains("Unknown command"))
    }

    func testConfigKeysCommand() async throws {
        let router = try await makeRouter()
        let result = await router.execute("/config keys")
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.displayText.contains("model.executive"))
        XCTAssertTrue(result.displayText.contains("context.budget"))
    }

    func testCustomCommandRegistration() async throws {
        let router = try await makeRouter()
        await router.register("ping", handler: BlockHandler { _, _ in
            .text("pong")
        })
        let result = await router.execute("/ping")
        XCTAssertEqual(result.displayText, "pong")
    }
}
