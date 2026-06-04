import AozoraCore
import SwiftUI

/// Full-featured settings panel for CIMS runtime configuration.
///
/// Displays a `Form` with 9 sections covering model parameters, memory thresholds,
/// worker limits, consolidation timing, salience weights, allostasis thresholds,
/// Hebbian decay, cold storage, and OAuth account status.
///
/// Each section is its own view struct for observation isolation — changing one
/// setting only invalidates the section that reads it.
///
/// Only shown when `appState.phase == .ready`, so force-unwrapping
/// `settingsManager` is safe.
///
/// -> Spec: Chat UI Design Settings Panel
struct SettingsView: View {
    @Environment(CIMSAppState.self) private var appState

    var body: some View {
        let sm = appState.settingsManager!
        Form {
            ModelSettingsSection(settings: sm)
            MemorySettingsSection(settings: sm)
            WorkersSettingsSection(settings: sm)
            ConsolidationSettingsSection(settings: sm)
            SalienceSettingsSection(settings: sm)
            AllostasisSettingsSection(settings: sm)
            HebbianDecaySettingsSection(settings: sm)
            ColdStorageSettingsSection(settings: sm)
            AccountSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Reset All") {
                    appState.settingsManager?.resetAll()
                }
                .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Model Section

/// Section for model-level parameters: system prompt and max tokens.
private struct ModelSettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        @Bindable var sm = settings
        Section("Model") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("System Prompt")
                    Spacer()
                    SettingsResetButton { sm.resetValue("systemPrompt") }
                }
                TextEditor(text: $sm.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 80)
                Text("Default: \"You are a helpful assistant.\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            SettingsStepperRow(
                label: "Max Tokens",
                value: Binding(get: { sm.maxTokens }, set: { sm.maxTokens = $0 }),
                range: 256 ... 16_384,
                step: 256,
                hint: "Default: 4096",
            ) {
                sm.resetValue("maxTokens")
            }
        }
    }
}

// MARK: - Memory Section

/// Section for memory tier configuration: fresh tail size, leaf thresholds, large file threshold.
private struct MemorySettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        Section("Memory") {
            SettingsStepperRow(
                label: "Protected Tail Count",
                value: Binding(get: { settings.protectedTailCount }, set: { settings.protectedTailCount = $0 }),
                range: 8 ... 128,
                step: 1,
                hint: "Default: \(CIMSDefaults.protectedTailCount)",
            ) {
                settings.resetValue("protectedTailCount")
            }

            SettingsStepperRow(
                label: "Leaf Chunk Tokens",
                value: Binding(get: { settings.leafChunkTokens }, set: { settings.leafChunkTokens = $0 }),
                range: 5_000 ... 50_000,
                step: 1_000,
                hint: "Default: \(CIMSDefaults.leafChunkTokens)",
            ) {
                settings.resetValue("leafChunkTokens")
            }

            SettingsStepperRow(
                label: "Leaf Target Tokens Max",
                value: Binding(get: { settings.leafTargetTokensMax }, set: { settings.leafTargetTokensMax = $0 }),
                range: 200 ... 5_000,
                step: 100,
                hint: "Default: \(CIMSDefaults.leafTargetTokensMax)",
            ) {
                settings.resetValue("leafTargetTokensMax")
            }

            SettingsStepperRow(
                label: "Large File Threshold",
                value: Binding(get: { settings.largeFileTokenThreshold }, set: { settings.largeFileTokenThreshold = $0 }),
                range: 5_000 ... 100_000,
                step: 1_000,
                hint: "Default: \(CIMSDefaults.largeFileTokenThreshold)",
            ) {
                settings.resetValue("largeFileTokenThreshold")
            }
        }
    }
}

// MARK: - Workers Section

/// Section for worker concurrency and budget settings.
private struct WorkersSettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        Section("Workers") {
            SettingsStepperRow(
                label: "Max Concurrent Workers",
                value: Binding(get: { settings.maxConcurrentWorkers }, set: { settings.maxConcurrentWorkers = $0 }),
                range: 1 ... 8,
                step: 1,
                hint: "Default: \(CIMSDefaults.maxConcurrentWorkers)",
            ) {
                settings.resetValue("maxConcurrentWorkers")
            }

            SettingsStepperRow(
                label: "Max Workers Per User",
                value: Binding(get: { settings.maxWorkersPerUser }, set: { settings.maxWorkersPerUser = $0 }),
                range: 1 ... 4,
                step: 1,
                hint: "Default: \(CIMSDefaults.maxWorkersPerUser)",
            ) {
                settings.resetValue("maxWorkersPerUser")
            }

            SettingsStepperRow(
                label: "Worker Default Budget",
                value: Binding(get: { settings.workerDefaultBudget }, set: { settings.workerDefaultBudget = $0 }),
                range: 10_000 ... 200_000,
                step: 5_000,
                hint: "Default: \(CIMSDefaults.workerDefaultBudget)",
            ) {
                settings.resetValue("workerDefaultBudget")
            }

