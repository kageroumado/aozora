import Foundation
import GRDB
import Testing
@testable import Aozora

@Suite("IdentityStore")
struct IdentityStoreTests {
    /// Create a fresh in-memory database and identity store for each test.
    private func makeStore() async throws -> (IdentityStore, CIMSDatabase) {
        let db = try CIMSDatabase.inMemory()
        let store = try await IdentityStore(database: db)
        return (store, db)
    }

    // MARK: - Bootstrap

    @Test
    func `Bootstrap creates an active identity version on init`() async throws {
        let (_, db) = try await makeStore()

        let versions = try await db.dbPool.read { db in
            try IdentityVersionRecord.fetchAll(db)
        }
        #expect(versions.count == 1)
        #expect(versions[0].isActive == true)
        #expect(versions[0].createdBy == "bootstrap")
        #expect(versions[0].previousVersion == nil)
    }

    @Test
    func `Bootstrap is idempotent — second init doesn't create duplicate version`() async throws {
        let db = try CIMSDatabase.inMemory()
        _ = try await IdentityStore(database: db)
        _ = try await IdentityStore(database: db)

        let versions = try await db.dbPool.read { db in
            try IdentityVersionRecord.fetchAll(db)
        }
        #expect(versions.count == 1)
    }

    @Test
    func `currentIdentity returns empty block with no claims after bootstrap`() async throws {
        let (store, _) = try await makeStore()

        let identity = await store.currentIdentity()
        #expect(identity.claims.isEmpty)
        #expect(identity.createdBy == "bootstrap")
        #expect(identity.versionId > 0)
    }

    // MARK: - Mirror Bootstrap

    @Test
    func `currentMirror creates user and mirror version for new users`() async throws {
        let (store, db) = try await makeStore()

        let mirror = await store.currentMirror(for: "alice")
        #expect(mirror.userKey == "alice")
        #expect(mirror.claims.isEmpty)
        #expect(mirror.createdBy == "bootstrap")

        let user = try await db.dbPool.read { db in
            try UserRecord.fetchOne(db, key: "alice")
        }
        #expect(user != nil)
        #expect(user?.isBootstrap == true)
    }

    @Test
    func `currentMirror is idempotent for the same user`() async throws {
        let (store, db) = try await makeStore()

        _ = await store.currentMirror(for: "alice")
        _ = await store.currentMirror(for: "alice")

        let versions = try await db.dbPool.read { db in
            try MirrorVersionRecord
                .filter(Column("userKey") == "alice")
                .fetchAll(db)
        }
        #expect(versions.count == 1)
    }

    // MARK: - Merge Claims (Identity)

    @Test
    func `Merge new identity claims creates them as hypotheses`() async throws {
        let (store, _) = try await makeStore()

        let candidates = [
            ClaimCandidate(
                claimKey: "self.communication_style",
                value: "concise and direct",
                confidence: 0.6,
                evidenceType: .behavior,
                excerpt: "Observed pattern",
                nodeId: nil,
            ),
        ]

        await store.mergeClaims(candidates, target: .identity)

        let identity = await store.currentIdentity()
        #expect(identity.claims.count == 1)
        #expect(identity.claims[0].claimKey == "self.communication_style")
        #expect(identity.claims[0].value == "concise and direct")
        #expect(identity.claims[0].epistemicStatus == .hypothesis)
        #expect(identity.claims[0].evidenceCount == 1)
        #expect(identity.createdBy == "consolidation")
    }

    @Test
    func `Merge reinforces existing identity claims with matching key and value`() async throws {
        let (store, _) = try await makeStore()

        let candidate = ClaimCandidate(
            claimKey: "self.depth_seeking",
            value: "prefers deep analysis",
            confidence: 0.6,
            evidenceType: .behavior,
            excerpt: nil,
            nodeId: nil,
        )

        await store.mergeClaims([candidate], target: .identity)

        let beforeIdentity = await store.currentIdentity()
        let beforeConfidence = beforeIdentity.claims.first?.confidence ?? 0
        let beforeEvidence = beforeIdentity.claims.first?.evidenceCount ?? 0

        await store.mergeClaims([candidate], target: .identity)

        let afterIdentity = await store.currentIdentity()
        let claim = afterIdentity.claims.first { $0.claimKey == "self.depth_seeking" }
        #expect(claim != nil)
        #expect(try #require(claim?.confidence) > beforeConfidence)
        #expect(claim?.evidenceCount == beforeEvidence + 1)
    }

