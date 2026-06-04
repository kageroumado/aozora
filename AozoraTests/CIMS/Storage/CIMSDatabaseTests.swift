import GRDB
import Testing
@testable import Aozora

@Suite("CIMSDatabase")
struct CIMSDatabaseTests {
    private func makeDatabase() throws -> CIMSDatabase {
        try CIMSDatabase.inMemory()
    }

    // MARK: - Table Creation

    @Test
    func `All tables are created`() throws {
        let cims = try makeDatabase()
        let expectedTables: Set = [
            "conversations",
            "messages",
            "message_parts",
            "lcm_nodes",
            "lcm_edges",
            "lcm_frontier",
            "lcm_cold_payloads",
            "large_files",
            "context_items",
            "identity_versions",
            "identity_claims",
            "users",
            "mirror_versions",
            "mirror_claims",
            "claim_evidence",
            "delegation_grants",
            "consolidation_jobs",
            "chrono_state",
            "allostatic_state",
            "cognitive_traces",
        ]

        let tables = try cims.dbPool.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT name FROM sqlite_master
                WHERE type IN ('table', 'view')
                  AND name NOT LIKE 'sqlite_%'
                  AND name NOT LIKE 'grdb_%'
                ORDER BY name
                """,
            )
        }

        let tableSet = Set(tables)
        for expected in expectedTables {
            #expect(tableSet.contains(expected), "Missing table: \(expected)")
        }

        // FTS5 is a virtual table
        let virtualTables = try cims.dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND sql LIKE '%fts5%'",
            )
        }
        #expect(virtualTables.contains("lcm_fts"))
    }

    // MARK: - FTS5

    @Test
    func `FTS5 virtual table exists and accepts inserts`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            try db.execute(
                sql: """
                INSERT INTO lcm_fts (content, nodeId, conversationId, depth, kind)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: ["Hello world, this is a test message", "node_abc123", 1, 0, "raw_turn"],
            )
            try db.execute(
                sql: """
                INSERT INTO lcm_fts (content, nodeId, conversationId, depth, kind)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    "Another message about Swift concurrency", "node_def456", 1, 0, "raw_turn",
                ],
            )
        }

        let results = try cims.dbPool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT nodeId, rank FROM lcm_fts WHERE lcm_fts MATCH ?
                ORDER BY rank
                """,
                arguments: ["concurrency"],
            )
        }

        #expect(results.count == 1)
        #expect(results[0]["nodeId"] as String == "node_def456")
    }

    // MARK: - Foreign Keys

    @Test
    func `Foreign key constraints are enforced`() throws {
        let cims = try makeDatabase()

        #expect(throws: (any Error).self) {
            try cims.dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO messages (conversationId, role, content, tokenEstimate, createdAt)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [9_999, "user", "orphan message", 10, "2026-01-01T00:00:00Z"],
                )
            }
        }
    }

    // MARK: - Record CRUD

    @Test
    func `Conversation record roundtrip`() throws {
        let cims = try makeDatabase()

        var conversation = ConversationRecord(
            sessionKey: "session-1",
            userKey: "alice",
            startedAt: "2026-01-01T00:00:00Z",
            lastMessageAt: nil,
            messageCount: 0,
        )

        try cims.dbPool.write { db in
            try conversation.insert(db)
        }

        let fetched = try cims.dbPool.read { db in
            try ConversationRecord.fetchOne(db, key: conversation.id)
        }

        #expect(fetched != nil)
        #expect(fetched?.sessionKey == "session-1")
        #expect(fetched?.userKey == "alice")
    }

    @Test
    func `Message record with parts`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            var conversation = ConversationRecord(
                sessionKey: "session-2",
                userKey: "alice",
                startedAt: "2026-01-01T00:00:00Z",
                lastMessageAt: nil,
                messageCount: 0,
            )
            try conversation.insert(db)

            var message = MessageRecord(
                conversationId: conversation.id!,
                role: "user",
                content: "Hello world",
                tokenEstimate: 3,
                salienceScore: 0.7,
                createdAt: "2026-01-01T00:00:01Z",
            )
            try message.insert(db)

            var part = MessagePartRecord(
                messageId: message.id!,
                partKind: "text",
                ordinal: 0,
                content: "Hello world",
                metadata: nil,
            )
            try part.insert(db)
        }

        let parts = try cims.dbPool.read { db in
            try MessagePartRecord.fetchAll(db)
        }

        #expect(parts.count == 1)
        #expect(parts[0].partKind == "text")
        #expect(parts[0].content == "Hello world")
    }

    @Test
    func `LCM node and edge records`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            var conversation = ConversationRecord(
                sessionKey: "session-3",
                userKey: "alice",
                startedAt: "2026-01-01T00:00:00Z",
                lastMessageAt: nil,
                messageCount: 0,
            )
            try conversation.insert(db)

            let node1 = LCMNodeRecord(
                nodeId: "node_aaa111",
                conversationId: conversation.id!,
                depth: 0,
                kind: "raw_turn",
                tokenCount: 100,
                checksum: nil,
                salienceScore: 0.5,
                hotness: 1.0,
                isCold: 0,
                canonicalText: "First message",
                summaryText: nil,
                expandFooter: nil,
                earliestAt: "2026-01-01T00:00:00Z",
                latestAt: "2026-01-01T00:00:00Z",
                lastAccessedAt: "2026-01-01T00:00:00Z",
                version: 1,
                createdAt: "2026-01-01T00:00:00Z",
            )
            try node1.insert(db)

            let node2 = LCMNodeRecord(
                nodeId: "node_bbb222",
                conversationId: conversation.id!,
                depth: 0,
                kind: "raw_turn",
                tokenCount: 150,
                checksum: nil,
                salienceScore: 0.6,
                hotness: 1.0,
                isCold: 0,
                canonicalText: "Second message",
                summaryText: nil,
                expandFooter: nil,
                earliestAt: "2026-01-01T00:01:00Z",
                latestAt: "2026-01-01T00:01:00Z",
                lastAccessedAt: "2026-01-01T00:01:00Z",
                version: 1,
                createdAt: "2026-01-01T00:01:00Z",
            )
            try node2.insert(db)

            let edge = LCMEdgeRecord(
                fromNodeId: "node_aaa111",
                toNodeId: "node_bbb222",
                edgeKind: "temporal_next",
            )
            try edge.insert(db)
        }

        let edges = try cims.dbPool.read { db in
            try LCMEdgeRecord.fetchAll(db)
        }

        #expect(edges.count == 1)
        #expect(edges[0].edgeKind == "temporal_next")
    }

    @Test
    func `Identity version and claims roundtrip`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            var version = IdentityVersionRecord(
                previousVersion: nil,
                isActive: true,
                createdAt: "2026-01-01T00:00:00Z",
                createdBy: "bootstrap",
                rationale: "Initial bootstrap",
            )
            try version.insert(db)

            var claim = IdentityClaimRecord(
                versionId: version.versionId!,
                claimKey: "self.communication_style",
                value: "concise and direct",
                confidence: 0.7,
                epistemicStatus: "hypothesis",
                evidenceCount: 1,
                evidenceDiversity: 1,
                decayHalfLifeDays: 90,
                createdAt: "2026-01-01T00:00:00Z",
                lastReinforcedAt: "2026-01-01T00:00:00Z",
            )
            try claim.insert(db)
        }

        let claims = try cims.dbPool.read { db in
            try IdentityClaimRecord.fetchAll(db)
        }

        #expect(claims.count == 1)
        #expect(claims[0].claimKey == "self.communication_style")
        #expect(claims[0].confidence == 0.7)
    }

    @Test
    func `User and mirror version roundtrip`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            let user = UserRecord(
                userKey: "alice",
                displayName: "Alice",
                firstSeenAt: "2026-01-01T00:00:00Z",
                lastInteractionAt: "2026-01-01T00:00:00Z",
                sessionCount: 1,
                isBootstrap: true,
            )
            try user.insert(db)

            var mirrorVersion = MirrorVersionRecord(
                userKey: "alice",
                previousVersion: nil,
                isActive: true,
                createdAt: "2026-01-01T00:00:00Z",
                createdBy: "bootstrap",
                rationale: nil,
            )
            try mirrorVersion.insert(db)

            var claim = MirrorClaimRecord(
                versionId: mirrorVersion.versionId!,
                claimKey: "mirror.alice.expertise",
                value: "Swift and Apple platform development",
                confidence: 0.8,
                epistemicStatus: "asserted",
                evidenceCount: 5,
                evidenceDiversity: 3,
                decayHalfLifeDays: 60,
                createdAt: "2026-01-01T00:00:00Z",
                lastReinforcedAt: "2026-01-01T00:00:00Z",
            )
            try claim.insert(db)
        }

        let claims = try cims.dbPool.read { db in
            try MirrorClaimRecord.fetchAll(db)
        }

        #expect(claims.count == 1)
        #expect(claims[0].claimKey == "mirror.alice.expertise")
    }

    @Test
    func `Allostatic state singleton constraint`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            let state = AllostaticStateRecord(
                id: 1,
                mode: "balanced",
                recentLatencyMs: nil,
                recentErrorRate: 0,
                tokenBudgetUsed: 0,
                updatedAt: "2026-01-01T00:00:00Z",
            )
            try state.insert(db)
        }

        // Separate write call so the first transaction is fully committed
        #expect(throws: (any Error).self) {
            try cims.dbPool.write { db in
                let duplicate = AllostaticStateRecord(
                    id: 2,
                    mode: "conservative",
                    recentLatencyMs: nil,
                    recentErrorRate: 0.5,
                    tokenBudgetUsed: 1_000,
                    updatedAt: "2026-01-01T00:01:00Z",
                )
                try duplicate.insert(db)
            }
        }
    }

    @Test
    func `Delegation grant record lifecycle`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            var grant = DelegationGrantRecord(
                grantId: "grant-1",
                conversationScope: "[1,2,3]",
                tokenCap: 50_000,
                tokensUsed: 0,
                operations: "[\"grep\",\"expand\"]",
                createdAt: "2026-01-01T00:00:00Z",
                expiresAt: "2026-01-01T00:05:00Z",
                revokedAt: nil,
                workerRunId: "worker-1",
            )
            try grant.insert(db)

            grant.revokedAt = "2026-01-01T00:02:00Z"
            grant.tokensUsed = 12_000
            try grant.update(db)
        }

        let grant = try cims.dbPool.read { db in
            try DelegationGrantRecord.fetchOne(db, key: "grant-1")
        }

        #expect(grant?.revokedAt == "2026-01-01T00:02:00Z")
        #expect(grant?.tokensUsed == 12_000)
    }

    @Test
    func `Consolidation job record`() throws {
        let cims = try makeDatabase()

        try cims.dbPool.write { db in
            var job = ConsolidationJobRecord(
                jobId: "job-1",
                trigger: "idle_timeout",
                status: "pending",
                startedAt: nil,
                completedAt: nil,
                bumpsDetected: nil,
                claimsExtracted: nil,
                nodesCompacted: nil,
                nodesDecayed: nil,
                error: nil,
                createdAt: "2026-01-01T00:00:00Z",
            )
            try job.insert(db)

            job.status = "completed"
            job.startedAt = "2026-01-01T00:00:01Z"
            job.completedAt = "2026-01-01T00:00:30Z"
            job.bumpsDetected = 3
            job.claimsExtracted = 2
            job.nodesCompacted = 15
            job.nodesDecayed = 8
            try job.update(db)
        }

        let job = try cims.dbPool.read { db in
            try ConsolidationJobRecord.fetchOne(db, key: "job-1")
        }

        #expect(job?.status == "completed")
        #expect(job?.bumpsDetected == 3)
        #expect(job?.nodesCompacted == 15)
    }

    // MARK: - Unique Constraints

    @Test
    func `Identity claims unique per version+key`() throws {
        let cims = try makeDatabase()

        // Insert the first claim
        try cims.dbPool.write { db in
            var version = IdentityVersionRecord(
                previousVersion: nil,
                isActive: true,
                createdAt: "2026-01-01T00:00:00Z",
                createdBy: "bootstrap",
                rationale: nil,
            )
            try version.insert(db)

            var claim = IdentityClaimRecord(
                versionId: version.versionId!,
                claimKey: "self.style",
                value: "direct",
                confidence: 0.5,
                epistemicStatus: "hypothesis",
                evidenceCount: 1,
                evidenceDiversity: 1,
                decayHalfLifeDays: 90,
                createdAt: "2026-01-01T00:00:00Z",
                lastReinforcedAt: "2026-01-01T00:00:00Z",
            )
            try claim.insert(db)
        }

        // Duplicate insert in a separate write — the error propagates cleanly
        let versionId = try cims.dbPool.read { db in
            try IdentityVersionRecord.fetchOne(db)!.versionId!
        }

        #expect(throws: (any Error).self) {
            try cims.dbPool.write { db in
                var duplicate = IdentityClaimRecord(
                    versionId: versionId,
                    claimKey: "self.style",
                    value: "verbose",
                    confidence: 0.3,
                    epistemicStatus: "hypothesis",
                    evidenceCount: 1,
                    evidenceDiversity: 1,
                    decayHalfLifeDays: 90,
                    createdAt: "2026-01-01T00:00:00Z",
                    lastReinforcedAt: "2026-01-01T00:00:00Z",
                )
                try duplicate.insert(db)
            }
        }
    }

    @Test
    func `Cascade delete removes messages when conversation deleted`() throws {
        let cims = try makeDatabase()

        var conversationId: Int64 = 0

        try cims.dbPool.write { db in
            var conversation = ConversationRecord(
                sessionKey: "session-cascade",
                userKey: "alice",
                startedAt: "2026-01-01T00:00:00Z",
                lastMessageAt: nil,
                messageCount: 1,
            )
            try conversation.insert(db)
            conversationId = conversation.id!

            var message = MessageRecord(
                conversationId: conversationId,
                role: "user",
                content: "test",
                tokenEstimate: 1,
                salienceScore: nil,
                createdAt: "2026-01-01T00:00:00Z",
            )
            try message.insert(db)
        }

        let countBefore = try cims.dbPool.read { db in
            try MessageRecord.fetchCount(db)
        }
        #expect(countBefore == 1)

        try cims.dbPool.write { db in
            _ = try ConversationRecord.deleteOne(db, key: conversationId)
        }

        let countAfter = try cims.dbPool.read { db in
            try MessageRecord.fetchCount(db)
        }
        #expect(countAfter == 0)
    }
}
