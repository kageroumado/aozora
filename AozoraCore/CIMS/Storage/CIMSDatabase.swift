import Foundation
import GRDB

/// Central database manager for CIMS persistence.
///
/// Owns and configures the GRDB `DatabasePool` that backs all CIMS storage — the LCM DAG,
/// identity/mirror versioned claims, conversation history, delegation grants, consolidation jobs,
/// and cognitive traces. The schema is created via a single versioned migration (`v1_createSchema`)
/// that establishes all 19+ tables, FTS5 virtual table, and covering indices.
///
/// **Configuration:**
/// - WAL journal mode for concurrent reads during write transactions.
/// - Foreign keys enforced at the SQLite level — cascading deletes protect referential integrity.
///
/// **Thread safety:** `CIMSDatabase` is `Sendable` because `DatabasePool` is itself `Sendable`
/// and the class holds no mutable state. Actor-isolated stores (``MemoryStoring``, ``IdentityStoring``)
/// share a single `CIMSDatabase` instance and call into `dbPool` from their own isolation domains.
///
/// **Testing:** Use ``inMemory()`` to get a throwaway database backed by a temp file. Each call
/// produces an independent database — no shared state between tests.
public final nonisolated class CIMSDatabase: Sendable {
    /// The GRDB connection pool shared by all CIMS actors.
    ///
    /// Actors read via `dbPool.read { }` and write via `dbPool.write { }`.
    /// WAL mode allows concurrent readers alongside a single writer.
    public let dbPool: DatabasePool

    /// Create a database at the given filesystem path.
    ///
    /// Opens (or creates) a SQLite database file, enables foreign keys and WAL journal mode,
    /// then runs all pending migrations to bring the schema up to date.
    ///
    /// - Parameter path: Absolute path to the `.sqlite` file.
    /// - Throws: GRDB errors if the file can't be opened or migrations fail.
    public init(path: String) throws {
        self.dbPool = try DatabasePool(path: path, configuration: Self.makeConfiguration())
        try migrator.migrate(dbPool)
    }

    /// Create an ephemeral in-memory database for testing.
    ///
    /// Each call produces an independent database backed by a temporary file that is cleaned
    /// up by the OS. The database has the same schema as production — all 19+ tables, FTS5,
    /// and indices are created.
    ///
    /// - Returns: A fully migrated `CIMSDatabase` instance.
    /// - Throws: GRDB errors if schema creation fails.
    public static func inMemory() throws -> CIMSDatabase {
        try CIMSDatabase()
    }

    /// Private initializer for in-memory databases.
    ///
    /// Creates a temp file in the system's temporary directory with a UUID-based name
    /// to avoid collisions when multiple tests run concurrently.
    private init() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent("cims-test-\(UUID().uuidString).sqlite").path
        self.dbPool = try DatabasePool(path: path, configuration: Self.makeConfiguration())
        try migrator.migrate(dbPool)
    }

    /// Shared GRDB configuration for all database instances.
    ///
    /// Enables foreign keys for referential integrity and WAL journal mode
    /// for concurrent reads during write transactions.
    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.journalMode = .wal
        return config
    }

    // MARK: - Migrations

    /// The database migrator containing all schema versions.
    ///
    /// GRDB's `DatabaseMigrator` tracks which migrations have been applied and only runs
    /// new ones. Migrations are identified by string keys and execute in registration order.
    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createSchema") { db in
            // ──────────────────────────────────────────────
            // 1. Conversations — one row per session
            // ──────────────────────────────────────────────
            try db.create(table: "conversations") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionKey", .text).notNull().unique()
                t.column("userKey", .text).notNull()
                t.column("startedAt", .text).notNull()
                t.column("lastMessageAt", .text)
                t.column("messageCount", .integer).notNull().defaults(to: 0)
            }

            // ──────────────────────────────────────────────
            // 2. Messages — individual turns within a conversation
            // ──────────────────────────────────────────────
            try db.create(table: "messages") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .integer).notNull()
                    .references("conversations", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("tokenEstimate", .integer).notNull()
                t.column("salienceScore", .double)
                t.column("createdAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 3. Message parts — structured content within a message
            // ──────────────────────────────────────────────
            try db.create(table: "message_parts") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .integer).notNull()
                    .references("messages", onDelete: .cascade)
                t.column("partKind", .text).notNull()
                t.column("ordinal", .integer).notNull()
                t.column("content", .text).notNull()
                t.column("metadata", .text)
            }

            // ──────────────────────────────────────────────
            // 4. LCM nodes — DAG vertices at various compression depths
            // ──────────────────────────────────────────────
            try db.create(table: "lcm_nodes") { t in
                t.primaryKey("nodeId", .text)
                t.column("conversationId", .integer).notNull()
                    .references("conversations")
                t.column("depth", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("tokenCount", .integer).notNull()
                t.column("checksum", .text)
                t.column("salienceScore", .double).notNull().defaults(to: 0)
                t.column("hotness", .double).notNull().defaults(to: 1.0)
                t.column("isCold", .integer).notNull().defaults(to: 0)
                t.column("canonicalText", .text)
                t.column("summaryText", .text)
                t.column("expandFooter", .text)
                t.column("earliestAt", .text).notNull()
                t.column("latestAt", .text).notNull()
                t.column("lastAccessedAt", .text).notNull()
                t.column("version", .integer).notNull().defaults(to: 1)
                t.column("createdAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 5. LCM edges — directed relationships between DAG nodes
            // ──────────────────────────────────────────────
            try db.create(table: "lcm_edges") { t in
                t.column("fromNodeId", .text).notNull()
                    .references("lcm_nodes")
                t.column("toNodeId", .text).notNull()
                    .references("lcm_nodes")
                t.column("edgeKind", .text).notNull()
                t.primaryKey(["fromNodeId", "toNodeId", "edgeKind"])
            }

            // ──────────────────────────────────────────────
            // 6. LCM frontier — the current "visible" set of nodes per conversation
            // ──────────────────────────────────────────────
            try db.create(table: "lcm_frontier") { t in
                t.column("conversationId", .integer).notNull()
                    .references("conversations")
                t.column("nodeId", .text).notNull()
                    .references("lcm_nodes")
                t.column("ordinal", .integer).notNull()
                t.primaryKey(["conversationId", "ordinal"])
            }

            // ──────────────────────────────────────────────
            // 7. FTS5 virtual table — full-text search over node content
            // ──────────────────────────────────────────────
            try db.execute(sql: """
            CREATE VIRTUAL TABLE lcm_fts USING fts5(
                content,
                nodeId UNINDEXED,
                conversationId UNINDEXED,
                depth UNINDEXED,
                kind UNINDEXED
            )
            """)

            // ──────────────────────────────────────────────
            // 8. Cold payloads — compressed blobs for demoted nodes
            // ──────────────────────────────────────────────
            try db.create(table: "lcm_cold_payloads") { t in
                t.primaryKey("nodeId", .text)
                    .references("lcm_nodes")
                t.column("payload", .blob).notNull()
                t.column("originalBytes", .integer).notNull()
            }

            // ──────────────────────────────────────────────
            // 9. Large files — metadata for content too large for inline storage
            // ──────────────────────────────────────────────
            try db.create(table: "large_files") { t in
                t.primaryKey("fileId", .text)
                t.column("conversationId", .integer).notNull()
                    .references("conversations")
                t.column("messageId", .integer).notNull()
                    .references("messages")
                t.column("fileName", .text)
                t.column("mimeType", .text)
                t.column("byteSize", .integer).notNull()
                t.column("tokenEstimate", .integer).notNull()
                t.column("explorationSummary", .text).notNull()
                t.column("storagePath", .text).notNull()
                t.column("createdAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 10. Context items — assembled context snapshot per conversation
            // ──────────────────────────────────────────────
            try db.create(table: "context_items") { t in
                t.column("conversationId", .integer).notNull()
                    .references("conversations")
                t.column("ordinal", .integer).notNull()
                t.column("itemKind", .text).notNull()
                t.column("referenceId", .text).notNull()
                t.column("tokenEstimate", .integer).notNull()
                t.primaryKey(["conversationId", "ordinal"])
            }

            // ──────────────────────────────────────────────
            // 11. Identity versions — version chain for the system's self-knowledge
            // ──────────────────────────────────────────────
            try db.create(table: "identity_versions") { t in
                t.autoIncrementedPrimaryKey("versionId")
                t.column("previousVersion", .integer)
                    .references("identity_versions")
                t.column("isActive", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("createdBy", .text).notNull()
                t.column("rationale", .text)
            }

            // ──────────────────────────────────────────────
            // 12. Identity claims — epistemic claims attached to a version
            // ──────────────────────────────────────────────
            try db.create(table: "identity_claims") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("versionId", .integer).notNull()
                    .references("identity_versions", onDelete: .cascade)
                t.column("claimKey", .text).notNull()
                t.column("value", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 0.5)
                t.column("epistemicStatus", .text).notNull().defaults(to: "hypothesis")
                t.column("evidenceCount", .integer).notNull().defaults(to: 0)
                t.column("evidenceDiversity", .integer).notNull().defaults(to: 0)
                t.column("decayHalfLifeDays", .double).notNull().defaults(to: 90)
                t.column("createdAt", .text).notNull()
                t.column("lastReinforcedAt", .text).notNull()
                t.uniqueKey(["versionId", "claimKey"])
            }

            // ──────────────────────────────────────────────
            // 13. Users — known users who have interacted with the system
            // ──────────────────────────────────────────────
            try db.create(table: "users") { t in
                t.primaryKey("userKey", .text)
                t.column("displayName", .text)
                t.column("firstSeenAt", .text).notNull()
                t.column("lastInteractionAt", .text).notNull()
                t.column("sessionCount", .integer).notNull().defaults(to: 0)
                t.column("isBootstrap", .integer).notNull().defaults(to: 1)
            }

            // ──────────────────────────────────────────────
            // 14. Mirror versions — version chain for per-user models
            // ──────────────────────────────────────────────
            try db.create(table: "mirror_versions") { t in
                t.autoIncrementedPrimaryKey("versionId")
                t.column("userKey", .text).notNull()
                    .references("users")
                t.column("previousVersion", .integer)
                    .references("mirror_versions")
                t.column("isActive", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
                t.column("createdBy", .text).notNull()
                t.column("rationale", .text)
            }

            // ──────────────────────────────────────────────
            // 15. Mirror claims — per-user epistemic claims attached to a mirror version
            // ──────────────────────────────────────────────
            try db.create(table: "mirror_claims") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("versionId", .integer).notNull()
                    .references("mirror_versions", onDelete: .cascade)
                t.column("claimKey", .text).notNull()
                t.column("value", .text).notNull()
                t.column("confidence", .double).notNull().defaults(to: 0.5)
                t.column("epistemicStatus", .text).notNull().defaults(to: "hypothesis")
                t.column("evidenceCount", .integer).notNull().defaults(to: 0)
                t.column("evidenceDiversity", .integer).notNull().defaults(to: 0)
                t.column("decayHalfLifeDays", .double).notNull().defaults(to: 60)
                t.column("createdAt", .text).notNull()
                t.column("lastReinforcedAt", .text).notNull()
                t.uniqueKey(["versionId", "claimKey"])
            }

            // ──────────────────────────────────────────────
            // 16. Claim evidence — links claims to supporting DAG nodes
            // ──────────────────────────────────────────────
            try db.create(table: "claim_evidence") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("claimId", .integer).notNull()
                t.column("claimTable", .text).notNull()
                t.column("nodeId", .text).notNull()
                    .references("lcm_nodes")
                t.column("evidenceType", .text).notNull()
                t.column("excerpt", .text)
                t.column("createdAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 17. Delegation grants — scoped, time-limited worker access to LCM
            // ──────────────────────────────────────────────
            try db.create(table: "delegation_grants") { t in
                t.primaryKey("grantId", .text)
                t.column("conversationScope", .text).notNull()
                t.column("tokenCap", .integer).notNull()
                t.column("tokensUsed", .integer).notNull().defaults(to: 0)
                t.column("operations", .text).notNull()
                t.column("createdAt", .text).notNull()
                t.column("expiresAt", .text).notNull()
                t.column("revokedAt", .text)
                t.column("workerRunId", .text)
            }

            // ──────────────────────────────────────────────
            // 18. Consolidation jobs — offline pipeline run tracking
            // ──────────────────────────────────────────────
            try db.create(table: "consolidation_jobs") { t in
                t.primaryKey("jobId", .text)
                t.column("trigger", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("startedAt", .text)
                t.column("completedAt", .text)
                t.column("bumpsDetected", .integer)
                t.column("claimsExtracted", .integer)
                t.column("nodesCompacted", .integer)
                t.column("nodesDecayed", .integer)
                t.column("error", .text)
                t.column("createdAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 19a. Chrono state — per-user temporal perception tracking
            // ──────────────────────────────────────────────
            try db.create(table: "chrono_state") { t in
                t.primaryKey("userKey", .text)
                    .references("users")
                t.column("lastInteractionAt", .text).notNull()
                t.column("lastSessionEndAt", .text)
                t.column("sessionCount", .integer).notNull().defaults(to: 0)
                t.column("gapHistory", .text)
            }

            // ──────────────────────────────────────────────
            // 19b. Allostatic state — singleton resource pressure tracking
            // ──────────────────────────────────────────────
            try db.create(table: "allostatic_state") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("mode", .text).notNull().defaults(to: "balanced")
                t.column("recentLatencyMs", .text)
                t.column("recentErrorRate", .double).notNull().defaults(to: 0)
                t.column("tokenBudgetUsed", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 19c. Cognitive traces — per-turn diagnostic snapshots
            // ──────────────────────────────────────────────
            try db.create(table: "cognitive_traces") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("turnId", .text).notNull()
                t.column("conversationId", .integer).notNull()
                    .references("conversations")
                t.column("salienceEnvelope", .text).notNull()
                t.column("memoryRetrieval", .text).notNull()
                t.column("contextBudget", .text).notNull()
                t.column("executiveTools", .text)
                t.column("workerDispatches", .text)
                t.column("degradationFlags", .text)
                t.column("allostasisMode", .text).notNull()
                t.column("createdAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // Indices for common query patterns
            // ──────────────────────────────────────────────
            try db.create(
                index: "idx_messages_conversationId_createdAt",
                on: "messages",
                columns: ["conversationId", "createdAt"],
            )
            try db.create(
                index: "idx_lcm_nodes_conversationId_depth",
                on: "lcm_nodes",
                columns: ["conversationId", "depth"],
            )
            try db.create(
                index: "idx_lcm_nodes_hotness",
                on: "lcm_nodes",
                columns: ["hotness"],
            )
            try db.create(
                index: "idx_identity_claims_versionId",
                on: "identity_claims",
                columns: ["versionId"],
            )
            try db.create(
                index: "idx_mirror_claims_versionId",
                on: "mirror_claims",
                columns: ["versionId"],
            )
            try db.create(
                index: "idx_claim_evidence_claimId_claimTable",
                on: "claim_evidence",
                columns: ["claimId", "claimTable"],
            )
        }

        migrator.registerMigration("v2_observerTables") { db in
            // ──────────────────────────────────────────────
            // 20. Plate snapshots — observer hidden state persistence
            // ──────────────────────────────────────────────
            try db.create(table: "plate_snapshots") { t in
                t.autoIncrementedPrimaryKey("snapshotId")
                t.column("cycleNumber", .integer).notNull().unique()
                t.column("plateVector", .blob).notNull()
                t.column("plateEntropy", .double).notNull()
                t.column("plateMagnitude", .double).notNull()
                t.column("generatedText", .text).notNull()
                t.column("inputDigest", .text)
                t.column("capturedAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 21. Plate archive — downsampled historical plate vectors
            // ──────────────────────────────────────────────
            try db.create(table: "plate_archive") { t in
                t.autoIncrementedPrimaryKey("archiveId")
                t.column("cycleRange", .text).notNull()
                t.column("meanVector", .blob).notNull()
                t.column("maxEntropy", .double).notNull()
                t.column("minEntropy", .double).notNull()
                t.column("archivedAt", .text).notNull()
            }

            // ──────────────────────────────────────────────
            // 22. Observer signals — interoception channel text
            // ──────────────────────────────────────────────
            try db.create(table: "observer_signals") { t in
                t.autoIncrementedPrimaryKey("signalId")
                t.column("cycleNumber", .integer).notNull()
                    .references("plate_snapshots", column: "cycleNumber")
                t.column("signalText", .text).notNull()
                t.column("salienceScore", .double)
                t.column("wasPromoted", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .text).notNull()
            }

            try db.create(
                index: "idx_plate_snapshots_cycleNumber",
                on: "plate_snapshots",
                columns: ["cycleNumber"],
            )
            try db.create(
                index: "idx_observer_signals_createdAt",
                on: "observer_signals",
                columns: ["createdAt"],
            )
        }

        migrator.registerMigration("v3_todos") { db in
            try db.create(table: "todos") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sessionKey", .text).notNull()
                t.column("content", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("priority", .text).notNull().defaults(to: "medium")
                t.column("position", .integer).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(indexOn: "todos", columns: ["sessionKey"])
        }

        migrator.registerMigration("v4_cronJobs") { db in
            try db.create(table: "cron_jobs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("jobId", .text).notNull().unique()
                t.column("name", .text).notNull()
                t.column("prompt", .text).notNull()
                t.column("scheduleKind", .text).notNull()
                t.column("scheduleExpr", .text)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("deliverTo", .text).notNull().defaults(to: "local")
                t.column("skill", .text)
                t.column("repeatTimes", .integer)
                t.column("completedCount", .integer).notNull().defaults(to: 0)
                t.column("nextRunAt", .datetime)
                t.column("lastRunAt", .datetime)
                t.column("lastStatus", .text)
                t.column("lastError", .text)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v5_fileVersions") { db in
            try db.create(table: "file_versions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("conversationId", .integer).notNull()
                t.column("filePath", .text).notNull()
                t.column("content", .blob).notNull()
                t.column("mutationTool", .text).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(indexOn: "file_versions", columns: ["conversationId", "filePath"])
        }

        // ──────────────────────────────────────────────
        // Plan 4B: Embedding-based semantic search
        // ──────────────────────────────────────────────
        migrator.registerMigration("v6_nodeEmbeddings") { db in
            try db.create(table: "node_embeddings") { t in
                t.primaryKey("nodeId", .text)
                t.column("embedding", .blob).notNull()
                t.column("dimensions", .integer).notNull()
                t.column("provider", .text).notNull()
                t.column("createdAt", .text).notNull()
            }
        }

        return migrator
    }
}