    @Test
    func `Merge promotes hypothesis to asserted when diversity threshold met`() async throws {
        let (store, _) = try await makeStore()

        let candidate = ClaimCandidate(
            claimKey: "self.quality_bar",
            value: "high standards",
            confidence: 0.6,
            evidenceType: .behavior,
            excerpt: nil,
            nodeId: nil,
        )

        await store.mergeClaims([candidate], target: .identity)
        await store.mergeClaims([candidate], target: .identity)
        await store.mergeClaims([candidate], target: .identity)

        let identity = await store.currentIdentity()
        let claim = identity.claims.first { $0.claimKey == "self.quality_bar" }
        #expect(claim?.epistemicStatus == .asserted)
        #expect(try #require(claim?.evidenceDiversity) >= 3)
    }

    @Test
    func `Merge contradicting value lowers confidence on existing and creates competing`() async throws {
        let (store, _) = try await makeStore()

        let original = ClaimCandidate(
            claimKey: "self.style",
            value: "verbose",
            confidence: 0.7,
            evidenceType: .behavior,
            excerpt: nil,
            nodeId: nil,
        )
        await store.mergeClaims([original], target: .identity)

        let beforeIdentity = await store.currentIdentity()
        let beforeConfidence = beforeIdentity.claims.first { $0.claimKey == "self.style" }?.confidence ?? 0

        let contradiction = ClaimCandidate(
            claimKey: "self.style",
            value: "concise",
            confidence: 0.5,
            evidenceType: .behavior,
            excerpt: nil,
            nodeId: nil,
        )
        await store.mergeClaims([contradiction], target: .identity)

        let afterIdentity = await store.currentIdentity()

        let existingClaim = afterIdentity.claims.first { $0.claimKey == "self.style" }
        #expect(existingClaim != nil)
        #expect(try #require(existingClaim?.confidence) < beforeConfidence)

        let competing = afterIdentity.claims.first { $0.claimKey == "self.style__competing" }
        #expect(competing != nil)
        #expect(competing?.value == "concise")
        #expect(competing?.epistemicStatus == .hypothesis)
    }

    @Test
    func `Empty candidates array is a no-op`() async throws {
        let (store, db) = try await makeStore()

        await store.mergeClaims([], target: .identity)

        let versions = try await db.dbPool.read { db in
            try IdentityVersionRecord.fetchAll(db)
        }
        #expect(versions.count == 1)
    }

    @Test
    func `Unprocessed claims are carried forward to new version`() async throws {
        let (store, _) = try await makeStore()

        let first = [
            ClaimCandidate(claimKey: "self.a", value: "value_a", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil),
            ClaimCandidate(claimKey: "self.b", value: "value_b", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil),
        ]
        await store.mergeClaims(first, target: .identity)

        let second = [
            ClaimCandidate(claimKey: "self.c", value: "value_c", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil),
        ]
        await store.mergeClaims(second, target: .identity)

        let identity = await store.currentIdentity()
        #expect(identity.claims.count == 3)
        let keys = Set(identity.claims.map(\.claimKey))
        #expect(keys.contains("self.a"))
        #expect(keys.contains("self.b"))
        #expect(keys.contains("self.c"))
    }

    // MARK: - Merge Claims (Mirror)

    @Test
    func `Merge new mirror claims creates them as hypotheses`() async throws {
        let (store, _) = try await makeStore()

        _ = await store.currentMirror(for: "alice")

        let candidates = [
            ClaimCandidate(
                claimKey: "mirror.alice.expertise",
                value: "Swift development",
                confidence: 0.7,
                evidenceType: .explicitStatement,
                excerpt: nil,
                nodeId: nil,
            ),
        ]

        await store.mergeClaims(candidates, target: .mirror("alice"))

        let mirror = await store.currentMirror(for: "alice")
        #expect(mirror.claims.count == 1)
        #expect(mirror.claims[0].claimKey == "mirror.alice.expertise")
        #expect(mirror.claims[0].epistemicStatus == .hypothesis)
    }

    // MARK: - Explicit Correction

    @Test
    func `Explicit correction updates existing claim with full confidence`() async throws {
        let (store, _) = try await makeStore()

        _ = await store.currentMirror(for: "alice")
        let candidate = ClaimCandidate(
            claimKey: "mirror.alice.preference",
            value: "dark mode",
            confidence: 0.5,
            evidenceType: .inference,
            excerpt: nil,
            nodeId: nil,
        )
        await store.mergeClaims([candidate], target: .mirror("alice"))

        let correction = MirrorCorrection(
            claimKey: "mirror.alice.preference",
            newValue: "light mode",
            rationale: "User explicitly stated preference",
        )
        await store.applyExplicitCorrection(correction, for: "alice")

        let mirror = await store.currentMirror(for: "alice")
        let claim = mirror.claims.first { $0.claimKey == "mirror.alice.preference" }
        #expect(claim != nil)
        #expect(claim?.value == "light mode")
        #expect(claim?.confidence == 1.0)
        #expect(claim?.epistemicStatus == .asserted)
        #expect(mirror.createdBy == "explicit_correction")
    }

