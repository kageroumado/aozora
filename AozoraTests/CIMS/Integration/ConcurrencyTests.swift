import Foundation
import Testing
@testable import Aozora

/// Concurrency and stress tests for the CIMS coordinator.
///
/// These tests exercise queue management, turn cancellation, concurrent turn processing,
/// and edge cases that only surface under concurrent access patterns.
struct CIMSConcurrencyTests {
    // MARK: - Helpers

    private func makeGateway() async throws -> CIMSGateway {
        try await CIMSGateway.inMemory()
    }

    private func makeRequest(
        _ text: String,
        userKey: UserKey = "test-user",
    ) -> TurnRequest {
        TurnRequest(
            turnID: UUID().uuidString,
            sessionKey: "test-session",
            userKey: userKey,
            message: InboundMessage(
                text: text,
                parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
                metadata: nil,
            ),
            receivedAt: Date(),
        )
    }

    // MARK: - Queue Management

    @Test
    func `Turn cancellation for nonexistent ID is safe`() async throws {
        let gateway = try await makeGateway()
        await gateway.coordinator.cancelTurn("nonexistent-turn-id")
        // No crash = success
    }

    @Test
    func `Multiple sequential turns all complete successfully`() async throws {
        let gateway = try await makeGateway()

        for i in 0 ..< 10 {
            let request = makeRequest("Sequential message \(i)")
            let events = try await runTurnCollecting(gateway.coordinator, request)

            let completed = events.contains { event in
                if case .responseCompleted = event { return true }
                return false
            }
            #expect(completed, "Turn \(i) should complete successfully")
        }
    }

    // MARK: - Concurrent Access

    @Test
    func `Concurrent turns from different users`() async throws {
        let gateway = try await makeGateway()

        // Launch turns for different users concurrently
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0 ..< 3 {
                group.addTask {
                    let request = TurnRequest(
                        turnID: UUID().uuidString,
                        sessionKey: "session-\(i)",
                        userKey: "user-\(i)",
                        message: InboundMessage(
                            text: "Hello from user \(i)",
                            parts: [MessagePart(kind: .text, ordinal: 0, content: "Hello from user \(i)", metadata: nil)],
                            metadata: nil,
                        ),
                        receivedAt: Date(),
                    )
                    let events = try await runTurnCollecting(gateway.coordinator, request)
                    let completed = events.contains { e in
                        if case .responseCompleted = e { return true }
                        return false
                    }
                    #expect(completed, "User \(i) turn should complete")
                }
            }

            try await group.waitForAll()
        }
    }

    // MARK: - Gateway Lifecycle

    @Test
    func `Multiple gateways are independent`() async throws {
        let gateway1 = try await makeGateway()
        let gateway2 = try await makeGateway()

        // Ingest into gateway 1
        let req1 = makeRequest("Only in gateway 1")
        _ = try await runTurnCollecting(gateway1.coordinator, req1)

        // Gateway 2 should have no memory of gateway 1's messages
        let tail2 = await gateway2.memoryStore.freshTail(count: 10, for: 1)
        #expect(tail2.isEmpty, "Gateway 2 should not see gateway 1's messages")

        // Gateway 1 should have the message
        let tail1 = await gateway1.memoryStore.freshTail(count: 10, for: 1)
        #expect(!tail1.isEmpty, "Gateway 1 should have its own messages")
    }

    @Test
    func `In-memory gateway creates fresh state each time`() async throws {
        let gateway = try await makeGateway()

        let identity = await gateway.identityStore.currentIdentity()
        #expect(identity.claims.isEmpty, "Fresh gateway should have no identity claims")

        let mirror = await gateway.identityStore.currentMirror(for: "any-user")
        #expect(mirror.claims.isEmpty, "Fresh gateway should have no mirror claims")
    }

    // MARK: - Memory Store Concurrency

    @Test
    func `Concurrent grep operations don't interfere`() async throws {
        let gateway = try await makeGateway()

        // Ingest several messages with different content
        let topics = ["Swift concurrency", "GRDB database", "SwiftUI views", "WebKit rendering"]
        for topic in topics {
            let request = makeRequest("Discussing \(topic) in depth.")
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // Run concurrent grep operations
        try await withThrowingTaskGroup(of: [GrepMatch].self) { group in
            for topic in topics {
                let keyword = topic.split(separator: " ").first.map(String.init) ?? topic
                group.addTask {
                    await gateway.memoryStore.grep(pattern: keyword, mode: .fullText, scope: .all)
                }
            }

            var allResults: [[GrepMatch]] = []
            for try await result in group {
                allResults.append(result)
            }

            // At least some searches should find matches
            let totalMatches = allResults.reduce(0) { $0 + $1.count }
            #expect(totalMatches > 0, "At least some grep operations should find matches")
        }
    }

    // MARK: - Consolidation Engine

    @Test
    func `Consolidation can run on empty database without errors`() async throws {
        let gateway = try await makeGateway()
        await gateway.consolidationEngine.consolidate(trigger: .manual)
        // No crash = success
    }

    @Test
    func `Consolidation after ingestion completes without errors`() async throws {
        let gateway = try await makeGateway()

        // Ingest some messages first
        for i in 0 ..< 5 {
            let request = makeRequest("Message \(i) for consolidation testing")
            _ = try await runTurnCollecting(gateway.coordinator, request)
        }

        // Run consolidation
        await gateway.consolidationEngine.consolidate(trigger: .sessionEnd)
        // No crash = success
    }

    // MARK: - Delegation Grant Lifecycle

    @Test
    func `Delegation grant creation and revocation`() async throws {
        let gateway = try await makeGateway()

        let scope = DelegationScope(
            conversationScope: .all,
            operations: [.grep, .describe],
            tokenCap: 10_000,
        )

        let grant = await gateway.memoryStore.createDelegationGrant(scope: scope)
        #expect(!grant.grantId.isEmpty, "Grant should have a non-empty ID")
        #expect(grant.operations.contains(.grep))
        #expect(grant.operations.contains(.describe))

        // Revoke should not crash
        await gateway.memoryStore.revokeDelegationGrant(grant.grantId)
    }

    // MARK: - Identity Store Concurrency

    @Test
    func `Concurrent mirror access for different users`() async throws {
        let gateway = try await makeGateway()

        try await withThrowingTaskGroup(of: MirrorBlock.self) { group in
            for i in 0 ..< 5 {
                group.addTask {
                    await gateway.identityStore.currentMirror(for: "user-\(i)")
                }
            }

            var mirrors: [MirrorBlock] = []
            for try await mirror in group {
                mirrors.append(mirror)
            }

            #expect(mirrors.count == 5, "All 5 mirror accesses should complete")

            // Each mirror should be for a different user
            let userKeys = Set(mirrors.map(\.userKey))
            #expect(userKeys.count == 5, "Each mirror should be for a distinct user")
        }
    }
}
