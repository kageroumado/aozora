import AozoraCore
import AppKit
import Foundation
import GRDB

/// Provides live CIMS telemetry for the inspector panel.
///
/// Pure data provider — no scheduling responsibility. The view drives refresh:
///
/// - **Gateway mode**: the view calls ``refresh()`` from a `.task` modifier on its own
///   `Task.sleep` loop. SwiftUI manages the lifecycle (auto-cancel on disappear).
/// - **IPC mode**: push-based. The daemon broadcasts snapshots on its 60-second tick.
///   ``updateFromIPC(_:)`` handles incoming data. No view-driven refresh needed.
@Observable
final class InspectorManager {
    // MARK: - Dependencies

    /// Data source for the inspector — either a local gateway or a remote IPC client.
    private enum DataSource {
        case gateway(CIMSGateway)
        case ipc(IPCClient)
    }

    private let dataSource: DataSource

    /// Whether this manager is in IPC mode (push-based, no polling needed).
    var isPushBased: Bool {
        if case .ipc = dataSource { return true }
        return false
    }

    // MARK: - Live State

    /// The current temporal mode from the coordinator's chrono state.
    private(set) var temporalMode: TemporalMode = .newSession

    /// The current allostasis mode from the coordinator's resource pressure state.
    private(set) var allostasisMode: AllostasisMode = .exploratory

    /// Current resource pressure (0-1) from the allostasis subsystem.
    private(set) var pressure: Float = 0

    /// Estimated context tokens consumed by the last assembled context.
    ///
    /// This reflects the effective context budget (scaled by allostasis mode),
    /// not raw token consumption. A precise "used" count requires inference
    /// telemetry that the coordinator does not currently expose.
    private(set) var contextBudgetUsed: Int = 0

    /// Total context token budget (effective, scaled by allostasis).
    private(set) var contextBudgetTotal: Int = CIMSDefaults.defaultContextBudget

    /// Number of turns currently queued or in-progress in the coordinator.
    private(set) var queueDepth: Int = 0

    // MARK: - Identity / Mirror

    /// Number of active identity claims in the current identity version.
    private(set) var identityClaimCount: Int = 0

    /// Top 5 identity claims ranked by confidence (descending).
    private(set) var topIdentityClaims: [ClaimSnapshot] = []

    /// Number of active mirror claims for the default user.
    private(set) var mirrorClaimCount: Int = 0

    // MARK: - Memory DAG

    /// Total number of nodes in the LCM DAG across all conversations.
    private(set) var dagNodeCount: Int = 0

    /// Number of nodes demoted to cold storage (compressed payloads).
    private(set) var coldStorageCount: Int = 0

    /// Number of frontier nodes across all conversations.
    private(set) var frontierSize: Int = 0

    // MARK: - Consolidation

    /// Completion time of the most recent consolidation run, or `nil` if none has completed.
    private(set) var lastConsolidationTime: Date?

    /// Whether a consolidation pipeline is currently running.
    private(set) var isConsolidating: Bool = false

    // MARK: - Plugins

    /// Number of registered plugins in the plugin registry.
    private(set) var pluginCount: Int = 0

    // MARK: - Initialization

    /// Creates an inspector manager backed by the given gateway (in-process mode).
    ///
    /// The view drives refresh — call ``refresh()`` from a SwiftUI `.task` modifier.
    init(gateway: CIMSGateway) {
        self.dataSource = .gateway(gateway)
    }

    /// Creates an inspector manager backed by an IPC client (daemon mode).
    ///
    /// Push-based: the daemon broadcasts snapshots on its 60-second tick.
    /// ``updateFromIPC(_:)`` handles incoming data — no view-driven refresh needed.
    init(ipcClient: IPCClient) {
        self.dataSource = .ipc(ipcClient)
    }

    // MARK: - Refresh

    /// Fetch the latest state from all CIMS subsystems.
    ///
    /// In gateway mode, reads from actor-isolated stores (awaits across actor boundaries).
    /// In IPC mode, this is a no-op — data arrives via ``updateFromIPC(_:)`` from the daemon's tick.
    ///
    /// Call this from a SwiftUI `.task` modifier for view-scoped lifecycle management:
    /// ```swift
    /// .task {
    ///     while !Task.isCancelled {
    ///         await inspector.refresh()
    ///         try? await Task.sleep(for: .seconds(2))
    ///     }
    /// }
    /// ```
    func refresh() async {
        await poll()
    }

    // MARK: - Actions