    @Test
    func `Explicit correction creates new claim if key doesn't exist`() async throws {
        let (store, _) = try await makeStore()

        _ = await store.currentMirror(for: "alice")

        let correction = MirrorCorrection(
            claimKey: "mirror.alice.language",
            newValue: "Japanese",
            rationale: "User mentioned their language preference",
        )
        await store.applyExplicitCorrection(correction, for: "alice")

        let mirror = await store.currentMirror(for: "alice")
        let claim = mirror.claims.first { $0.claimKey == "mirror.alice.language" }
        #expect(claim != nil)
        #expect(claim?.value == "Japanese")
        #expect(claim?.confidence == 1.0)
    }

    @Test
    func `Explicit correction preserves other claims`() async throws {
        let (store, _) = try await makeStore()

        _ = await store.currentMirror(for: "alice")

        let candidates = [
            ClaimCandidate(claimKey: "mirror.alice.a", value: "value_a", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil),
            ClaimCandidate(claimKey: "mirror.alice.b", value: "value_b", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil),
        ]
        await store.mergeClaims(candidates, target: .mirror("alice"))

        let correction = MirrorCorrection(
            claimKey: "mirror.alice.a",
            newValue: "corrected_a",
            rationale: "test",
        )
        await store.applyExplicitCorrection(correction, for: "alice")

        let mirror = await store.currentMirror(for: "alice")
        #expect(mirror.claims.count == 2)
        let claimB = mirror.claims.first { $0.claimKey == "mirror.alice.b" }
        #expect(claimB?.value == "value_b")
    }

    // MARK: - Hebbian Decay

    @Test
    func `Decay lowers confidence based on time since reinforcement`() async throws {
        let (store, db) = try await makeStore()

        let pastDate = try #require(Calendar.current.date(byAdding: .day, value: -180, to: Date()))
        let pastString = ISO8601DateFormatter().string(from: pastDate)

        let versionId = try await db.dbPool.read { db in
            try IdentityVersionRecord
                .filter(Column("isActive") == true)
                .fetchOne(db)!.versionId!
        }

        try await db.dbPool.write { [versionId] db in
            var claim = IdentityClaimRecord(
                versionId: versionId,
                claimKey: "self.old_claim",
                value: "something old",
                confidence: 0.8,
                epistemicStatus: "hypothesis",
                evidenceCount: 2,
                evidenceDiversity: 2,
                decayHalfLifeDays: 90,
                createdAt: pastString,
                lastReinforcedAt: pastString,
            )
            try claim.insert(db)
        }

        let beforeIdentity = await store.currentIdentity()
        let beforeClaim = beforeIdentity.claims.first { $0.claimKey == "self.old_claim" }
        #expect(beforeClaim != nil)
        #expect(try abs(#require(beforeClaim?.confidence) - 0.8) < 0.01)

        await store.decayClaims()

        let afterIdentity = await store.currentIdentity()
        let afterClaim = afterIdentity.claims.first { $0.claimKey == "self.old_claim" }
        #expect(afterClaim != nil)
        #expect(try #require(afterClaim?.confidence) < 0.8)
        #expect(try #require(afterClaim?.confidence) >= CIMSDefaults.hebbianDecayFloor)
    }

    @Test
    func `Decay respects floor — confidence never drops below 0.05`() async throws {
        let (store, db) = try await makeStore()

        let ancientDate = try #require(Calendar.current.date(byAdding: .year, value: -5, to: Date()))
        let ancientString = ISO8601DateFormatter().string(from: ancientDate)

        let versionId = try await db.dbPool.read { db in
            try IdentityVersionRecord
                .filter(Column("isActive") == true)
                .fetchOne(db)!.versionId!
        }

        try await db.dbPool.write { [versionId] db in
            var claim = IdentityClaimRecord(
                versionId: versionId,
                claimKey: "self.ancient_claim",
                value: "something ancient",
                confidence: 0.5,
                epistemicStatus: "hypothesis",
                evidenceCount: 1,
                evidenceDiversity: 1,
                decayHalfLifeDays: 90,
                createdAt: ancientString,
                lastReinforcedAt: ancientString,
            )
            try claim.insert(db)
        }

        await store.decayClaims()

        let identity = await store.currentIdentity()
        let claim = identity.claims.first { $0.claimKey == "self.ancient_claim" }
        #expect(claim != nil)
        #expect(try #require(claim?.confidence) >= CIMSDefaults.hebbianDecayFloor)
    }