            SettingsDoubleStepperRow(
                label: "Delegation Grant TTL",
                value: Binding(get: { settings.delegationGrantTTLSeconds }, set: { settings.delegationGrantTTLSeconds = $0 }),
                range: 30 ... 3_600,
                step: 30,
                hint: "Default: 5 min 0 sec",
                displayFormatter: { formatDuration($0) },
            ) {
                settings.resetValue("delegationGrantTTLSeconds")
            }
        }
    }
}

// MARK: - Consolidation Section

/// Section for consolidation trigger timing.
private struct ConsolidationSettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        Section("Consolidation") {
            SettingsDoubleStepperRow(
                label: "Idle Timeout",
                value: Binding(get: { settings.consolidationIdleTimeoutSeconds }, set: { settings.consolidationIdleTimeoutSeconds = $0 }),
                range: 60 ... 7_200,
                step: 60,
                hint: "Default: 15 min 0 sec",
                displayFormatter: { formatDuration($0) },
            ) {
                settings.resetValue("consolidationIdleTimeoutSeconds")
            }

            SettingsDoubleStepperRow(
                label: "Session End Delay",
                value: Binding(get: { settings.consolidationSessionEndDelaySeconds }, set: { settings.consolidationSessionEndDelaySeconds = $0 }),
                range: 30 ... 3_600,
                step: 30,
                hint: "Default: 5 min 0 sec",
                displayFormatter: { formatDuration($0) },
            ) {
                settings.resetValue("consolidationSessionEndDelaySeconds")
            }
        }
    }
}

// MARK: - Salience Weights Section

/// Section for the four salience scoring weights.
///
/// The manager auto-normalizes when any one weight changes, so all four
/// are shown together so the user sees the redistribution immediately.
private struct SalienceSettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        Section("Salience Weights") {
            SettingsFloatSliderRow(
                label: "Urgency",
                value: Binding(
                    get: { settings.salienceUrgencyWeight },
                    set: { settings.salienceUrgencyWeight = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.salienceUrgencyWeight))",
            ) {
                settings.resetValue("salienceUrgencyWeight")
            }

            SettingsFloatSliderRow(
                label: "Identity",
                value: Binding(
                    get: { settings.salienceIdentityWeight },
                    set: { settings.salienceIdentityWeight = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.salienceIdentityWeight))",
            ) {
                settings.resetValue("salienceIdentityWeight")
            }

            SettingsFloatSliderRow(
                label: "Mirror",
                value: Binding(
                    get: { settings.salienceMirrorWeight },
                    set: { settings.salienceMirrorWeight = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.salienceMirrorWeight))",
            ) {
                settings.resetValue("salienceMirrorWeight")
            }

            SettingsFloatSliderRow(
                label: "Recency",
                value: Binding(
                    get: { settings.salienceRecencyWeight },
                    set: { settings.salienceRecencyWeight = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.salienceRecencyWeight))",
            ) {
                settings.resetValue("salienceRecencyWeight")
            }

            HStack {
                Text("Sum")
                    .foregroundStyle(.secondary)
                Spacer()
                let total = settings.salienceUrgencyWeight
                    + settings.salienceIdentityWeight
                    + settings.salienceMirrorWeight
                    + settings.salienceRecencyWeight
                Text(String(format: "%.2f", total))
                    .foregroundStyle(abs(total - 1.0) < 0.01 ? Color.secondary : Color.red)
                    .monospacedDigit()
            }
            .font(.caption)
        }
    }
}

// MARK: - Allostasis Section

/// Section for allostasis pressure thresholds.
private struct AllostasisSettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        Section("Allostasis") {
            SettingsFloatSliderRow(
                label: "Exploratory Threshold",
                value: Binding(
                    get: { settings.allostasisExploratoryThreshold },
                    set: { settings.allostasisExploratoryThreshold = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.allostasisExploratoryThreshold))",
            ) {
                settings.resetValue("allostasisExploratoryThreshold")
            }

            SettingsFloatSliderRow(
                label: "Conservative Threshold",
                value: Binding(
                    get: { settings.allostasisConservativeThreshold },
                    set: { settings.allostasisConservativeThreshold = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.allostasisConservativeThreshold))",
            ) {
                settings.resetValue("allostasisConservativeThreshold")
            }

            SettingsFloatSliderRow(
                label: "Recovery Threshold",
                value: Binding(
                    get: { settings.allostasisRecoveryThreshold },
                    set: { settings.allostasisRecoveryThreshold = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.allostasisRecoveryThreshold))",
            ) {
                settings.resetValue("allostasisRecoveryThreshold")
            }
        }
    }
}

// MARK: - Hebbian Decay Section

/// Section for Hebbian decay half-lives and confidence bounds.
private struct HebbianDecaySettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        Section("Hebbian Decay") {
            SettingsFloatStepperRow(
                label: "Identity Claim Half-Life (days)",
                value: Binding(
                    get: { settings.identityClaimDecayHalfLifeDays },
                    set: { settings.identityClaimDecayHalfLifeDays = $0 },
                ),
                range: 1 ... 365,
                step: 1,
                hint: "Default: \(Int(CIMSDefaults.identityClaimDecayHalfLifeDays))",
            ) {
                settings.resetValue("identityClaimDecayHalfLifeDays")
            }

