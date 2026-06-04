import Foundation
import Testing
@testable import Aozora

/// Tests for the plugin registry lifecycle, tool routing, and channel management.
@Suite("Plugin Registry")
struct PluginRegistryTests {
    // MARK: - Mock Plugins

    /// A minimal tool provider plugin for testing.
    actor MockToolPlugin: CIMSToolProvider {
        let id: String
        let name: String
        private(set) var isActivated = false
        private(set) var executeCallCount = 0

        private let toolDefs: [ToolDefinition]
        private let executeResult: String

        init(
            id: String = "mock-tool",
            name: String = "Mock Tool",
            tools: [ToolDefinition] = [],
            executeResult: String = "Tool executed successfully",
        ) {
            self.id = id
            self.name = name
            self.toolDefs = tools
            self.executeResult = executeResult
        }

        nonisolated var tools: [ToolDefinition] {
            get async { await getTools() }
        }

        private func getTools() -> [ToolDefinition] {
            toolDefs
        }

        func activate(context _: PluginContext) async throws {
            isActivated = true
        }

        func deactivate() async {
            isActivated = false
        }

        nonisolated func execute(tool _: String, arguments _: String, context _: PluginContext) async throws -> ToolResult {
            await incrementExecuteCount()
            return await .success(getResult())
        }

        private func incrementExecuteCount() {
            executeCallCount += 1
        }
        private func getResult() -> String {
            executeResult
        }
    }

    /// A minimal messaging channel plugin for testing.
    actor MockChannelPlugin: MessagingChannel {
        let id: String
        let name: String
        private(set) var isStarted = false
        private(set) var sentMessages: [OutboundMessage] = []

        private let messageContinuation: AsyncStream<InboundMessage>.Continuation
        private let messageStream: AsyncStream<InboundMessage>

        init(id: String = "mock-channel", name: String = "Mock Channel") {
            self.id = id
            self.name = name
            let (stream, continuation) = AsyncStream<InboundMessage>.makeStream()
            self.messageStream = stream
            self.messageContinuation = continuation
        }

        func activate(context _: PluginContext) async throws {}
        func deactivate() async {}

        func start() async throws {
            isStarted = true
        }

        func stop() async {
            isStarted = false
        }

        nonisolated func send(_ message: OutboundMessage) async throws {
            await appendSent(message)
        }

        private func appendSent(_ message: OutboundMessage) {
            sentMessages.append(message)
        }

        nonisolated var incomingMessages: AsyncStream<InboundMessage> {
            get async { await getStream() }
        }

        private func getStream() -> AsyncStream<InboundMessage> {
            messageStream
        }

        /// Inject a test message into the stream.
        func injectMessage(_ message: InboundMessage) {
            messageContinuation.yield(message)
        }
    }

    /// Create a minimal plugin context for testing.
    private func makeContext() async throws -> PluginContext {
        let gateway = try await CIMSGateway.inMemory()
        return PluginContext(
            coordinator: gateway.coordinator,
            memoryStore: gateway.memoryStore,
            identityStore: gateway.identityStore,
        )
    }

    // MARK: - Registration

    @Test("Register a plugin")
    func registerPlugin() async {
        let registry = PluginRegistry()
        let plugin = MockToolPlugin()
        await registry.register(plugin)

        let count = await registry.pluginCount
        #expect(count == 1)
    }

    @Test("Register multiple plugins")
    func registerMultiplePlugins() async {
        let registry = PluginRegistry()
        await registry.register(MockToolPlugin(id: "tool-1", name: "Tool 1"))
        await registry.register(MockToolPlugin(id: "tool-2", name: "Tool 2"))
        await registry.register(MockChannelPlugin(id: "channel-1", name: "Channel 1"))

        let pluginCount = await registry.pluginCount
        let toolCount = await registry.toolProviderCount
        let channelCount = await registry.channelCount

        #expect(pluginCount == 3)
        #expect(toolCount == 2)
        #expect(channelCount == 1)
    }

    @Test("Duplicate plugin ID replaces previous")
    func duplicateIdReplaces() async {
        let registry = PluginRegistry()
        await registry.register(MockToolPlugin(id: "same-id", name: "First"))
        await registry.register(MockToolPlugin(id: "same-id", name: "Second"))

        let count = await registry.pluginCount
        #expect(count == 1)
    }