    /// Trigger an immediate consolidation run via the scheduler.
    ///
    /// Cancels any pending idle/session-end timers and runs the consolidation
    /// pipeline synchronously (the pipeline itself is async). If consolidation
    /// is already in progress, this is a no-op inside the scheduler.
    func triggerConsolidation() {
        guard case let .gateway(gateway) = dataSource else { return }
        Task.detached(name: "InspectorManager.consolidate") { [gateway] in
            await gateway.consolidationScheduler.runNow()
        }
    }

    /// Copy a formatted text snapshot of the current inspector state to the system pasteboard.
    func copySnapshot() {
        let snapshot = formatSnapshot()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot, forType: .string)
    }

    // MARK: - Polling

    /// Execute a single poll cycle, reading state from all CIMS subsystems.
    private func poll() async {
        switch dataSource {
        case let .gateway(gateway):
            await pollGateway(gateway)
        case let .ipc(client):
            pollIPC(client)
        }
    }

    /// Poll via IPC — sends a pollInspector request and waits for the response
    /// via the incoming message stream.
    private func pollIPC(_ client: IPCClient) {
        client.send(.pollInspector)
    }

    /// Update inspector state from an IPC inspector snapshot.
    ///
    /// Called by the IPC listener when an `.inspector` message arrives.
    func updateFromIPC(_ data: IPCInspectorData) {
        temporalMode = TemporalMode(rawValue: data.temporalMode) ?? .newSession
        allostasisMode = AllostasisMode(rawValue: data.allostasisMode) ?? .exploratory
        pressure = data.pressure
        contextBudgetUsed = data.contextBudgetUsed
        contextBudgetTotal = data.contextBudgetTotal
        queueDepth = data.queueDepth
        identityClaimCount = data.identityClaimCount
        dagNodeCount = data.dagNodeCount
    }

    /// Poll via in-process gateway.
    private func pollGateway(_ gateway: CIMSGateway) async {
        let coordinator = gateway.coordinator
        let temporal = await coordinator.currentTemporalMode
        let alloMode = await coordinator.currentAllostasisMode
        let press = await coordinator.currentPressure
        let ctxBudget = await coordinator.currentContextBudget
        let queue = await coordinator.currentQueueDepth

        // Identity store
        let identity = await gateway.identityStore.currentIdentity()
        let mirror = await gateway.identityStore.currentMirror(for: "default")

        // Plugin registry
        let plugins = await gateway.pluginRegistry.pluginCount

        // Database-level stats (DAG, cold storage, frontier, consolidation)
        let dbStats = await fetchDatabaseStats()

        // Update observable properties on MainActor
        temporalMode = temporal
        allostasisMode = alloMode
        pressure = press
        contextBudgetTotal = ctxBudget
        contextBudgetUsed = dbStats.estimatedContextUsed
        queueDepth = queue

        identityClaimCount = identity.claims.count
        topIdentityClaims = identity.claims
            .sorted { $0.confidence > $1.confidence }
            .prefix(5)
            .map { ClaimSnapshot(from: $0) }
        mirrorClaimCount = mirror.claims.count

        dagNodeCount = dbStats.nodeCount
        coldStorageCount = dbStats.coldCount
        frontierSize = dbStats.frontier

        lastConsolidationTime = dbStats.lastConsolidation
        isConsolidating = dbStats.consolidating

        pluginCount = plugins
    }

    // MARK: - Database Stats

    /// Aggregate statistics fetched from the CIMS database in a single read transaction.
    private struct DatabaseStats {
        var nodeCount: Int = 0
        var coldCount: Int = 0
        var frontier: Int = 0
        var lastConsolidation: Date?
        var consolidating: Bool = false
        var estimatedContextUsed: Int = 0
    }

    /// Query aggregate stats from the CIMS database.
    ///
    /// Runs all queries in a single `read` transaction to get a consistent snapshot.
    /// Returns default values if the database read fails.
    private func fetchDatabaseStats() async -> DatabaseStats {
        guard case let .gateway(gateway) = dataSource else { return DatabaseStats() }
        do {
            return try await gateway.database.dbPool.read { db in
                var stats = DatabaseStats()

                stats.nodeCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lcm_nodes",
                ) ?? 0

                stats.coldCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lcm_cold_payloads",
                ) ?? 0

                stats.frontier = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM lcm_frontier",
                ) ?? 0

                // Most recent completed consolidation job
                if let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT completedAt FROM consolidation_jobs
                    WHERE status = 'completed' AND completedAt IS NOT NULL
                    ORDER BY completedAt DESC LIMIT 1
                    """,
                ) {
                    if let dateString = row["completedAt"] as String? {
                        stats.lastConsolidation = Self.parseISO8601(dateString)
                    }
                }

                // Check if any consolidation job is currently running
                let runningCount = try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM consolidation_jobs WHERE status = 'running'",
                ) ?? 0
                stats.consolidating = runningCount > 0

                // Estimate context usage from session tokens if available
                // The allostasis state tracks sessionTokensUsed, but it's internal
                // to the coordinator. Approximate from total message token estimates.
                stats.estimatedContextUsed = try Int.fetchOne(
                    db, sql: """
                    SELECT COALESCE(SUM(tokenEstimate), 0) FROM messages
                    WHERE conversationId = (SELECT id FROM conversations ORDER BY updatedAt DESC LIMIT 1)
                    """,
                ) ?? 0

                return stats
            }
        } catch {
            print("[InspectorManager] Database stats query failed: \(error)")
            return DatabaseStats()
        }
    }

    // MARK: - Formatting

    /// Format the current inspector state as a multi-line text snapshot.
    private func formatSnapshot() -> String {
        var lines: [String] = []
        lines.append("=== CIMS Inspector Snapshot ===")
        lines.append("Captured: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")

        lines.append("-- Live State --")
        lines.append("Temporal Mode: \(temporalMode.rawValue)")
        lines.append("Allostasis Mode: \(allostasisMode.rawValue)")
        lines.append("Pressure: \(unsafe String(format: "%.2f", pressure))")
        lines.append("Context Budget: \(contextBudgetUsed) / \(contextBudgetTotal) tokens")
        lines.append("Queue Depth: \(queueDepth)")
        lines.append("")

        lines.append("-- Identity --")
        lines.append("Claims: \(identityClaimCount)")
        if !topIdentityClaims.isEmpty {
            lines.append("Top claims:")
            for claim in topIdentityClaims {
                lines.append("  [\(claim.epistemicStatus)] \(claim.key): \(claim.value) (conf: \(unsafe String(format: "%.2f", claim.confidence)))")
            }
        }
        lines.append("")

        lines.append("-- Mirror --")
        lines.append("Claims: \(mirrorClaimCount)")
        lines.append("")

        lines.append("-- Memory DAG --")
        lines.append("Nodes: \(dagNodeCount)")
        lines.append("Cold Storage: \(coldStorageCount)")
        lines.append("Frontier: \(frontierSize)")
        lines.append("")

        lines.append("-- Consolidation --")
        if let lastTime = lastConsolidationTime {
            lines.append("Last Run: \(ISO8601DateFormatter().string(from: lastTime))")
        } else {
            lines.append("Last Run: never")
        }
        lines.append("Currently Running: \(isConsolidating)")
        lines.append("")

        lines.append("-- Plugins --")
        lines.append("Registered: \(pluginCount)")

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// Parse an ISO 8601 date string with fractional seconds.
    private nonisolated static func parseISO8601(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: string) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}

// MARK: - ClaimSnapshot

/// Lightweight snapshot of an identity or mirror claim for the inspector panel.
///
/// Captures the essential display fields from ``IdentityClaim`` without retaining
/// the full claim structure. Used by ``InspectorManager/topIdentityClaims`` for
/// the inspector's identity section.
nonisolated struct ClaimSnapshot: Identifiable {
    /// Stable identifier derived from the source claim's database ID.
    let id: String

    /// The namespaced claim key (e.g., `"self.communication_style"`).
    let key: String

    /// The claim content.
    let value: String

    /// Confidence level (0-1), subject to Hebbian decay.
    let confidence: Float

    /// Display-friendly epistemic status (e.g., `"hypothesis"`, `"asserted"`).
    let epistemicStatus: String

    /// Creates a snapshot from an ``IdentityClaim``.
    init(from claim: IdentityClaim) {
        self.id = String(claim.id)
        self.key = claim.claimKey
        self.value = claim.value
        self.confidence = claim.confidence
        self.epistemicStatus = claim.epistemicStatus.rawValue
    }

    /// Creates a snapshot with explicit values (for testing or mirror claims).
    init(id: String, key: String, value: String, confidence: Float, epistemicStatus: String) {
        self.id = id
        self.key = key
        self.value = value
        self.confidence = confidence
        self.epistemicStatus = epistemicStatus
    }
}