            SettingsFloatStepperRow(
                label: "Mirror Claim Half-Life (days)",
                value: Binding(
                    get: { settings.mirrorClaimDecayHalfLifeDays },
                    set: { settings.mirrorClaimDecayHalfLifeDays = $0 },
                ),
                range: 1 ... 365,
                step: 1,
                hint: "Default: \(Int(CIMSDefaults.mirrorClaimDecayHalfLifeDays))",
            ) {
                settings.resetValue("mirrorClaimDecayHalfLifeDays")
            }

            SettingsFloatSliderRow(
                label: "Decay Floor",
                value: Binding(
                    get: { settings.hebbianDecayFloor },
                    set: { settings.hebbianDecayFloor = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.hebbianDecayFloor))",
            ) {
                settings.resetValue("hebbianDecayFloor")
            }

            SettingsFloatSliderRow(
                label: "Decay Cap",
                value: Binding(
                    get: { settings.hebbianDecayCap },
                    set: { settings.hebbianDecayCap = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.hebbianDecayCap))",
            ) {
                settings.resetValue("hebbianDecayCap")
            }
        }
    }
}

// MARK: - Cold Storage Section

/// Section for cold storage eligibility thresholds.
private struct ColdStorageSettingsSection: View {
    let settings: SettingsManager

    var body: some View {
        Section("Cold Storage") {
            SettingsFloatSliderRow(
                label: "Hotness Threshold",
                value: Binding(
                    get: { settings.coldStorageHotnessThreshold },
                    set: { settings.coldStorageHotnessThreshold = $0 },
                ),
                hint: "Default: \(String(format: "%.2f", CIMSDefaults.coldStorageHotnessThreshold))",
            ) {
                settings.resetValue("coldStorageHotnessThreshold")
            }

            SettingsStepperRow(
                label: "Age Threshold (days)",
                value: Binding(get: { settings.coldStorageAgeDays }, set: { settings.coldStorageAgeDays = $0 }),
                range: 1 ... 365,
                step: 1,
                hint: "Default: \(CIMSDefaults.coldStorageAgeDays)",
            ) {
                settings.resetValue("coldStorageAgeDays")
            }
        }
    }
}

// MARK: - Account Section

/// Section showing OAuth status and sign-out control.
private struct AccountSettingsSection: View {
    @Environment(CIMSAppState.self) private var appState

    var body: some View {
        Section("Account") {
            let credential = ClaudeCredentialStore.activeCredential()

            HStack {
                Text("Auth Method")
                Spacer()
                if let credential {
                    Text(credential.isOAuth ? "OAuth" : "API Key")
                        .foregroundStyle(.secondary)
                } else {
                    Text("None")
                        .foregroundStyle(.red)
                }
            }

            if let credential, case let .oauthToken(_, _, expiresAt) = credential {
                HStack {
                    Text("Token Expires")
                    Spacer()
                    Text(expiresAt, style: .relative)
                        .foregroundStyle(expiresAt > Date.now ? Color.secondary : Color.red)
                }
            }

            Button(role: .destructive) {
                appState.signOut()
            } label: {
                Text("Sign Out")
            }
        }
    }
}

// MARK: - Shared Row Components

/// A labeled `Stepper` row with a default hint and reset button.
private struct SettingsStepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let hint: String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 60, alignment: .trailing)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                SettingsResetButton(action: onReset)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A labeled `Stepper` row for `Double` values with custom display formatting.
private struct SettingsDoubleStepperRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let hint: String
    let displayFormatter: (Double) -> String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(displayFormatter(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 80, alignment: .trailing)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                SettingsResetButton(action: onReset)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A labeled `Stepper` row for `Float` values displayed as integers.
private struct SettingsFloatStepperRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let step: Float
    let hint: String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
                Stepper("", value: $value, in: range, step: step)
                    .labelsHidden()
                SettingsResetButton(action: onReset)
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A labeled `Slider` row for `Float` values in [0, 1], displaying two decimal places.
private struct SettingsFloatSliderRow: View {
    let label: String
    @Binding var value: Float
    let hint: String
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 40, alignment: .trailing)
                SettingsResetButton(action: onReset)
            }
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(value) },
                        set: { value = Float($0) },
                    ),
                    in: 0.0 ... 1.0,
                )
            }
            Text(hint)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// Compact reset button used across all settings rows.
private struct SettingsResetButton: View {
    let action: () -> Void

    var body: some View {
        Button("Reset", action: action)
            .font(.caption)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Formatters

/// Formats a seconds `Double` as "X min Y sec".
private func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let minutes = total / 60
    let secs = total % 60
    if minutes == 0 {
        return "\(secs) sec"
    } else if secs == 0 {
        return "\(minutes) min"
    } else {
        return "\(minutes) min \(secs) sec"
    }
}
