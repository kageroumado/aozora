import Foundation

/// Central registry for CIMS plugins.
///
/// ``PluginRegistry`` manages the lifecycle of all registered plugins — tool providers
/// and messaging channels. Plugins are registered before activation and can be queried
/// by the coordinator during turn processing.
///
/// The registry provides:
/// - Plugin lifecycle management (register, activate, deactivate)
/// - Tool routing: resolving tool names to their owning plugins
/// - Channel management: starting/stopping messaging channels
public actor PluginRegistry {
    /// All registered plugins, keyed by plugin ID.
    private var plugins: [String: any CIMSPlugin] = [:]

    /// Plugin IDs in registration (insertion) order.
    ///
    /// Maintains the order in which plugins were registered so lifecycle hooks
    /// are dispatched deterministically. Updated on register/unregister.
    private var pluginOrder: [String] = []

    /// Tool providers, keyed by plugin ID.
    private var toolProviders: [String: any CIMSToolProvider] = [:]

    /// Messaging channels, keyed by plugin ID.
    private var channels: [String: any MessagingChannel] = [:]

    /// Tool name → plugin ID mapping for fast routing.
    private var toolRouting: [String: String] = [:]

    /// Whether the registry has been activated.
    private var isActive = false

    /// The shared plugin context, set during activation.
    private var context: PluginContext?

    // MARK: - Registration

    /// Register a plugin with the registry.
    ///
    /// Plugins must be registered before ``activateAll(context:)`` is called.
    /// Registering a plugin with a duplicate ID replaces the previous registration.
    ///
    /// - Parameter plugin: The plugin to register.
    public func register(_ plugin: any CIMSPlugin) {
        let isReplacement = plugins[plugin.id] != nil
        plugins[plugin.id] = plugin

        if !isReplacement {
            pluginOrder.append(plugin.id)
        }

        if let toolProvider = plugin as? any CIMSToolProvider {
            toolProviders[plugin.id] = toolProvider
        }

        if let channel = plugin as? any MessagingChannel {
            channels[plugin.id] = channel
        }
    }

    /// Unregister a plugin by ID.
    ///
    /// If the registry is active, the plugin is deactivated first.
    ///
    /// - Parameter id: The plugin ID to unregister.
    public func unregister(id: String) async {
        if let plugin = plugins[id] {
            await plugin.deactivate()
        }

        plugins.removeValue(forKey: id)
        pluginOrder.removeAll { $0 == id }
        toolProviders.removeValue(forKey: id)
        channels.removeValue(forKey: id)

        // Clean up tool routing for this plugin
        toolRouting = toolRouting.filter { $0.value != id }
    }

    // MARK: - Lifecycle

    /// Activate all registered plugins.
    ///
    /// Each plugin's ``CIMSPlugin/activate(context:)`` is called. Plugins that fail
    /// to activate are logged but not removed — they can be retried later.
    ///
    /// After activation, tool routing is rebuilt from all tool providers.
    ///
    /// - Parameter context: The shared plugin context.
    public func activateAll(context: PluginContext) async {
        self.context = context
        isActive = true

        for (id, plugin) in plugins {
            do {
                try await plugin.activate(context: context)
            } catch {
                print("[PluginRegistry] Failed to activate plugin '\(id)': \(error)")
            }
        }

        await rebuildToolRouting()
    }

    /// Deactivate all registered plugins.
    public func deactivateAll() async {
        for channel in channels.values {
            await channel.stop()
        }

        for plugin in plugins.values {
            await plugin.deactivate()
        }

        isActive = false
        context = nil
        toolRouting.removeAll()
    }

    // MARK: - Tool Routing

    /// Resolve a tool name to its owning plugin and execute the tool.
    ///
    /// Called by the coordinator when the executive model returns a tool call
    /// that doesn't match the built-in tools (dispatch_worker, expand_memory, search_memory).
    ///
    /// - Parameters:
    ///   - toolName: The tool name from the model's tool call.
    ///   - arguments: JSON-encoded arguments.
    /// - Returns: The tool result, or `nil` if no plugin owns this tool.
    public func executePluginTool(name toolName: String, arguments: String) async -> ToolResult? {
        guard let pluginId = toolRouting[toolName],
              let provider = toolProviders[pluginId],
              let context
        else {
            return nil
        }

        do {
            return try await provider.execute(tool: toolName, arguments: arguments, context: context)
        } catch {
            return .failure("Plugin tool '\(toolName)' failed: \(error)")
        }
    }

    /// Get all tool definitions from all registered tool providers.
    ///
    /// Used by the coordinator to include plugin tools in the executive model's
    /// tool schema.
    public func allToolDefinitions() async -> [ToolDefinition] {
        var definitions: [ToolDefinition] = []
        for provider in toolProviders.values {
            let tools = await provider.tools
            definitions.append(contentsOf: tools)
        }
        return definitions
    }

    /// Rebuild the tool name → plugin ID routing table.
    private func rebuildToolRouting() async {
        toolRouting.removeAll()
        for (id, provider) in toolProviders {
            let tools = await provider.tools
            for tool in tools {
                if toolRouting[tool.name] != nil {
                    print("[PluginRegistry] Tool name conflict: '\(tool.name)' already registered")
                }
                toolRouting[tool.name] = id
            }
        }
    }

    // MARK: - Channel Management

    /// Start all registered messaging channels.
    ///
    /// Called after activation. Each channel begins receiving inbound messages.
    public func startChannels() async {
        for (id, channel) in channels {
            do {
                try await channel.start()
            } catch {
                print("[PluginRegistry] Failed to start channel '\(id)': \(error)")
            }
        }
    }

    /// Stop all registered messaging channels.
    public func stopChannels() async {
        for channel in channels.values {
            await channel.stop()
        }
    }

    /// Get all active messaging channels.
    public func activeChannels() -> [any MessagingChannel] {
        Array(channels.values)
    }

    // MARK: - Lifecycle Hooks

    /// Dispatch ``CIMSPlugin/beforeToolCall(_:)`` to all plugins in registration order.
    ///
    /// Returns the first non-proceed decision, or ``ToolCallDecision/proceed`` if all
    /// plugins allow the tool call. Errors from individual plugin hooks are logged
    /// and treated as ``ToolCallDecision/proceed``.
    ///
    /// - Parameter event: The tool call event to evaluate.
    /// - Returns: The first non-proceed decision, or `.proceed`.
    public func dispatchBeforeToolCall(_ event: ToolCallEvent) async -> ToolCallDecision {
        for id in pluginOrder {
            guard let plugin = plugins[id] else { continue }
            do {
                let decision = await plugin.beforeToolCall(event)
                if case .proceed = decision {
                    continue
                }
                return decision
            } catch {
                print("[PluginRegistry] beforeToolCall hook failed for '\(id)': \(error)")
            }
        }
        return .proceed
    }

    /// Dispatch ``CIMSPlugin/afterToolCall(_:result:)`` to all plugins in registration order.
    ///
    /// Errors from individual plugin hooks are logged and do not prevent subsequent
    /// plugins from receiving the event.
    ///
    /// - Parameters:
    ///   - event: The tool call event that was executed.
    ///   - result: The result of the tool execution.
    public func dispatchAfterToolCall(_ event: ToolCallEvent, result: ToolResult) async {
        for id in pluginOrder {
            guard let plugin = plugins[id] else { continue }
            do {
                await plugin.afterToolCall(event, result: result)
            } catch {
                print("[PluginRegistry] afterToolCall hook failed for '\(id)': \(error)")
            }
        }
    }

    /// Dispatch ``CIMSPlugin/beforeInference(_:)`` to all plugins, chaining prompt modifications.
    ///
    /// Each plugin receives the prompt as modified by the previous plugin. If a plugin
    /// hook throws, the error is logged and the unmodified prompt from before that plugin
    /// is passed to the next.
    ///
    /// - Parameter prompt: The initial prompt before plugin modifications.
    /// - Returns: The prompt after all plugin modifications have been applied.
    public func dispatchBeforeInference(_ prompt: Prompt) async -> Prompt {
        var current = prompt
        for id in pluginOrder {
            guard let plugin = plugins[id] else { continue }
            do {
                current = await plugin.beforeInference(current)
            } catch {
                print("[PluginRegistry] beforeInference hook failed for '\(id)': \(error)")
            }
        }
        return current
    }

    /// Dispatch ``CIMSPlugin/afterInference(_:)`` to all plugins in registration order.
    ///
    /// Errors from individual plugin hooks are logged and do not prevent subsequent
    /// plugins from receiving the event.
    ///
    /// - Parameter response: The model response to broadcast.
    public func dispatchAfterInference(_ response: ModelResponse) async {
        for id in pluginOrder {
            guard let plugin = plugins[id] else { continue }
            do {
                await plugin.afterInference(response)
            } catch {
                print("[PluginRegistry] afterInference hook failed for '\(id)': \(error)")
            }
        }
    }

    /// Dispatch ``CIMSPlugin/onSessionStart(_:)`` to all plugins in registration order.
    ///
    /// Errors from individual plugin hooks are logged and do not prevent subsequent
    /// plugins from receiving the event.
    ///
    /// - Parameter session: Information about the starting session.
    public func dispatchSessionStart(_ session: SessionInfo) async {
        for id in pluginOrder {
            guard let plugin = plugins[id] else { continue }
            do {
                await plugin.onSessionStart(session)
            } catch {
                print("[PluginRegistry] onSessionStart hook failed for '\(id)': \(error)")
            }
        }
    }

    /// Dispatch ``CIMSPlugin/onSessionEnd(_:)`` to all plugins in registration order.
    ///
    /// Errors from individual plugin hooks are logged and do not prevent subsequent
    /// plugins from receiving the event.
    ///
    /// - Parameter session: Information about the ending session.
    public func dispatchSessionEnd(_ session: SessionInfo) async {
        for id in pluginOrder {
            guard let plugin = plugins[id] else { continue }
            do {
                await plugin.onSessionEnd(session)
            } catch {
                print("[PluginRegistry] onSessionEnd hook failed for '\(id)': \(error)")
            }
        }
    }

    // MARK: - Queries

    /// The number of registered plugins.
    public var pluginCount: Int {
        plugins.count
    }

    /// The number of registered tool providers.
    public var toolProviderCount: Int {
        toolProviders.count
    }

    /// The number of registered messaging channels.
    public var channelCount: Int {
        channels.count
    }

    /// The number of routable tools.
    public var routedToolCount: Int {
        toolRouting.count
    }

    /// Check if a tool name is handled by a plugin.
    public func isPluginTool(_ name: String) -> Bool {
        toolRouting[name] != nil
    }

    /// Look up a messaging channel by its plugin ID or name (case-insensitive).
    ///
    /// Searches first by exact plugin ID match, then by case-insensitive name match.
    /// Used by ``CrossChannelTool`` to resolve channel targets.
    ///
    /// - Parameter nameOrId: The channel's plugin ID or display name.
    /// - Returns: The matching messaging channel, or `nil` if not found.
    public func channel(named nameOrId: String) -> (any MessagingChannel)? {
        if let channel = channels[nameOrId] {
            return channel
        }
        let lowered = nameOrId.lowercased()
        return channels.values.first { $0.name.lowercased() == lowered }
    }

    /// Build lightweight snapshots of all registered plugins for the management UI.
    ///
    /// Each snapshot captures the plugin's current state without exposing the plugin
    /// reference itself. Includes tool count (from tool providers) and channel status
    /// (from messaging channels).
    ///
    /// - Returns: An array of ``PluginSnapshot``s for all registered plugins.
    public func pluginSnapshots() async -> [PluginSnapshot] {
        var snapshots: [PluginSnapshot] = []
        for (id, plugin) in plugins {
            let toolCount: Int = if let provider = toolProviders[id] {
                await provider.tools.count
            } else {
                0
            }
            let hasChannel = channels[id] != nil
            snapshots.append(PluginSnapshot(
                id: id,
                name: plugin.name,
                isActive: isActive,
                toolCount: toolCount,
                hasChannel: hasChannel,
            ))
        }
        return snapshots
    }

    /// Activate a single plugin by ID.
    ///
    /// If the registry hasn't been activated yet (no context set), or if the plugin
    /// ID is not registered, this is a no-op. After activation, tool routing is rebuilt.
    ///
    /// - Parameter id: The plugin ID to activate.
    public func activatePlugin(id: String) async {
        guard let plugin = plugins[id], let context else { return }
        do {
            try await plugin.activate(context: context)
            await rebuildToolRouting()
        } catch {
            print("[PluginRegistry] Failed to activate plugin '\(id)': \(error)")
        }
    }

    /// Deactivate a single plugin by ID without unregistering it.
    ///
    /// The plugin remains registered and can be reactivated later. If the plugin
    /// provides a messaging channel, the channel is stopped first.
    ///
    /// - Parameter id: The plugin ID to deactivate.
    public func deactivatePlugin(id: String) async {
        guard let plugin = plugins[id] else { return }

        if let channel = channels[id] {
            await channel.stop()
        }

        await plugin.deactivate()

        // Clean up tool routing for this plugin
        toolRouting = toolRouting.filter { $0.value != id }
    }
}
