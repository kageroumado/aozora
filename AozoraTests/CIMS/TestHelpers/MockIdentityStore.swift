@testable import Aozora

/// Minimal mock implementing ``IdentityStoring`` for coordinator and gateway tests.
///
/// Returns empty identity/mirror blocks. All mutation methods are no-ops.
actor MockIdentityStore: IdentityStoring {
    func currentIdentity() async -> IdentityBlock {
        IdentityBlock(
            versionId: 0,
            claims: [],
            createdAt: .distantPast,
            createdBy: "test",
        )
    }

    func currentMirror(for userKey: UserKey) async -> MirrorBlock {
        MirrorBlock(
            versionId: 0,
            userKey: userKey,
            claims: [],
            createdAt: .distantPast,
            createdBy: "test",
        )
    }

    func mergeClaims(_: [ClaimCandidate], target _: ClaimTarget) async {}

    func applyExplicitCorrection(_: MirrorCorrection, for _: UserKey) async {}

    func decayClaims() async {}

    func rollbackIdentity(to _: VersionID) async {}

    func rollbackMirror(for _: UserKey, to _: VersionID) async {}
}
