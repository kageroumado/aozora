import Foundation
import GRDB

/// Versioned identity and mirror block management actor.
///
/// Manages the system's self-knowledge (identity block) and per-user models (mirror blocks)
/// as versioned collections of epistemic claims backed by GRDB. Every mutation creates a new
/// version with rationale and an optional back-pointer to the previous version, enabling
/// full rollback to any historical state.
///
/// On initialization, bootstraps the identity block if no active version exists, creating
/// version 1 with `isActive = true` and `createdBy = "bootstrap"`.
///
/// Claims follow strict epistemic discipline:
/// - Single-observation inferences are always `hypothesis`
/// - Promotion to `asserted` requires `evidenceDiversity >= 3`
/// - Contradictions lower confidence; strong contradiction with diverse evidence moves to `rejected`
/// - `rejected` claims are kept for audit trail
///
/// All database operations go through ``CIMSDatabase/dbPool`` without holding the actor's
/// executor during long I/O.
public actor IdentityStore: IdentityStoring {
    /// The shared database backing all CIMS persistence.
    private let db: CIMSDatabase

    /// Creates an identity store backed by the given database and bootstraps if needed.
    ///
    /// If no active identity version exists in the database, creates version 1 with
    /// `isActive = true`, `createdBy = "bootstrap"`, and no claims.
    ///
    /// - Parameter database: The CIMS database instance to use for all persistence.
    public init(database: CIMSDatabase) async throws {
        self.db = database
        try await bootstrap()
    }

    // MARK: - Date Helpers

    /// Format a `Date` as an ISO 8601 string with fractional seconds.
    public nonisolated static func formatDate(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// Parse an ISO 8601 string back to a `Date`.
    public nonisolated static func parseDate(_ string: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string) ?? ISO8601DateFormatter().date(from: string) ?? Date()
    }

    // MARK: - Bootstrap

    /// Ensure an active identity version exists, creating one if necessary.
    ///
    /// Called on init. If the database has no active identity version, inserts a
    /// bootstrap version (v1) with no claims. This guarantees that ``currentIdentity()``
    /// always returns a valid block.
    private func bootstrap() async throws {
        try await db.dbPool.write { db in
            let hasActive = try IdentityVersionRecord
                .filter(Column("isActive") == true)
                .fetchOne(db)

            if hasActive == nil {
                var version = IdentityVersionRecord(
                    previousVersion: nil,
                    isActive: true,
                    createdAt: IdentityStore.formatDate(Date()),
                    createdBy: "bootstrap",
                    rationale: "Initial identity bootstrap",
                )
                try version.insert(db)
            }
        }
    }

    // MARK: - Read

    /// Fetch the current active identity block with all claims.
    ///
    /// Returns ``IdentityBlock/empty`` if no identity has been bootstrapped yet
    /// (should not happen after init, but provides a safe fallback).
    public func currentIdentity() async -> IdentityBlock {
        do {
            return try await db.dbPool.read { db in
                guard let version = try IdentityVersionRecord
                    .filter(Column("isActive") == true)
                    .fetchOne(db)
                else {
                    return IdentityBlock(
                        versionId: 0,
                        claims: [],
                        createdAt: .distantPast,
                        createdBy: "bootstrap",
                    )
                }

                let claimRecords = try IdentityClaimRecord
                    .filter(Column("versionId") == version.versionId!)
                    .fetchAll(db)

                let claims = claimRecords.map { record in
                    IdentityClaim(
                        id: record.id!,
                        claimKey: record.claimKey,
                        value: record.value,
                        confidence: Float(record.confidence),
                        epistemicStatus: EpistemicStatus(rawValue: record.epistemicStatus) ?? .hypothesis,
                        evidenceCount: record.evidenceCount,
                        evidenceDiversity: record.evidenceDiversity,
                        decayHalfLifeDays: Float(record.decayHalfLifeDays),
                        createdAt: IdentityStore.parseDate(record.createdAt),
                        lastReinforcedAt: IdentityStore.parseDate(record.lastReinforcedAt),
                    )
                }

                return IdentityBlock(
                    versionId: version.versionId!,
                    claims: claims,
                    createdAt: IdentityStore.parseDate(version.createdAt),
                    createdBy: version.createdBy,
                )
            }
        } catch {
            print("[IdentityStore] currentIdentity error: \(error)")
            return IdentityBlock(
                versionId: 0,
                claims: [],
                createdAt: .distantPast,
                createdBy: "bootstrap",
            )
        }
    }

    /// Fetch the current active mirror block for a specific user.
    ///
    /// Creates the user record if the user hasn't been seen before, and creates an
    /// initial empty mirror version if none exists. This guarantees that every call
    /// returns a valid mirror block.
    ///
    /// - Parameter userKey: The user to fetch the mirror for.
    /// - Returns: The active mirror block, or an empty one for new users.
    public func currentMirror(for userKey: UserKey) async -> MirrorBlock {
        do {
            return try await db.dbPool.write { db in
                let now = IdentityStore.formatDate(Date())

                // Ensure user record exists
                if try UserRecord.fetchOne(db, key: userKey) == nil {
                    let user = UserRecord(
                        userKey: userKey,
                        displayName: nil,
                        firstSeenAt: now,
                        lastInteractionAt: now,
                        sessionCount: 0,
                        isBootstrap: true,
                    )
                    try user.insert(db)
                }

                // Ensure active mirror version exists for this user
                var version = try MirrorVersionRecord
                    .filter(Column("userKey") == userKey)
                    .filter(Column("isActive") == true)
                    .fetchOne(db)

                if version == nil {
                    var newVersion = MirrorVersionRecord(
                        userKey: userKey,
                        previousVersion: nil,
                        isActive: true,
                        createdAt: now,
                        createdBy: "bootstrap",
                        rationale: "Initial mirror bootstrap",
                    )
                    try newVersion.insert(db)
                    version = newVersion
                }

                let claimRecords = try MirrorClaimRecord
                    .filter(Column("versionId") == version!.versionId!)
                    .fetchAll(db)

                let claims = claimRecords.map { record in
                    MirrorClaim(
                        id: record.id!,
                        claimKey: record.claimKey,
                        value: record.value,
                        confidence: Float(record.confidence),
                        epistemicStatus: EpistemicStatus(rawValue: record.epistemicStatus) ?? .hypothesis,
                        evidenceCount: record.evidenceCount,
                        evidenceDiversity: record.evidenceDiversity,
                        decayHalfLifeDays: Float(record.decayHalfLifeDays),
                        createdAt: IdentityStore.parseDate(record.createdAt),
                        lastReinforcedAt: IdentityStore.parseDate(record.lastReinforcedAt),
                    )
                }

                return MirrorBlock(
                    versionId: version!.versionId!,
                    userKey: userKey,
                    claims: claims,
                    createdAt: IdentityStore.parseDate(version!.createdAt),
                    createdBy: version!.createdBy,
                )
            }
        } catch {
            print("[IdentityStore] currentMirror error: \(error)")
            return MirrorBlock(
                versionId: 0,
                userKey: userKey,
                claims: [],
                createdAt: .distantPast,
                createdBy: "bootstrap",
            )
        }
    }

    // MARK: - Write (Consolidation Path)

    /// Merge candidate claims into the identity or mirror block.
    ///
    /// Creates a new version, copies all existing claims from the current active version,
    /// then applies each candidate through the epistemic merge logic:
    /// - **Reinforcement**: candidate matches existing claim key and value →
    ///   bump confidence (min of existing + 0.1, cap at 1.0), increment evidence count,
    ///   update `lastReinforcedAt`.
    /// - **New claim**: no existing claim with this key → create as `hypothesis`.
    /// - **Contradiction**: candidate matches existing key but different value →
    ///   lower confidence on existing (multiply by 0.8), create competing hypothesis.
    ///
    /// Empty candidate arrays are a no-op (no version created).
    ///
    /// - Parameters:
    ///   - candidates: Proposed claims from the consolidation engine.
    ///   - target: Whether to update the identity block or a specific user's mirror.
    public func mergeClaims(_ candidates: [ClaimCandidate], target: ClaimTarget) async {
        guard !candidates.isEmpty else { return }

        do {
            try await db.dbPool.write { db in
                let now = IdentityStore.formatDate(Date())

                switch target {
                case .identity:
                    try Self.mergeIdentityClaims(candidates, now: now, in: db)
                case let .mirror(userKey):
                    try Self.mergeMirrorClaims(candidates, userKey: userKey, now: now, in: db)
                }
            }
        } catch {
            print("[IdentityStore] mergeClaims error: \(error)")
        }
    }

    /// Merge candidates into the identity block within a database transaction.
    private static func mergeIdentityClaims(
        _ candidates: [ClaimCandidate],
        now: String,
        in db: Database,
    ) throws {
        // Fetch current active version
        guard let currentVersion = try IdentityVersionRecord
            .filter(Column("isActive") == true)
            .fetchOne(db)
        else { return }

        let currentVersionId = currentVersion.versionId!

        // Fetch existing claims
        let existingClaims = try IdentityClaimRecord
            .filter(Column("versionId") == currentVersionId)
            .fetchAll(db)

        // Deactivate current version
        try db.execute(
            sql: "UPDATE identity_versions SET isActive = 0 WHERE versionId = ?",
            arguments: [currentVersionId],
        )

        // Create new version
        var newVersion = IdentityVersionRecord(
            previousVersion: currentVersionId,
            isActive: true,
            createdAt: now,
            createdBy: "consolidation",
            rationale: "Merged \(candidates.count) claim candidates",
        )
        try newVersion.insert(db)
        let newVersionId = newVersion.versionId!

        // Build lookup of existing claims by key
        var claimsByKey: [String: IdentityClaimRecord] = [:]
        for claim in existingClaims {
            claimsByKey[claim.claimKey] = claim
        }

        // Track which keys have been processed by candidates
        var processedKeys: Set<String> = []

        for candidate in candidates {
            processedKeys.insert(candidate.claimKey)

            if let existing = claimsByKey[candidate.claimKey] {
                if existing.value == candidate.value {
                    // Reinforcement: same key and value
                    let newConfidence = min(
                        Float(existing.confidence) + 0.1,
                        CIMSDefaults.hebbianDecayCap,
                    )
                    var reinforced = IdentityClaimRecord(
                        versionId: newVersionId,
                        claimKey: existing.claimKey,
                        value: existing.value,
                        confidence: Double(newConfidence),
                        epistemicStatus: existing.epistemicStatus,
                        evidenceCount: existing.evidenceCount + 1,
                        evidenceDiversity: existing.evidenceDiversity + 1,
                        decayHalfLifeDays: existing.decayHalfLifeDays,
                        createdAt: existing.createdAt,
                        lastReinforcedAt: now,
                    )
                    // Promote to asserted if diversity threshold met
                    if reinforced.evidenceDiversity >= 3, reinforced.epistemicStatus == EpistemicStatus.hypothesis.rawValue {
                        reinforced.epistemicStatus = EpistemicStatus.asserted.rawValue
                    }
                    try reinforced.insert(db)
                } else {
                    // Contradiction: same key, different value
                    // Copy existing with lowered confidence
                    let loweredConfidence = max(
                        Float(existing.confidence) * 0.8,
                        CIMSDefaults.hebbianDecayFloor,
                    )
                    var lowered = IdentityClaimRecord(
                        versionId: newVersionId,
                        claimKey: existing.claimKey,
                        value: existing.value,
                        confidence: Double(loweredConfidence),
                        epistemicStatus: existing.epistemicStatus,
                        evidenceCount: existing.evidenceCount,
                        evidenceDiversity: existing.evidenceDiversity,
                        decayHalfLifeDays: existing.decayHalfLifeDays,
                        createdAt: existing.createdAt,
                        lastReinforcedAt: existing.lastReinforcedAt,
                    )
                    try lowered.insert(db)

                    // Create competing hypothesis with a derived key
                    var competing = IdentityClaimRecord(
                        versionId: newVersionId,
                        claimKey: "\(candidate.claimKey)__competing",
                        value: candidate.value,
                        confidence: Double(candidate.confidence),
                        epistemicStatus: EpistemicStatus.hypothesis.rawValue,
                        evidenceCount: 1,
                        evidenceDiversity: 1,
                        decayHalfLifeDays: Double(CIMSDefaults.identityClaimDecayHalfLifeDays),
                        createdAt: now,
                        lastReinforcedAt: now,
                    )
                    try competing.insert(db)
                }
            } else {
                // New claim: create as hypothesis
                var newClaim = IdentityClaimRecord(
                    versionId: newVersionId,
                    claimKey: candidate.claimKey,
                    value: candidate.value,
                    confidence: Double(candidate.confidence),
                    epistemicStatus: EpistemicStatus.hypothesis.rawValue,
                    evidenceCount: 1,
                    evidenceDiversity: 1,
                    decayHalfLifeDays: Double(CIMSDefaults.identityClaimDecayHalfLifeDays),
                    createdAt: now,
                    lastReinforcedAt: now,
                )
                try newClaim.insert(db)
            }
        }

        // Copy unprocessed existing claims to new version unchanged
        for claim in existingClaims where !processedKeys.contains(claim.claimKey) {
            var copy = IdentityClaimRecord(
                versionId: newVersionId,
                claimKey: claim.claimKey,
                value: claim.value,
                confidence: claim.confidence,
                epistemicStatus: claim.epistemicStatus,
                evidenceCount: claim.evidenceCount,
                evidenceDiversity: claim.evidenceDiversity,
                decayHalfLifeDays: claim.decayHalfLifeDays,
                createdAt: claim.createdAt,
                lastReinforcedAt: claim.lastReinforcedAt,
            )
            try copy.insert(db)
        }
    }

    /// Merge candidates into a user's mirror block within a database transaction.
    private static func mergeMirrorClaims(
        _ candidates: [ClaimCandidate],
        userKey: UserKey,
        now: String,
        in db: Database,
    ) throws {
        // Fetch current active mirror version for this user
        guard let currentVersion = try MirrorVersionRecord
            .filter(Column("userKey") == userKey)
            .filter(Column("isActive") == true)
            .fetchOne(db)
        else { return }

        let currentVersionId = currentVersion.versionId!

        // Fetch existing claims
        let existingClaims = try MirrorClaimRecord
            .filter(Column("versionId") == currentVersionId)
            .fetchAll(db)

        // Deactivate current version
        try db.execute(
            sql: "UPDATE mirror_versions SET isActive = 0 WHERE versionId = ?",
            arguments: [currentVersionId],
        )

        // Create new version
        var newVersion = MirrorVersionRecord(
            userKey: userKey,
            previousVersion: currentVersionId,
            isActive: true,
            createdAt: now,
            createdBy: "consolidation",
            rationale: "Merged \(candidates.count) claim candidates",
        )
        try newVersion.insert(db)
        let newVersionId = newVersion.versionId!

        // Build lookup
        var claimsByKey: [String: MirrorClaimRecord] = [:]
        for claim in existingClaims {
            claimsByKey[claim.claimKey] = claim
        }

        var processedKeys: Set<String> = []

        for candidate in candidates {
            processedKeys.insert(candidate.claimKey)

            if let existing = claimsByKey[candidate.claimKey] {
                if existing.value == candidate.value {
                    // Reinforcement
                    let newConfidence = min(
                        Float(existing.confidence) + 0.1,
                        CIMSDefaults.hebbianDecayCap,
                    )
                    var reinforced = MirrorClaimRecord(
                        versionId: newVersionId,
                        claimKey: existing.claimKey,
                        value: existing.value,
                        confidence: Double(newConfidence),
                        epistemicStatus: existing.epistemicStatus,
                        evidenceCount: existing.evidenceCount + 1,
                        evidenceDiversity: existing.evidenceDiversity + 1,
                        decayHalfLifeDays: existing.decayHalfLifeDays,
                        createdAt: existing.createdAt,
                        lastReinforcedAt: now,
                    )
                    if reinforced.evidenceDiversity >= 3, reinforced.epistemicStatus == EpistemicStatus.hypothesis.rawValue {
                        reinforced.epistemicStatus = EpistemicStatus.asserted.rawValue
                    }
                    try reinforced.insert(db)
                } else {
                    // Contradiction
                    let loweredConfidence = max(
                        Float(existing.confidence) * 0.8,
                        CIMSDefaults.hebbianDecayFloor,
                    )
                    var lowered = MirrorClaimRecord(
                        versionId: newVersionId,
                        claimKey: existing.claimKey,
                        value: existing.value,
                        confidence: Double(loweredConfidence),
                        epistemicStatus: existing.epistemicStatus,
                        evidenceCount: existing.evidenceCount,
                        evidenceDiversity: existing.evidenceDiversity,
                        decayHalfLifeDays: existing.decayHalfLifeDays,
                        createdAt: existing.createdAt,
                        lastReinforcedAt: existing.lastReinforcedAt,
                    )
                    try lowered.insert(db)

                    var competing = MirrorClaimRecord(
                        versionId: newVersionId,
                        claimKey: "\(candidate.claimKey)__competing",
                        value: candidate.value,
                        confidence: Double(candidate.confidence),
                        epistemicStatus: EpistemicStatus.hypothesis.rawValue,
                        evidenceCount: 1,
                        evidenceDiversity: 1,
                        decayHalfLifeDays: Double(CIMSDefaults.mirrorClaimDecayHalfLifeDays),
                        createdAt: now,
                        lastReinforcedAt: now,
                    )
                    try competing.insert(db)
                }
            } else {
                // New claim
                var newClaim = MirrorClaimRecord(
                    versionId: newVersionId,
                    claimKey: candidate.claimKey,
                    value: candidate.value,
                    confidence: Double(candidate.confidence),
                    epistemicStatus: EpistemicStatus.hypothesis.rawValue,
                    evidenceCount: 1,
                    evidenceDiversity: 1,
                    decayHalfLifeDays: Double(CIMSDefaults.mirrorClaimDecayHalfLifeDays),
                    createdAt: now,
                    lastReinforcedAt: now,
                )
                try newClaim.insert(db)
            }
        }

        // Copy unprocessed claims
        for claim in existingClaims where !processedKeys.contains(claim.claimKey) {
            var copy = MirrorClaimRecord(
                versionId: newVersionId,
                claimKey: claim.claimKey,
                value: claim.value,
                confidence: claim.confidence,
                epistemicStatus: claim.epistemicStatus,
                evidenceCount: claim.evidenceCount,
                evidenceDiversity: claim.evidenceDiversity,
                decayHalfLifeDays: claim.decayHalfLifeDays,
                createdAt: claim.createdAt,
                lastReinforcedAt: claim.lastReinforcedAt,
            )
            try copy.insert(db)
        }
    }

    // MARK: - Write (Escape Hatch)

    /// Apply an immediate correction to a user's mirror, bypassing the consolidation queue.
    ///
    /// Used when the user explicitly corrects a belief about themselves (e.g., "No, I actually
    /// prefer X over Y"). Creates a new mirror version with the corrected claim. If the claim
    /// key already exists, it's replaced with the new value at full confidence. If not, a new
    /// claim is created. All other claims are copied unchanged.
    ///
    /// The correction is versioned and logged with the rationale for audit trail.
    ///
    /// - Parameters:
    ///   - correction: The correction to apply.
    ///   - userKey: The user whose mirror to update.
    public func applyExplicitCorrection(_ correction: MirrorCorrection, for userKey: UserKey) async {
        do {
            try await db.dbPool.write { db in
                let now = IdentityStore.formatDate(Date())

                // Ensure user and mirror exist
                if try UserRecord.fetchOne(db, key: userKey) == nil {
                    let user = UserRecord(
                        userKey: userKey,
                        displayName: nil,
                        firstSeenAt: now,
                        lastInteractionAt: now,
                        sessionCount: 0,
                        isBootstrap: true,
                    )
                    try user.insert(db)
                }

                // Find or create active mirror version
                let currentVersion = try MirrorVersionRecord
                    .filter(Column("userKey") == userKey)
                    .filter(Column("isActive") == true)
                    .fetchOne(db)

                let currentVersionId = currentVersion?.versionId
                let existingClaims: [MirrorClaimRecord]

                if let vid = currentVersionId {
                    existingClaims = try MirrorClaimRecord
                        .filter(Column("versionId") == vid)
                        .fetchAll(db)

                    // Deactivate current version
                    try db.execute(
                        sql: "UPDATE mirror_versions SET isActive = 0 WHERE versionId = ?",
                        arguments: [vid],
                    )
                } else {
                    existingClaims = []
                }

                // Create new version
                var newVersion = MirrorVersionRecord(
                    userKey: userKey,
                    previousVersion: currentVersionId,
                    isActive: true,
                    createdAt: now,
                    createdBy: "explicit_correction",
                    rationale: correction.rationale,
                )
                try newVersion.insert(db)
                let newVersionId = newVersion.versionId!

                // Copy existing claims, replacing the corrected one
                var corrected = false
                for claim in existingClaims {
                    if claim.claimKey == correction.claimKey {
                        // Replace with corrected value
                        var updated = MirrorClaimRecord(
                            versionId: newVersionId,
                            claimKey: correction.claimKey,
                            value: correction.newValue,
                            confidence: 1.0,
                            epistemicStatus: EpistemicStatus.asserted.rawValue,
                            evidenceCount: claim.evidenceCount + 1,
                            evidenceDiversity: claim.evidenceDiversity + 1,
                            decayHalfLifeDays: claim.decayHalfLifeDays,
                            createdAt: claim.createdAt,
                            lastReinforcedAt: now,
                        )
                        try updated.insert(db)
                        corrected = true
                    } else {
                        var copy = MirrorClaimRecord(
                            versionId: newVersionId,
                            claimKey: claim.claimKey,
                            value: claim.value,
                            confidence: claim.confidence,
                            epistemicStatus: claim.epistemicStatus,
                            evidenceCount: claim.evidenceCount,
                            evidenceDiversity: claim.evidenceDiversity,
                            decayHalfLifeDays: claim.decayHalfLifeDays,
                            createdAt: claim.createdAt,
                            lastReinforcedAt: claim.lastReinforcedAt,
                        )
                        try copy.insert(db)
                    }
                }

                // If the claim key didn't exist, create it
                if !corrected {
                    var newClaim = MirrorClaimRecord(
                        versionId: newVersionId,
                        claimKey: correction.claimKey,
                        value: correction.newValue,
                        confidence: 1.0,
                        epistemicStatus: EpistemicStatus.asserted.rawValue,
                        evidenceCount: 1,
                        evidenceDiversity: 1,
                        decayHalfLifeDays: Double(CIMSDefaults.mirrorClaimDecayHalfLifeDays),
                        createdAt: now,
                        lastReinforcedAt: now,
                    )
                    try newClaim.insert(db)
                }
            }
        } catch {
            print("[IdentityStore] applyExplicitCorrection error: \(error)")
        }
    }

    // MARK: - Maintenance

    /// Apply Hebbian decay to all claim confidences across both identity and mirror blocks.
    ///
    /// For each claim in the active identity and mirror versions, computes:
    /// `decayed = confidence * e^(-lambda * daysSinceReinforced)`
    /// where `lambda = ln(2) / decayHalfLifeDays`.
    ///
    /// Confidence is bounded by ``CIMSDefaults/hebbianDecayFloor`` (0.05) at the bottom
    /// and ``CIMSDefaults/hebbianDecayCap`` (1.0) at the top.
    ///
    /// This mutates claims in place on their current version rather than creating a new
    /// version, since decay is a maintenance operation, not a semantic change.
    public func decayClaims() async {
        do {
            try await db.dbPool.write { db in
                let now = Date()

                // Decay identity claims on the active version
                if let identityVersion = try IdentityVersionRecord
                    .filter(Column("isActive") == true)
                    .fetchOne(db) {
                    let claims = try IdentityClaimRecord
                        .filter(Column("versionId") == identityVersion.versionId!)
                        .fetchAll(db)

                    for var claim in claims {
                        let lastReinforced = IdentityStore.parseDate(claim.lastReinforcedAt)
                        let daysSince = now.timeIntervalSince(lastReinforced) / 86_400.0
                        let lambda = log(2.0) / claim.decayHalfLifeDays
                        let decayed = claim.confidence * exp(-lambda * daysSince)
                        let bounded = max(
                            Double(CIMSDefaults.hebbianDecayFloor),
                            min(Double(CIMSDefaults.hebbianDecayCap), decayed),
                        )
                        claim.confidence = bounded
                        try claim.update(db)
                    }
                }

                // Decay mirror claims on all active mirror versions
                let mirrorVersions = try MirrorVersionRecord
                    .filter(Column("isActive") == true)
                    .fetchAll(db)

                for mirrorVersion in mirrorVersions {
                    let claims = try MirrorClaimRecord
                        .filter(Column("versionId") == mirrorVersion.versionId!)
                        .fetchAll(db)

                    for var claim in claims {
                        let lastReinforced = IdentityStore.parseDate(claim.lastReinforcedAt)
                        let daysSince = now.timeIntervalSince(lastReinforced) / 86_400.0
                        let lambda = log(2.0) / claim.decayHalfLifeDays
                        let decayed = claim.confidence * exp(-lambda * daysSince)
                        let bounded = max(
                            Double(CIMSDefaults.hebbianDecayFloor),
                            min(Double(CIMSDefaults.hebbianDecayCap), decayed),
                        )
                        claim.confidence = bounded
                        try claim.update(db)
                    }
                }
            }
        } catch {
            print("[IdentityStore] decayClaims error: \(error)")
        }
    }

    // MARK: - Rollback

    /// Roll back the identity to a previous version.
    ///
    /// Deactivates the current active version and reactivates the specified version.
    /// If the target version doesn't exist, the operation is a no-op.
    ///
    /// - Parameter versionId: The version to restore.
    public func rollbackIdentity(to versionId: VersionID) async {
        do {
            try await db.dbPool.write { db in
                // Verify target exists
                guard try IdentityVersionRecord.fetchOne(db, key: versionId) != nil else {
                    return
                }

                // Deactivate all identity versions
                try db.execute(sql: "UPDATE identity_versions SET isActive = 0")

                // Activate the target version
                try db.execute(
                    sql: "UPDATE identity_versions SET isActive = 1 WHERE versionId = ?",
                    arguments: [versionId],
                )
            }
        } catch {
            print("[IdentityStore] rollbackIdentity error: \(error)")
        }
    }

    /// Roll back a user's mirror to a previous version.
    ///
    /// Deactivates the current active mirror version for the user and reactivates the
    /// specified version. If the target version doesn't exist or doesn't belong to the
    /// user, the operation is a no-op.
    ///
    /// - Parameters:
    ///   - userKey: The user whose mirror to roll back.
    ///   - versionId: The version to restore.
    public func rollbackMirror(for userKey: UserKey, to versionId: VersionID) async {
        do {
            try await db.dbPool.write { db in
                // Verify target exists and belongs to the right user
                guard let target = try MirrorVersionRecord.fetchOne(db, key: versionId),
                      target.userKey == userKey
                else {
                    return
                }

                // Deactivate all mirror versions for this user
                try db.execute(
                    sql: "UPDATE mirror_versions SET isActive = 0 WHERE userKey = ?",
                    arguments: [userKey],
                )

                // Activate the target version
                try db.execute(
                    sql: "UPDATE mirror_versions SET isActive = 1 WHERE versionId = ?",
                    arguments: [versionId],
                )
            }
        } catch {
            print("[IdentityStore] rollbackMirror error: \(error)")
        }
    }
}
