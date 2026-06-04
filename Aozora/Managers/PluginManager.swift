import AozoraCore
import Foundation
import OSLog

private let logger = Logger(subsystem: "app.aozora", category: "plugins")

/// Manages plugin lifecycle, channel status, and tool routing information.
///
/// Provides an observable snapshot of registered plugins for the management UI.
/// Bridges to the ``PluginRegistry`` actor for state queries and lifecycle control.
/// Each mutation method refreshes the snapshot list after the operation completes.
@Observable
final class PluginManager {
    /// The plugin registry actor.
    private let registry: PluginRegistry

    /// Snapshots of all registered plugins, refreshed after each operation.
    var plugins: [PluginSnapshot] = []

    /// Whether a refresh or lifecycle operation is in progress.
    var isLoading = false

    /// Creates a plugin manager backed by the given registry.
    ///
    /// - Parameter registry: The plugin registry to manage.
    init(registry: PluginRegistry) {
        self.registry = registry
    }

    // MARK: - Queries

    /// Refresh the plugin snapshot list from the registry.
    ///
    /// Queries the ``PluginRegistry`` for all registered plugins and builds
    /// lightweight snapshots with tool counts and channel status.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        plugins = await registry.pluginSnapshots()
        let count = plugins.count
        logger.debug("Refreshed plugin list: \(count) plugins")
    }

    // MARK: - Lifecycle

    /// Activate a single plugin by ID.
    ///
    /// Delegates to ``PluginRegistry/activatePlugin(id:)`` which calls the plugin's
    /// ``CIMSPlugin/activate(context:)`` method and rebuilds tool routing.
    /// Refreshes the snapshot list after activation.
    ///
    /// - Parameter id: The plugin ID to activate.
    func activatePlugin(id: String) async {
        isLoading = true
        defer { isLoading = false }

        await registry.activatePlugin(id: id)
        logger.info("Activated plugin '\(id)'")

        plugins = await registry.pluginSnapshots()
    }

    /// Deactivate a single plugin by ID without unregistering it.
    ///
    /// Delegates to ``PluginRegistry/deactivatePlugin(id:)`` which stops the
    /// plugin's messaging channel (if any), calls ``CIMSPlugin/deactivate()``,
    /// and removes tool routing entries. The plugin remains registered and can
    /// be reactivated later. Refreshes the snapshot list after deactivation.
    ///
    /// - Parameter id: The plugin ID to deactivate.
    func deactivatePlugin(id: String) async {
        isLoading = true
        defer { isLoading = false }

        await registry.deactivatePlugin(id: id)
        logger.info("Deactivated plugin '\(id)'")

        plugins = await registry.pluginSnapshots()
    }
}
