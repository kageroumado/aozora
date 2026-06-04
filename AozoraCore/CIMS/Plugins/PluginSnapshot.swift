import Foundation

/// A snapshot of a plugin's current state, for diagnostics and status display.
///
/// Extracted from ``PluginManager`` so it's available to both the GUI and daemon targets.
public nonisolated struct PluginSnapshot: Identifiable, Sendable {
    /// Unique identifier matching the plugin's ``CIMSPlugin/id``.
    public let id: String

    /// Human-readable name matching the plugin's ``CIMSPlugin/name``.
    public let name: String

    /// Whether the plugin is currently activated.
    public let isActive: Bool

    /// Number of tools provided by this plugin (0 if not a ``CIMSToolProvider``).
    public let toolCount: Int

    /// Whether this plugin implements ``MessagingChannel``.
    public let hasChannel: Bool
}
