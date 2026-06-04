import AozoraCore
import SwiftUI

// MARK: - Main View

/// Plugin management view for enabling and configuring registered plugins.
///
/// Lists all plugins from ``PluginManager`` with their active/inactive state,
/// tool-provider and messaging-channel capability badges, and an activation toggle.
/// Expanding a row reveals a detail section with tool count and channel presence.
///
/// Only rendered when `appState.phase == .ready`, so force-unwrapping
/// `pluginManager` is safe.
struct PluginManagementView: View {
    @Environment(CIMSAppState.self) private var appState

    /// The set of plugin IDs whose detail rows are currently expanded.
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        let pm = appState.pluginManager!

        Group {
            if pm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                pluginList(pm)
            }
        }
        .navigationTitle("Plugins")
        .task { await pm.refresh() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await pm.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(pm.isLoading)
            }
        }
    }

    // MARK: - Plugin List

    /// The scrollable list of plugin rows.
    ///
    /// - Parameter pm: The plugin manager providing the snapshot array.
    private func pluginList(_ pm: PluginManager) -> some View {
        List {
            Section {
                if pm.plugins.isEmpty {
                    Text("No plugins registered")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(pm.plugins) { plugin in
                        pluginRow(plugin, pm: pm)
                    }
                }
            } header: {
                HStack {
                    Text("Registered Plugins")
                    Spacer()
                    Text("\(pm.plugins.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: - Plugin Row

    /// A single plugin row with name, capability badges, active toggle, and expandable detail.
    ///
    /// Tapping the disclosure chevron expands an inline detail section showing
    /// tool count and channel status.
    ///
    /// - Parameters:
    ///   - plugin: The plugin snapshot to render.
    ///   - pm: The plugin manager used to activate/deactivate.
    private func pluginRow(_ plugin: PluginSnapshot, pm: PluginManager) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Active/inactive indicator dot
                Circle()
                    .fill(plugin.isActive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)

                // Name
                Text(plugin.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                // Capability badges
                HStack(spacing: 4) {
                    if plugin.toolCount > 0 {
                        PluginCapabilityBadge(
                            label: "\(plugin.toolCount) tool\(plugin.toolCount == 1 ? "" : "s")",
                            systemImage: "wrench.and.screwdriver",
                            color: .orange,
                        )
                    }
                    if plugin.hasChannel {
                        PluginCapabilityBadge(
                            label: "Channel",
                            systemImage: "antenna.radiowaves.left.and.right",
                            color: .purple,
                        )
                    }
                }

                Spacer()

                // Disclosure toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedIDs.contains(plugin.id) {
                            expandedIDs.remove(plugin.id)
                        } else {
                            expandedIDs.insert(plugin.id)
                        }
                    }
                } label: {
                    Image(
                        systemName: expandedIDs.contains(plugin.id)
                            ? "chevron.up"
                            : "chevron.down",
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)

                // Active toggle
                Toggle(
                    isOn: Binding(
                        get: { plugin.isActive },
                        set: { active in
                            Task {
                                if active {
                                    await pm.activatePlugin(id: plugin.id)
                                } else {
                                    await pm.deactivatePlugin(id: plugin.id)
                                }
                            }
                        },
                    ),
                ) {
                    EmptyView()
                }
                .labelsHidden()
                .toggleStyle(.switch)
            }
            .padding(.vertical, 6)

            // Expanded detail
            if expandedIDs.contains(plugin.id) {
                PluginDetailView(plugin: plugin)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Plugin Detail View

/// Inline detail section shown below an expanded plugin row.
///
/// Displays tool count, channel presence, and the plugin's unique ID for
/// diagnostics. Visually separated from the row with a top divider.
private struct PluginDetailView: View {
    /// The plugin snapshot to render detail for.
    let plugin: PluginSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 3) {
                detailRow(label: "Plugin ID", content: plugin.id)

                detailRow(
                    label: "Tools",
                    content: plugin.toolCount == 0
                        ? "None"
                        : "\(plugin.toolCount) tool\(plugin.toolCount == 1 ? "" : "s")",
                )

                detailRow(
                    label: "Messaging Channel",
                    content: plugin.hasChannel ? "Yes" : "No",
                )

                detailRow(
                    label: "Status",
                    content: plugin.isActive ? "Active" : "Inactive",
                )
            }
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 4)
    }

    /// A two-column grid row for a labeled detail field.
    ///
    /// - Parameters:
    ///   - label: The field name.
    ///   - content: The field value.
    private func detailRow(label: String, content: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(content)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Plugin Capability Badge

/// A compact badge indicating a plugin capability (tool provider or messaging channel).
///
/// Renders an SF Symbol icon next to a short label with a tinted background capsule.
private struct PluginCapabilityBadge: View {
    /// Short label for this capability.
    let label: String

    /// SF Symbol name.
    let systemImage: String

    /// The badge accent color.
    let color: Color

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}
