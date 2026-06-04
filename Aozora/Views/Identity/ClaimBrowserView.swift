import AozoraCore
import SwiftUI

// MARK: - Identifiable conformances

extension IdentityClaim: Identifiable {}
extension MirrorClaim: Identifiable {}

// MARK: - Mode

/// The two modes of the claim browser: the system's self-knowledge vs a user's mirror.
private enum ClaimMode: String, CaseIterable {
    /// Browse identity claims (system self-knowledge).
    case identity = "Identity"

    /// Browse mirror claims for the currently selected user.
    case mirror = "Mirror"
}

// MARK: - Main View

/// Full-featured browser for identity and mirror claims.
///
/// Shows the active identity block or a user's mirror block, depending on the selected
/// mode. Each claim row displays key, value, confidence, epistemic status, evidence
/// count, and last-reinforced date. Selecting a claim reveals a detail sheet with the
/// full evidence chain, decay half-life, and creation timestamp.
///
/// A version history section at the bottom supports rollback to any prior version.
/// In mirror mode an "Apply Correction" sheet lets you write an explicit correction
/// that bypasses the consolidation queue.
///
/// Only rendered when `appState.phase == .ready`, so force-unwrapping
/// `identityManager` is safe.
struct ClaimBrowserView: View {
    @Environment(CIMSAppState.self) private var appState

    @State private var mode: ClaimMode = .identity
    @State private var selectedClaimID: Int64? = nil
    @State private var showCorrectionSheet = false
    @State private var showRollbackSection = false
    @State private var rollbackVersionInput = ""

