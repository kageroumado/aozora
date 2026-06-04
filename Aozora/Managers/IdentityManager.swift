import AozoraCore
import Foundation
import OSLog

private let logger = Logger(subsystem: "app.aozora", category: "identity")

/// Manages identity and mirror claim browsing, corrections, and version history.
///
/// Bridges between the claim browser UI and the ``IdentityStore`` actor,
/// providing observable snapshots of claims and supporting rollback operations.
/// All methods delegate to the underlying store through the ``CIMSGateway``,
/// wrapping async actor calls with loading state management.
///
/// The manager exposes two parallel claim lists:
/// - ``identityClaims``: The system's self-knowledge (values, communication style, capabilities).
/// - ``mirrorClaims``: Per-user model for the currently selected user.
///
/// Corrections are mirror-only — the user is the authority on themselves. Identity
/// evolution happens exclusively through consolidation.
@Observable
final class IdentityManager {
    /// The CIMS gateway for identity store and consolidation access.
    private let gateway: CIMSGateway

    /// Active identity claims from the current identity version.
    var identityClaims: [IdentityClaim] = []

    /// Active mirror claims for the currently selected user.
    var mirrorClaims: [MirrorClaim] = []

    /// The user key whose mirror is currently loaded.
    var selectedUserKey: String = "default"

    /// Whether a load or mutation operation is in progress.
    var isLoading = false

    /// The version ID of the currently loaded identity block.
    private(set) var identityVersionId: VersionID = 0

    /// The version ID of the currently loaded mirror block.
    private(set) var mirrorVersionId: VersionID = 0

    /// Creates an identity manager backed by the given gateway.
    ///
    /// - Parameter gateway: The initialized CIMS gateway.
    init(gateway: CIMSGateway) {
        self.gateway = gateway
    }

    // MARK: - Loading

    /// Load the current identity block from the store.
    ///
    /// Fetches the active identity version and populates ``identityClaims``
    /// with all claims. Sets ``isLoading`` during the fetch.
    func loadIdentity() async {
        isLoading = true
        defer { isLoading = false }

        let block = await gateway.identityStore.currentIdentity()
        identityClaims = block.claims
        identityVersionId = block.versionId
        logger.debug("Loaded identity v\(block.versionId) with \(block.claims.count) claims")
    }

    /// Load the current mirror block for a specific user.
    ///
    /// Fetches the active mirror version for the given user and populates
    /// ``mirrorClaims``. Updates ``selectedUserKey`` to the loaded user.
    /// Creates the user record and initial mirror version if the user is new.
    ///
    /// - Parameter userKey: The user whose mirror to load.
    func loadMirror(for userKey: String) async {
        isLoading = true
        defer { isLoading = false }

        selectedUserKey = userKey
        let block = await gateway.identityStore.currentMirror(for: userKey)
        mirrorClaims = block.claims
        mirrorVersionId = block.versionId
        logger.debug("Loaded mirror v\(block.versionId) for '\(userKey)' with \(block.claims.count) claims")
    }

    // MARK: - Corrections

    /// Apply an explicit correction to the current user's mirror.
    ///
    /// Creates a new mirror version with the corrected claim at full confidence,
    /// bypassing the consolidation queue. The user is the authority on themselves.
    /// After applying, reloads the mirror to reflect the new version.
    ///
    /// - Parameters:
    ///   - key: The claim key to correct (e.g., `"mirror.user.expertise"`).
    ///   - value: The corrected value.
    ///   - rationale: Why this correction was made (for the version audit trail).
    func applyCorrection(key: String, value: String, rationale: String) async {
        isLoading = true
        defer { isLoading = false }

        let correction = MirrorCorrection(
            claimKey: key,
            newValue: value,
            rationale: rationale,
        )

        let userKey = selectedUserKey
        await gateway.identityStore.applyExplicitCorrection(correction, for: userKey)
        logger.info("Applied correction to '\(key)' for user '\(userKey)'")

        // Reload to reflect the new version
        let block = await gateway.identityStore.currentMirror(for: selectedUserKey)
        mirrorClaims = block.claims
        mirrorVersionId = block.versionId
    }

    // MARK: - Rollback

    /// Roll back the identity to a previous version.
    ///
    /// Deactivates the current active version and reactivates the specified version.
    /// After rollback, reloads the identity to reflect the restored state.
    ///
    /// - Parameter versionId: The version to restore.
    func rollbackIdentity(to versionId: Int64) async {
        isLoading = true
        defer { isLoading = false }

        await gateway.identityStore.rollbackIdentity(to: versionId)
        logger.info("Rolled back identity to version \(versionId)")

        // Reload to reflect the restored version
        let block = await gateway.identityStore.currentIdentity()
        identityClaims = block.claims
        identityVersionId = block.versionId
    }

    /// Roll back a user's mirror to a previous version.
    ///
    /// Deactivates the current active mirror version for the user and reactivates
    /// the specified version. After rollback, reloads the mirror.
    ///
    /// - Parameters:
    ///   - userKey: The user whose mirror to roll back.
    ///   - versionId: The version to restore.
    func rollbackMirror(for userKey: String, to versionId: Int64) async {
        isLoading = true
        defer { isLoading = false }

        await gateway.identityStore.rollbackMirror(for: userKey, to: versionId)
        logger.info("Rolled back mirror for '\(userKey)' to version \(versionId)")

        // Reload to reflect the restored version
        let block = await gateway.identityStore.currentMirror(for: userKey)
        mirrorClaims = block.claims
        mirrorVersionId = block.versionId
    }

    // MARK: - Consolidation

    /// Trigger an immediate manual consolidation run.
    ///
    /// Invokes the consolidation scheduler's ``ConsolidationScheduler/runNow()`` method,
    /// which cancels any pending timers and runs the full consolidation pipeline synchronously.
    /// After completion, reloads both identity and the current mirror to reflect any changes.
    func triggerConsolidation() async {
        isLoading = true
        defer { isLoading = false }

        logger.info("Triggering manual consolidation")
        await gateway.consolidationScheduler.runNow()

        // Reload both blocks since consolidation may have updated claims
        let identityBlock = await gateway.identityStore.currentIdentity()
        identityClaims = identityBlock.claims
        identityVersionId = identityBlock.versionId

        let mirrorBlock = await gateway.identityStore.currentMirror(for: selectedUserKey)
        mirrorClaims = mirrorBlock.claims
        mirrorVersionId = mirrorBlock.versionId

        logger.info("Manual consolidation complete")
    }
}
