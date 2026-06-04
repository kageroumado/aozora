import Foundation
import GRDB
import Testing
@testable import Aozora

@Suite("ConsolidationEngine")
struct ConsolidationEngineTests {
    /// Create a fully wired consolidation engine with in-memory database and mock model.
    private func makeEngine(
        defaultResponse: String = """
        {"nothingSignificant": true, "rationale": "No significant identity insights.", "identityProposals": [], "mirrorProposals": []}
        """,
    ) async throws -> (ConsolidationEngine, CIMSDatabase, MockModelProvider, IdentityStore) {
        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider(defaultResponse: defaultResponse)
        let identityStore = try await IdentityStore(database: db)
        let memoryStore = MemoryStore(database: db)
        let engine = ConsolidationEngine(
            database: db,
            identityStore: identityStore,
            model: model,
            memoryStore: memoryStore,
        )
        return (engine, db, model, identityStore)
    }

    /// Helper to create a minimal inbound message.
    private func makeMessage(_ text: String) -> InboundMessage {
        InboundMessage(
            text: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            metadata: nil,
        )
    }

    /// Helper to create a minimal assistant response.
    private func makeResponse(_ text: String) -> AssistantResponse {
        AssistantResponse(
            content: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            toolCalls: [],
            tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 10),
            latency: .seconds(1),
        )
    }

    // MARK: - Full Pipeline

    @Test
    func `Full pipeline creates and completes a consolidation job`() async throws {
        let (engine, db, _, _) = try await makeEngine()

        await engine.consolidate(trigger: .manual)

        let jobs = try await db.dbPool.read { db in
            try ConsolidationJobRecord.fetchAll(db)
        }
        #expect(jobs.count == 1)
        #expect(jobs[0].status == "completed")
        #expect(jobs[0].trigger == "manual")
        #expect(jobs[0].startedAt != nil)
        #expect(jobs[0].completedAt != nil)
        #expect(jobs[0].error == nil)
    }

    @Test
    func `Pipeline with no data produces nothingSignificant`() async throws {
        let (engine, db, _, _) = try await makeEngine()

        await engine.consolidate(trigger: .idleTimeout)

        let job = try await db.dbPool.read { db in
            try ConsolidationJobRecord.fetchOne(db)
        }
        #expect(job?.status == "completed")
        #expect(job?.bumpsDetected == 0)
        #expect(job?.claimsExtracted == 0)
    }

    @Test
    func `Pipeline with bumps extracts claims when model returns proposals`() async throws {
        let claimResponse = """
        {
            "nothingSignificant": false,
            "rationale": "User shows clear preference for depth over breadth.",
            "identityProposals": [
                {
                    "claimKey": "self.values.depth",
                    "value": "Prefers deep analysis over surface-level answers",
                    "confidence": 0.7,
                    "evidenceType": "behavior",
                    "excerpt": "I just realized I always prefer depth"
                }
            ],
            "mirrorProposals": [
                {
                    "claimKey": "mirror.user.expertise",
                    "value": "Expert in Swift concurrency",
                    "confidence": 0.6,
                    "evidenceType": "inference",
                    "excerpt": "discussing actor isolation"
                }
            ]
        }
        """

        let db = try CIMSDatabase.inMemory()
        let model = MockModelProvider(defaultResponse: "Summary of the conversation.")
        let identityStore = try await IdentityStore(database: db)
        let store = MemoryStore(database: db)

        await store.ingest(
            makeMessage("I just realized I always prefer depth over surface-level explanations"),
            response: makeResponse("That's a valuable insight about your learning style"),
        )

        await model.enqueueText(claimResponse)
        await model.enqueueText("Summary of conversation about depth preferences.")

        let engine = ConsolidationEngine(
            database: db,
            identityStore: identityStore,
            model: model,
            memoryStore: store,
        )

        await engine.consolidate(trigger: .manual)

        let job = try await db.dbPool.read { dbConn in
            try ConsolidationJobRecord.fetchOne(dbConn)
        }
        #expect(job?.status == "completed")
    }

    // MARK: - Job Tracking

    @Test
    func `Each consolidation run creates a unique job record`() async throws {
        let (engine, db, _, _) = try await makeEngine()

        await engine.consolidate(trigger: .manual)
        await engine.consolidate(trigger: .idleTimeout)
        await engine.consolidate(trigger: .sessionEnd)

        let jobs = try await db.dbPool.read { db in
            try ConsolidationJobRecord.fetchAll(db)
        }
        #expect(jobs.count == 3)

        let jobIds = Set(jobs.map(\.jobId))
        #expect(jobIds.count == 3, "Each job should have a unique ID")

        let triggers = jobs.map(\.trigger)
        #expect(triggers.contains("manual"))
        #expect(triggers.contains("idle_timeout"))
        #expect(triggers.contains("session_end"))
    }

    @Test
    func `Job records track pipeline metrics`() async throws {
        let (engine, db, _, _) = try await makeEngine()

        await engine.consolidate(trigger: .manual)

        let job = try await db.dbPool.read { db in
            try ConsolidationJobRecord.fetchOne(db)
        }
        #expect(job != nil)
        #expect(job?.bumpsDetected != nil)
        #expect(job?.claimsExtracted != nil)
        #expect(job?.nodesCompacted != nil)
        #expect(job?.nodesDecayed != nil)
    }

    // MARK: - Trigger Types

    @Test
    func `All trigger types are properly recorded`() async throws {
        let triggers: [ConsolidationTrigger] = [.idleTimeout, .sessionEnd, .manual, .scheduled]

        for trigger in triggers {
            let (engine, db, _, _) = try await makeEngine()
            await engine.consolidate(trigger: trigger)

            let job = try await db.dbPool.read { db in
                try ConsolidationJobRecord.fetchOne(db)
            }
            #expect(job?.trigger == trigger.rawValue)
        }
    }

    // MARK: - Claim Extraction

    @Test
    func `ClaimExtractor returns nothingSignificant for empty candidates`() async throws {
        let model = MockModelProvider()
        let extractor = ClaimExtractor(model: model)

        let proposal = try await extractor.extractClaims(from: [])
        #expect(proposal.nothingSignificant)
        #expect(proposal.identityProposals.isEmpty)
        #expect(proposal.mirrorProposals.isEmpty)
    }

    @Test
    func `ClaimExtractor parses valid JSON response`() async throws {
        let model = MockModelProvider(defaultResponse: """
        {
            "nothingSignificant": false,
            "rationale": "Found clear identity signal.",
            "identityProposals": [
                {
                    "claimKey": "self.style",
                    "value": "Concise communicator",
                    "confidence": 0.8,
                    "evidenceType": "behavior"
                }
            ],
            "mirrorProposals": []
        }
        """)
        let extractor = ClaimExtractor(model: model)

        let candidates = [
            BumpCandidate(
                nodeId: "node_test",
                reason: .correctionOrDiscovery,
                salienceScore: 0.8,
                content: "I just realized I prefer concise communication",
            ),
        ]

        let proposal = try await extractor.extractClaims(from: candidates)
        #expect(!proposal.nothingSignificant)
        #expect(proposal.identityProposals.count == 1)
        #expect(proposal.identityProposals[0].claimKey == "self.style")
        #expect(proposal.identityProposals[0].value == "Concise communicator")
    }

    @Test
    func `ClaimExtractor handles malformed model response gracefully`() async throws {
        let model = MockModelProvider(defaultResponse: "This is not JSON at all, just plain text.")
        let extractor = ClaimExtractor(model: model)

        let candidates = [
            BumpCandidate(
                nodeId: "node_test",
                reason: .emotionalIntensity,
                salienceScore: 0.7,
                content: "I love working on this project",
            ),
        ]

        let proposal = try await extractor.extractClaims(from: candidates)
        #expect(proposal.nothingSignificant)
    }

    // MARK: - BumpDetector

    @Test
    func `BumpDetector detects correction patterns`() async throws {
        let db = try CIMSDatabase.inMemory()
        let store = MemoryStore(database: db)

        await store.ingest(
            makeMessage("I just realized I was wrong about the architecture approach"),
            response: makeResponse("That's a good insight, let's revise the plan"),
        )

        let detector = BumpDetector(database: db)
        let bumps = try await detector.scanForBumps(since: Date().addingTimeInterval(-3_600))

        #expect(!bumps.isEmpty)
        #expect(bumps.contains(where: { $0.reason == BumpReason.correctionOrDiscovery }))
    }

    @Test
    func `BumpDetector detects emotional intensity`() async throws {
        let db = try CIMSDatabase.inMemory()
        let store = MemoryStore(database: db)

        await store.ingest(
            makeMessage("I love this framework, it's amazing for building apps"),
            response: makeResponse("I'm glad you're enjoying it!"),
        )

        let detector = BumpDetector(database: db)
        let bumps = try await detector.scanForBumps(since: Date().addingTimeInterval(-3_600))

        #expect(!bumps.isEmpty)
        #expect(bumps.contains(where: { $0.reason == BumpReason.emotionalIntensity }))
    }

    @Test
    func `BumpDetector detects novel entities`() async throws {
        let db = try CIMSDatabase.inMemory()
        let store = MemoryStore(database: db)

        await store.ingest(
            makeMessage("I'm working on a new project called Lumen, a WebKit browser"),
            response: makeResponse("That sounds interesting! Tell me more about Lumen"),
        )

        let detector = BumpDetector(database: db)
        let bumps = try await detector.scanForBumps(since: Date().addingTimeInterval(-3_600))

        #expect(!bumps.isEmpty)
        #expect(bumps.contains(where: { $0.reason == BumpReason.novelEntity }))
    }

    @Test
    func `BumpDetector returns empty for neutral content`() async throws {
        let db = try CIMSDatabase.inMemory()
        let store = MemoryStore(database: db)

        await store.ingest(
            makeMessage("What time is it?"),
            response: makeResponse("It is 3:00 PM"),
        )

        let detector = BumpDetector(database: db)

        let node = try await db.dbPool.read { dbConn in
            try LCMNodeRecord.fetchOne(dbConn)
        }
        #expect(node?.salienceScore == 0.0)

        let bumps = try await detector.scanForBumps(since: Date().addingTimeInterval(-3_600))
        #expect(bumps.isEmpty)
    }
}