    @Test("Unregister removes plugin")
    func unregisterPlugin() async {
        let registry = PluginRegistry()
        await registry.register(MockToolPlugin(id: "to-remove", name: "Remove Me"))

        let before = await registry.pluginCount
        #expect(before == 1)

        await registry.unregister(id: "to-remove")

        let after = await registry.pluginCount
        #expect(after == 0)
    }

    // MARK: - Activation

    @Test("ActivateAll calls activate on each plugin")
    func activateAll() async throws {
        let registry = PluginRegistry()
        let plugin = MockToolPlugin()
        await registry.register(plugin)

        let context = try await makeContext()
        await registry.activateAll(context: context)

        let activated = await plugin.isActivated
        #expect(activated)
    }

    @Test("DeactivateAll calls deactivate on each plugin")
    func deactivateAll() async throws {
        let registry = PluginRegistry()
        let plugin = MockToolPlugin()
        await registry.register(plugin)

        let context = try await makeContext()
        await registry.activateAll(context: context)
        await registry.deactivateAll()

        let activated = await plugin.isActivated
        #expect(!activated)
    }

    // MARK: - Tool Routing

    @Test("Tool routing resolves to correct plugin")
    func toolRouting() async throws {
        let registry = PluginRegistry()

        let bashTool = ToolDefinition(
            name: "run_bash",
            description: "Execute a bash command",
            parameters: [ToolParameter(name: "command", type: .string, description: "Command to run", optional: false)],
        )

        let plugin = MockToolPlugin(
            id: "bash-plugin",
            name: "Bash",
            tools: [bashTool],
            executeResult: "command output",
        )
        await registry.register(plugin)

        let context = try await makeContext()
        await registry.activateAll(context: context)

        let isPluginTool = await registry.isPluginTool("run_bash")
        #expect(isPluginTool)

        let result = await registry.executePluginTool(name: "run_bash", arguments: "{\"command\": \"ls\"}")
        #expect(result != nil)
        #expect(result?.content == "command output")
        #expect(result?.isError == false)
    }

    @Test("Unknown tool returns nil")
    func unknownToolReturnsNil() async throws {
        let registry = PluginRegistry()

        let context = try await makeContext()
        await registry.activateAll(context: context)

        let result = await registry.executePluginTool(name: "nonexistent", arguments: "{}")
        #expect(result == nil)
    }

    @Test("All tool definitions collected from providers")
    func allToolDefinitions() async {
        let registry = PluginRegistry()

        let tool1 = ToolDefinition(name: "tool_a", description: "A", parameters: [])
        let tool2 = ToolDefinition(name: "tool_b", description: "B", parameters: [])

        await registry.register(MockToolPlugin(id: "p1", name: "P1", tools: [tool1]))
        await registry.register(MockToolPlugin(id: "p2", name: "P2", tools: [tool2]))

        let allTools = await registry.allToolDefinitions()
        #expect(allTools.count == 2)

        let names = Set(allTools.map(\.name))
        #expect(names.contains("tool_a"))
        #expect(names.contains("tool_b"))
    }

    // MARK: - Channel Management

    @Test("Start channels starts all registered channels")
    func startChannels() async throws {
        let registry = PluginRegistry()
        let channel = MockChannelPlugin()
        await registry.register(channel)

        let context = try await makeContext()
        await registry.activateAll(context: context)
        await registry.startChannels()

        let started = await channel.isStarted
        #expect(started)
    }

    @Test("Stop channels stops all registered channels")
    func stopChannels() async throws {
        let registry = PluginRegistry()
        let channel = MockChannelPlugin()
        await registry.register(channel)

        let context = try await makeContext()
        await registry.activateAll(context: context)
        await registry.startChannels()
        await registry.stopChannels()

        let started = await channel.isStarted
        #expect(!started)
    }

    @Test("Send message through channel")
    func sendMessage() async throws {
        let channel = MockChannelPlugin()

        let message = OutboundMessage(
            text: "Hello from CIMS!",
            sessionKey: "test-session",
            userKey: "test-user",
        )

        try await channel.send(message)

        let sent = await channel.sentMessages
        #expect(sent.count == 1)
        #expect(sent.first?.text == "Hello from CIMS!")
    }

    // MARK: - Edge Cases

    @Test("Registry works with zero plugins")
    func emptyRegistry() async throws {
        let registry = PluginRegistry()

        let context = try await makeContext()
        await registry.activateAll(context: context)

        let toolCount = await registry.routedToolCount
        #expect(toolCount == 0)

        let result = await registry.executePluginTool(name: "anything", arguments: "{}")
        #expect(result == nil)
    }
}
