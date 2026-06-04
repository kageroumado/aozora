import AozoraCore
import SwiftUI

/// Inspector panel showing live CIMS telemetry and controls.
///
/// Displays collapsible sections for live state, identity, mirror,
/// memory DAG, plugins, and consolidation. Polls on a configurable timer
/// when visible, stopping automatically when the view disappears.
///
/// The inspector reads from ``InspectorManager`` via the environment-injected
/// ``CIMSAppState``. When the manager is unavailable (CIMS not yet booted),
/// a placeholder message is shown instead.
struct InspectorView: View {
    @Environment(CIMSAppState.self) var appState

    /// The inspector manager from app state, available once CIMS has booted.
    private var inspector: InspectorManager? {
        appState.inspectorManager
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let inspector {
                    liveStateSection(inspector)
                    identitySection(inspector)
                    mirrorSection(inspector)
                    memorySection(inspector)
                    pluginsSection(inspector)
                    consolidationSection(inspector)
                    exportSection(inspector)
                } else {
                    Text("Inspector not available")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 240, idealWidth: 280)
        .task {
            guard let inspector, !inspector.isPushBased else { return }
            while !Task.isCancelled {
                await inspector.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Sections

    /// Displays temporal mode, allostasis, context budget, and queue depth.
    private func liveStateSection(_ inspector: InspectorManager) -> some View {
        DisclosureGroup("Live State") {
            VStack(alignment: .leading, spacing: 8) {
                labeledValue("Temporal Mode", value: inspector.temporalMode.rawValue)
                labeledValue(
                    "Allostasis",
                    value: "\(inspector.allostasisMode.rawValue) (\(unsafe String(format: "%.2f", inspector.pressure)))",
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Context Budget")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(
                        value: Double(inspector.contextBudgetUsed),
                        total: Double(max(inspector.contextBudgetTotal, 1)),
                    )
                    .tint(.blue)
                    Text("\(inspector.contextBudgetUsed) / \(inspector.contextBudgetTotal) tokens")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                labeledValue("Queue Depth", value: "\(inspector.queueDepth)")
            }
        }
    }

    /// Shows top identity claims ranked by confidence with progress bars.
    private func identitySection(_ inspector: InspectorManager) -> some View {
        DisclosureGroup("Identity (\(inspector.identityClaimCount))") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(inspector.topIdentityClaims) { claim in
                    HStack {
                        Text(claim.key)
                            .font(.caption)
                            .bold()
                        Spacer()
                        Text(claim.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ProgressView(value: Double(claim.confidence))
                            .frame(width: 40)
                            .tint(.green)
                    }
                }
                if inspector.topIdentityClaims.isEmpty {
                    Text("No claims yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Shows the mirror claim count for the default user profile.
    private func mirrorSection(_ inspector: InspectorManager) -> some View {
        DisclosureGroup("Mirror (\(inspector.mirrorClaimCount))") {
            VStack(alignment: .leading, spacing: 6) {
                labeledValue("Active Claims", value: "\(inspector.mirrorClaimCount)")
            }
        }
    }

    /// Displays DAG node count, cold storage, and frontier size.
    private func memorySection(_ inspector: InspectorManager) -> some View {
        DisclosureGroup("Memory DAG") {
            VStack(alignment: .leading, spacing: 6) {
                labeledValue("Nodes", value: "\(inspector.dagNodeCount)")
                labeledValue("Cold Storage", value: "\(inspector.coldStorageCount)")
                labeledValue("Frontier", value: "\(inspector.frontierSize)")
            }
        }
    }

    /// Shows the number of registered plugins.
    private func pluginsSection(_ inspector: InspectorManager) -> some View {
        DisclosureGroup("Plugins (\(inspector.pluginCount))") {
            VStack(alignment: .leading, spacing: 6) {
                labeledValue("Registered", value: "\(inspector.pluginCount)")
            }
        }
    }

    /// Shows last consolidation time and provides a manual trigger button.
    private func consolidationSection(_ inspector: InspectorManager) -> some View {
        DisclosureGroup("Consolidation") {
            VStack(alignment: .leading, spacing: 6) {
                if let lastRun = inspector.lastConsolidationTime {
                    labeledValue("Last Run", value: lastRun.formatted(.relative(presentation: .named)))
                } else {
                    labeledValue("Last Run", value: "Never")
                }

                if inspector.isConsolidating {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Running...")
                            .font(.caption)
                    }
                } else {
                    Button("Run Now") {
                        inspector.triggerConsolidation()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    /// Button to copy a formatted text snapshot of inspector state to the pasteboard.
    private func exportSection(_ inspector: InspectorManager) -> some View {
        Button("Copy Snapshot") {
            inspector.copySnapshot()
        }
        .controlSize(.small)
    }

    // MARK: - Helpers

    /// A horizontally-spaced label/value pair styled for inspector display.
    private func labeledValue(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .bold()
        }
    }
}