    var body: some View {
        let im = appState.identityManager!

        VStack(spacing: 0) {
            if im.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                claimList(im)
            }
        }
        .navigationTitle(mode == .identity ? "Identity Claims" : "Mirror Claims")
        .toolbar { toolbarContent(im) }
        .task { await im.loadIdentity() }
        .sheet(isPresented: $showCorrectionSheet) {
            MirrorCorrectionSheet(identityManager: im)
        }
    }

    // MARK: - Claim List

    /// The scrollable list of claims, version banner, and rollback section.
    private func claimList(_ im: IdentityManager) -> some View {
        List(selection: $selectedClaimID) {
            claimsSection(im)
            versionSection(im)
        }
        .listStyle(.inset)
        .onChange(of: mode) { _, newMode in
            selectedClaimID = nil
            Task {
                if newMode == .mirror {
                    await im.loadMirror(for: im.selectedUserKey)
                } else {
                    await im.loadIdentity()
                }
            }
        }
    }

    // MARK: - Claims Section

    /// Rows for every claim in the active mode, plus an expanded detail row when one is selected.
    private func claimsSection(_ im: IdentityManager) -> some View {
        Section {
            if mode == .identity {
                if im.identityClaims.isEmpty {
                    emptyClaimsRow
                } else {
                    ForEach(im.identityClaims) { claim in
                        identityClaimRow(claim)
                        if selectedClaimID == claim.id {
                            identityClaimDetail(claim)
                        }
                    }
                }
            } else {
                if im.mirrorClaims.isEmpty {
                    emptyClaimsRow
                } else {
                    ForEach(im.mirrorClaims) { claim in
                        mirrorClaimRow(claim)
                        if selectedClaimID == claim.id {
                            mirrorClaimDetail(claim)
                        }
                    }
                }
            }
        } header: {
            Text(mode == .identity ? "Identity" : "Mirror — \(im.selectedUserKey)")
        }
    }

    /// Placeholder row shown when the claim list is empty.
    private var emptyClaimsRow: some View {
        Text("No claims loaded")
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
    }

    // MARK: - Identity Claim Row

    /// A single row summarising one identity claim.
    ///
    /// - Parameter claim: The claim to display.
    private func identityClaimRow(_ claim: IdentityClaim) -> some View {
        claimRow(
            id: claim.id,
            claimKey: claim.claimKey,
            value: claim.value,
            confidence: claim.confidence,
            epistemicStatus: claim.epistemicStatus,
            evidenceCount: claim.evidenceCount,
            lastReinforcedAt: claim.lastReinforcedAt,
        )
    }

    // MARK: - Mirror Claim Row

    /// A single row summarising one mirror claim.
    ///
    /// - Parameter claim: The mirror claim to display.
    private func mirrorClaimRow(_ claim: MirrorClaim) -> some View {
        claimRow(
            id: claim.id,
            claimKey: claim.claimKey,
            value: claim.value,
            confidence: claim.confidence,
            epistemicStatus: claim.epistemicStatus,
            evidenceCount: claim.evidenceCount,
            lastReinforcedAt: claim.lastReinforcedAt,
        )
    }

    // MARK: - Shared Claim Row

    /// Unified row layout shared by identity and mirror claims.
    ///
    /// - Parameters:
    ///   - id: The claim's Int64 row ID.
    ///   - claimKey: Namespaced key (e.g. `"self.communication_style"`).
    ///   - value: The claim content.
    ///   - confidence: Confidence in [0, 1].
    ///   - epistemicStatus: Current epistemic status.
    ///   - evidenceCount: Number of supporting observations.
    ///   - lastReinforcedAt: When evidence last reinforced this claim.
    private func claimRow(
        id: Int64,
        claimKey: String,
        value: String,
        confidence: Float,
        epistemicStatus: EpistemicStatus,
        evidenceCount: Int,
        lastReinforcedAt: Date,
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Key + value
            VStack(alignment: .leading, spacing: 2) {
                Text(claimKey)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Confidence bar
            VStack(alignment: .center, spacing: 2) {
                ProgressView(value: Double(confidence))
                    .progressViewStyle(.linear)
                    .frame(width: 80)
                Text(String(format: "%.0f%%", confidence * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(width: 80)

            // Status badge
            EpistemicStatusBadge(status: epistemicStatus)
                .frame(width: 76)

            // Evidence
            VStack(alignment: .center, spacing: 2) {
                Text("\(evidenceCount)")
                    .font(.callout)
                    .monospacedDigit()
                Text("evidence")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56)

            // Last reinforced
            VStack(alignment: .trailing, spacing: 2) {
                Text(lastReinforcedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                Text("ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedClaimID = (selectedClaimID == id) ? nil : id
            }
        }
    }

    // MARK: - Identity Claim Detail

    /// An expanded detail row showing full metadata for the selected identity claim.
    ///
    /// - Parameter claim: The identity claim whose detail to show.
    private func identityClaimDetail(_ claim: IdentityClaim) -> some View {
        ClaimDetailView(
            claimKey: claim.claimKey,
            value: claim.value,
            epistemicStatus: claim.epistemicStatus,
            evidenceCount: claim.evidenceCount,
            evidenceDiversity: claim.evidenceDiversity,
            decayHalfLifeDays: claim.decayHalfLifeDays,
            createdAt: claim.createdAt,
            lastReinforcedAt: claim.lastReinforcedAt,
        )
    }

    // MARK: - Mirror Claim Detail

    /// An expanded detail row showing full metadata for the selected mirror claim.
    ///
    /// - Parameter claim: The mirror claim whose detail to show.
    private func mirrorClaimDetail(_ claim: MirrorClaim) -> some View {
        ClaimDetailView(
            claimKey: claim.claimKey,
            value: claim.value,
            epistemicStatus: claim.epistemicStatus,
            evidenceCount: claim.evidenceCount,
            evidenceDiversity: claim.evidenceDiversity,
            decayHalfLifeDays: claim.decayHalfLifeDays,
            createdAt: claim.createdAt,
            lastReinforcedAt: claim.lastReinforcedAt,
        )
    }

    // MARK: - Version Section

    /// Footer section with current version ID and a rollback control.
    private func versionSection(_ im: IdentityManager) -> some View {
        Section {
            HStack {
                Label(
                    "Version \(mode == .identity ? im.identityVersionId : im.mirrorVersionId)",
                    systemImage: "clock.arrow.circlepath",
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation { showRollbackSection.toggle() }
                } label: {
                    Label(
                        showRollbackSection ? "Hide Rollback" : "Rollback…",
                        systemImage: showRollbackSection ? "chevron.up" : "arrow.counterclockwise",
                    )
                    .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            if showRollbackSection {
                rollbackRow(im)
            }
        } header: {
            Text("Version History")
        }
    }

    /// The rollback text field and button row.
    ///
    /// - Parameter im: The identity manager to perform the rollback on.
    private func rollbackRow(_ im: IdentityManager) -> some View {
        HStack {
            TextField("Version ID", text: $rollbackVersionInput)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 140)

            Button("Rollback") {
                guard let vid = Int64(rollbackVersionInput.trimmingCharacters(in: .whitespaces)) else { return }
                rollbackVersionInput = ""
                showRollbackSection = false
                Task {
                    if mode == .identity {
                        await im.rollbackIdentity(to: vid)
                    } else {
                        await im.rollbackMirror(for: im.selectedUserKey, to: vid)
                    }
                }
            }
            .buttonStyle(.bordered)
            .disabled(Int64(rollbackVersionInput.trimmingCharacters(in: .whitespaces)) == nil)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Toolbar

    /// Toolbar items: mode picker and (in mirror mode) the "Apply Correction" button.
    @ToolbarContentBuilder
    private func toolbarContent(_: IdentityManager) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Mode", selection: $mode) {
                ForEach(ClaimMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
        }

        if mode == .mirror {
            ToolbarItem(placement: .automatic) {
                Button("Apply Correction…") {
                    showCorrectionSheet = true
                }
            }
        }
    }
}

// MARK: - Claim Detail View

/// A subordinate view rendered inside the list below a selected claim row.
///
/// Shows full epistemic metadata: status, evidence count, evidence diversity (the
/// minimum required for promotion), decay half-life, creation date, and last
/// reinforced date.
private struct ClaimDetailView: View {
    /// The namespaced claim key.
    let claimKey: String
    /// The claim content.
    let value: String
    /// Current epistemic status.
    let epistemicStatus: EpistemicStatus
    /// Number of supporting observations.
    let evidenceCount: Int
    /// Number of distinct evidence contexts (≥ 3 required for `asserted`).
    let evidenceDiversity: Int
    /// Hebbian decay half-life in days.
    let decayHalfLifeDays: Float
    /// When this claim was first created.
    let createdAt: Date
    /// When evidence last reinforced this claim.
    let lastReinforcedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            Text("Claim Detail")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 4) {
                detailRow(label: "Key", content: claimKey)
                detailRow(label: "Value", content: value)
                detailRow(label: "Status", content: epistemicStatus.rawValue.capitalized)
                detailRow(label: "Evidence", content: "\(evidenceCount) observation\(evidenceCount == 1 ? "" : "s")")
                detailRow(label: "Diversity", content: "\(evidenceDiversity) context\(evidenceDiversity == 1 ? "" : "s") (≥ 3 for asserted)")
                detailRow(label: "Decay Half-Life", content: String(format: "%.0f days", decayHalfLifeDays))
                GridRow {
                    Text("Created")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                GridRow {
                    Text("Last Reinforced")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(lastReinforcedAt, style: .date)
                        Text("(\(Text(lastReinforcedAt, style: .relative)) ago)")
                    }
                    .font(.caption)
                    .foregroundStyle(.primary)
                }
            }

            Divider()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04)),
        )
    }

    /// A grid row with a secondary label and primary content.
    ///
    /// - Parameters:
    ///   - label: The field name.
    ///   - content: The field value.
    private func detailRow(label: String, content: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(content)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Epistemic Status Badge

/// A compact colored badge rendering an ``EpistemicStatus`` value.
///
/// Uses distinct accent colors to make status scannable at a glance:
/// hypothesis → blue, asserted → green, rejected → red.
private struct EpistemicStatusBadge: View {
    /// The status to display.
    let status: EpistemicStatus

    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.caption)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.15), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    /// The accent color for this status.
    private var badgeColor: Color {
        switch status {
        case .hypothesis: .blue
        case .asserted: .green
        case .rejected: .red
        }
    }
}

// MARK: - Mirror Correction Sheet

/// A modal sheet for applying an explicit correction to the current user's mirror.
///
/// Presented when the "Apply Correction" toolbar button is tapped in mirror mode.
/// Bypasses the consolidation queue — the user is the authority on themselves.
private struct MirrorCorrectionSheet: View {
    /// The identity manager to deliver the correction to.
    let identityManager: IdentityManager

    @Environment(\.dismiss) private var dismiss

    @State private var claimKey = ""
    @State private var value = ""
    @State private var rationale = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Correction") {
                    LabeledContent("Claim Key") {
                        TextField("e.g. mirror.user.expertise", text: $claimKey)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Value") {
                        TextField("Corrected value", text: $value)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section("Rationale") {
                    TextField(
                        "Why this correction was made…",
                        text: $rationale,
                        axis: .vertical,
                    )
                    .lineLimit(3 ... 6)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Apply Correction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let k = claimKey.trimmingCharacters(in: .whitespaces)
                        let v = value.trimmingCharacters(in: .whitespaces)
                        let r = rationale.trimmingCharacters(in: .whitespaces)
                        dismiss()
                        Task { await identityManager.applyCorrection(key: k, value: v, rationale: r) }
                    }
                    .disabled(
                        claimKey.trimmingCharacters(in: .whitespaces).isEmpty ||
                            value.trimmingCharacters(in: .whitespaces).isEmpty,
                    )
                }
            }
        }
        .frame(minWidth: 420, minHeight: 340)
    }
}