    @Test
    func `Decay also applies to mirror claims`() async throws {
        let (store, db) = try await makeStore()

        _ = await store.currentMirror(for: "alice")

        let pastDate = try #require(Calendar.current.date(byAdding: .day, value: -120, to: Date()))
        let pastString = ISO8601DateFormatter().string(from: pastDate)

        let versionId = try await db.dbPool.read { db in
            try MirrorVersionRecord
                .filter(Column("userKey") == "alice")
                .filter(Column("isActive") == true)
                .fetchOne(db)!.versionId!
        }

        try await db.dbPool.write { [versionId] db in
            var claim = MirrorClaimRecord(
                versionId: versionId,
                claimKey: "mirror.alice.stale",
                value: "old preference",
                confidence: 0.9,
                epistemicStatus: "hypothesis",
                evidenceCount: 1,
                evidenceDiversity: 1,
                decayHalfLifeDays: 60,
                createdAt: pastString,
                lastReinforcedAt: pastString,
            )
            try claim.insert(db)
        }

        await store.decayClaims()

        let mirror = await store.currentMirror(for: "alice")
        let claim = mirror.claims.first { $0.claimKey == "mirror.alice.stale" }
        #expect(claim != nil)
        #expect(try #require(claim?.confidence) < 0.9)
    }

    // MARK: - Rollback

    @Test
    func `Rollback identity restores a previous version`() async throws {
        let (store, _) = try await makeStore()

        let v1 = await store.currentIdentity()
        let v1Id = v1.versionId

        let candidates = [
            ClaimCandidate(claimKey: "self.test", value: "v2_value", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil),
        ]
        await store.mergeClaims(candidates, target: .identity)

        let v2 = await store.currentIdentity()
        #expect(v2.versionId != v1Id)
        #expect(v2.claims.count == 1)

        await store.rollbackIdentity(to: v1Id)

        let rolledBack = await store.currentIdentity()
        #expect(rolledBack.versionId == v1Id)
        #expect(rolledBack.claims.isEmpty)
    }

    @Test
    func `Rollback mirror restores a previous version for the correct user`() async throws {
        let (store, _) = try await makeStore()

        _ = await store.currentMirror(for: "alice")
        let v1 = await store.currentMirror(for: "alice")
        let v1Id = v1.versionId

        let candidates = [
            ClaimCandidate(claimKey: "mirror.alice.test", value: "v2", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil),
        ]
        await store.mergeClaims(candidates, target: .mirror("alice"))

        let v2 = await store.currentMirror(for: "alice")
        #expect(v2.claims.count == 1)

        await store.rollbackMirror(for: "alice", to: v1Id)

        let rolledBack = await store.currentMirror(for: "alice")
        #expect(rolledBack.versionId == v1Id)
        #expect(rolledBack.claims.isEmpty)
    }

    @Test
    func `Rollback mirror for wrong user is a no-op`() async throws {
        let (store, _) = try await makeStore()

        _ = await store.currentMirror(for: "alice")
        _ = await store.currentMirror(for: "other")

        let aliceMirror = await store.currentMirror(for: "alice")
        let aliceV1Id = aliceMirror.versionId

        await store.rollbackMirror(for: "other", to: aliceV1Id)

        let otherMirror = await store.currentMirror(for: "other")
        #expect(otherMirror.versionId != aliceV1Id)
    }

    // MARK: - Version Chain

    @Test
    func `Each merge creates a new version with correct previousVersion link`() async throws {
        let (store, db) = try await makeStore()

        let v1 = await store.currentIdentity()

        await store.mergeClaims(
            [ClaimCandidate(claimKey: "k1", value: "v1", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil)],
            target: .identity,
        )
        let v2 = await store.currentIdentity()

        await store.mergeClaims(
            [ClaimCandidate(claimKey: "k2", value: "v2", confidence: 0.5, evidenceType: .behavior, excerpt: nil, nodeId: nil)],
            target: .identity,
        )
        let v3 = await store.currentIdentity()

        let v3Id = v3.versionId
        let v3Record = try await db.dbPool.read { [v3Id] db in
            try IdentityVersionRecord.fetchOne(db, key: v3Id)!
        }
        #expect(v3Record.previousVersion == v2.versionId)

        let v2Id = v2.versionId
        let v2Record = try await db.dbPool.read { [v2Id] db in
            try IdentityVersionRecord.fetchOne(db, key: v2Id)!
        }
        #expect(v2Record.previousVersion == v1.versionId)
    }
}
