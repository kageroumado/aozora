import AozoraCore
import Foundation

/// Wraps ``CIMSDefaults`` with ``UserDefaults`` overrides for runtime configuration.
///
/// Each CIMS setting is a computed property that checks UserDefaults first,
/// falling back to the compile-time default from ``CIMSDefaults``. Changes take effect
/// on the next turn. All keys are prefixed with `cims.` to avoid collisions.
///
/// Salience weights auto-normalize to sum 1.0 when any individual weight is changed,
/// preserving the relative ratios of the other three weights.
@Observable
final class SettingsManager {
    // MARK: - Storage

    /// The backing UserDefaults store.
    private let defaults = UserDefaults.standard

    /// Key prefix for all CIMS settings in UserDefaults.
    private let prefix = "cims."

    // MARK: - Model

    /// System prompt prepended to every assembled context.
    ///
    /// Default: `"You are a helpful assistant."`
    var systemPrompt: String {
        get { overrideString("systemPrompt") ?? "You are a helpful assistant." }
        set { defaults.set(newValue, forKey: prefix + "systemPrompt") }
    }

    /// Maximum token count for model responses.
    ///
    /// Default: `4096`. This is a settings-only value not present in ``CIMSDefaults``.
    var maxTokens: Int {
        get { overrideInt("maxTokens") ?? 4_096 }
        set { defaults.set(newValue, forKey: prefix + "maxTokens") }
    }

    // MARK: - Memory

    /// Protected tail count override. Default: ``CIMSDefaults/protectedTailCount`` (100).
    ///
    /// Minimum number of meaningful messages that are never compacted.
    var protectedTailCount: Int {
        get { overrideInt("protectedTailCount") ?? CIMSDefaults.protectedTailCount }
        set { defaults.set(newValue, forKey: prefix + "protectedTailCount") }
    }

    /// Leaf chunk token threshold override. Default: ``CIMSDefaults/leafChunkTokens`` (20,000).
    ///
    /// Raw token count that triggers leaf compaction.
    var leafChunkTokens: Int {
        get { overrideInt("leafChunkTokens") ?? CIMSDefaults.leafChunkTokens }
        set { defaults.set(newValue, forKey: prefix + "leafChunkTokens") }
    }

    /// Leaf target token max override. Default: ``CIMSDefaults/leafTargetTokensMax`` (4,000).
    ///
    /// Maximum token budget for leaf summaries.
    var leafTargetTokensMax: Int {
        get { overrideInt("leafTargetTokensMax") ?? CIMSDefaults.leafTargetTokensMax }
        set { defaults.set(newValue, forKey: prefix + "leafTargetTokensMax") }
    }

    /// Large file token threshold override. Default: ``CIMSDefaults/largeFileTokenThreshold`` (25,000).
    ///
    /// Token count above which file content is intercepted and stored separately.
    var largeFileTokenThreshold: Int {
        get { overrideInt("largeFileTokenThreshold") ?? CIMSDefaults.largeFileTokenThreshold }
        set { defaults.set(newValue, forKey: prefix + "largeFileTokenThreshold") }
    }

    // MARK: - Workers

    /// Maximum concurrent workers override. Default: ``CIMSDefaults/maxConcurrentWorkers`` (4).
    var maxConcurrentWorkers: Int {
        get { overrideInt("maxConcurrentWorkers") ?? CIMSDefaults.maxConcurrentWorkers }
        set { defaults.set(newValue, forKey: prefix + "maxConcurrentWorkers") }
    }

    /// Maximum workers per user override. Default: ``CIMSDefaults/maxWorkersPerUser`` (1).
    var maxWorkersPerUser: Int {
        get { overrideInt("maxWorkersPerUser") ?? CIMSDefaults.maxWorkersPerUser }
        set { defaults.set(newValue, forKey: prefix + "maxWorkersPerUser") }
    }

    /// Default worker token budget override. Default: ``CIMSDefaults/workerDefaultBudget`` (50,000).
    var workerDefaultBudget: Int {
        get { overrideInt("workerDefaultBudget") ?? CIMSDefaults.workerDefaultBudget }
        set { defaults.set(newValue, forKey: prefix + "workerDefaultBudget") }
    }

    /// Delegation grant time-to-live in seconds. Default: ``CIMSDefaults/delegationGrantTTL`` (300s).
    ///
    /// Stored as a `Double` representing seconds; the ``CIMSDefaults`` value is a `Duration`.
    var delegationGrantTTLSeconds: Double {
        get { overrideDouble("delegationGrantTTLSeconds") ?? 300 }
        set { defaults.set(newValue, forKey: prefix + "delegationGrantTTLSeconds") }
    }

    // MARK: - Consolidation

    /// Consolidation idle timeout in seconds. Default: ``CIMSDefaults/consolidationIdleTimeout`` (900s).
    ///
    /// Idle time after the last message before routine consolidation triggers.
    var consolidationIdleTimeoutSeconds: Double {
        get { overrideDouble("consolidationIdleTimeoutSeconds") ?? 900 }
        set { defaults.set(newValue, forKey: prefix + "consolidationIdleTimeoutSeconds") }
    }

    /// Session-end consolidation delay in seconds. Default: ``CIMSDefaults/consolidationSessionEndDelay`` (300s).
    ///
    /// Delay after the last response before session-end consolidation triggers.
    var consolidationSessionEndDelaySeconds: Double {
        get { overrideDouble("consolidationSessionEndDelaySeconds") ?? 300 }
        set { defaults.set(newValue, forKey: prefix + "consolidationSessionEndDelaySeconds") }
    }

    // MARK: - Salience Weights

    /// Urgency weight in composite salience scoring. Default: ``CIMSDefaults/salienceUrgencyWeight`` (0.3).
    ///
    /// Setting this auto-normalizes the other three weights so the total remains 1.0.
    var salienceUrgencyWeight: Float {
        get { overrideFloat("salienceUrgencyWeight") ?? CIMSDefaults.salienceUrgencyWeight }
        set {
            defaults.set(newValue, forKey: prefix + "salienceUrgencyWeight")
            normalizeSalienceWeights(changedKey: "salienceUrgencyWeight")
        }
    }

    /// Identity relevance weight in composite salience scoring. Default: ``CIMSDefaults/salienceIdentityWeight`` (0.3).
    ///
    /// Setting this auto-normalizes the other three weights so the total remains 1.0.
    var salienceIdentityWeight: Float {
        get { overrideFloat("salienceIdentityWeight") ?? CIMSDefaults.salienceIdentityWeight }
        set {
            defaults.set(newValue, forKey: prefix + "salienceIdentityWeight")
            normalizeSalienceWeights(changedKey: "salienceIdentityWeight")
        }
    }

    /// Mirror relevance weight in composite salience scoring. Default: ``CIMSDefaults/salienceMirrorWeight`` (0.2).
    ///
    /// Setting this auto-normalizes the other three weights so the total remains 1.0.
    var salienceMirrorWeight: Float {
        get { overrideFloat("salienceMirrorWeight") ?? CIMSDefaults.salienceMirrorWeight }
        set {
            defaults.set(newValue, forKey: prefix + "salienceMirrorWeight")
            normalizeSalienceWeights(changedKey: "salienceMirrorWeight")
        }
    }

    /// Temporal recency weight in composite salience scoring. Default: ``CIMSDefaults/salienceRecencyWeight`` (0.2).
    ///
    /// Setting this auto-normalizes the other three weights so the total remains 1.0.
    var salienceRecencyWeight: Float {
        get { overrideFloat("salienceRecencyWeight") ?? CIMSDefaults.salienceRecencyWeight }
        set {
            defaults.set(newValue, forKey: prefix + "salienceRecencyWeight")
            normalizeSalienceWeights(changedKey: "salienceRecencyWeight")
        }
    }

    // MARK: - Allostasis

    /// Pressure threshold for exploratory mode. Default: ``CIMSDefaults/allostasisExploratoryThreshold`` (0.3).
    ///
    /// Below this pressure, the system enters exploratory mode.
    var allostasisExploratoryThreshold: Float {
        get { overrideFloat("allostasisExploratoryThreshold") ?? CIMSDefaults.allostasisExploratoryThreshold }
        set { defaults.set(newValue, forKey: prefix + "allostasisExploratoryThreshold") }
    }

    /// Pressure threshold for conservative mode. Default: ``CIMSDefaults/allostasisConservativeThreshold`` (0.7).
    ///
    /// Above this pressure, the system enters conservative mode.
    var allostasisConservativeThreshold: Float {
        get { overrideFloat("allostasisConservativeThreshold") ?? CIMSDefaults.allostasisConservativeThreshold }
        set { defaults.set(newValue, forKey: prefix + "allostasisConservativeThreshold") }
    }

    /// Pressure threshold for recovery mode. Default: ``CIMSDefaults/allostasisRecoveryThreshold`` (0.9).
    ///
    /// Above this pressure, the system enters recovery mode.
    var allostasisRecoveryThreshold: Float {
        get { overrideFloat("allostasisRecoveryThreshold") ?? CIMSDefaults.allostasisRecoveryThreshold }
        set { defaults.set(newValue, forKey: prefix + "allostasisRecoveryThreshold") }
    }

    // MARK: - Hebbian Decay

    /// Identity claim decay half-life in days. Default: ``CIMSDefaults/identityClaimDecayHalfLifeDays`` (90).
    ///
    /// Identity claims decay slowly — values are stable.
    var identityClaimDecayHalfLifeDays: Float {
        get { overrideFloat("identityClaimDecayHalfLifeDays") ?? CIMSDefaults.identityClaimDecayHalfLifeDays }
        set { defaults.set(newValue, forKey: prefix + "identityClaimDecayHalfLifeDays") }
    }

    /// Mirror claim decay half-life in days. Default: ``CIMSDefaults/mirrorClaimDecayHalfLifeDays`` (60).
    ///
    /// Mirror claims decay faster than identity — people change.
    var mirrorClaimDecayHalfLifeDays: Float {
        get { overrideFloat("mirrorClaimDecayHalfLifeDays") ?? CIMSDefaults.mirrorClaimDecayHalfLifeDays }
        set { defaults.set(newValue, forKey: prefix + "mirrorClaimDecayHalfLifeDays") }
    }

    /// Minimum confidence floor for Hebbian decay. Default: ``CIMSDefaults/hebbianDecayFloor`` (0.05).
    ///
    /// Claims never decay below this value, keeping them discoverable.
    var hebbianDecayFloor: Float {
        get { overrideFloat("hebbianDecayFloor") ?? CIMSDefaults.hebbianDecayFloor }
        set { defaults.set(newValue, forKey: prefix + "hebbianDecayFloor") }
    }

    /// Maximum confidence cap for Hebbian decay. Default: ``CIMSDefaults/hebbianDecayCap`` (1.0).
    ///
    /// Claims never exceed this confidence value.
    var hebbianDecayCap: Float {
        get { overrideFloat("hebbianDecayCap") ?? CIMSDefaults.hebbianDecayCap }
        set { defaults.set(newValue, forKey: prefix + "hebbianDecayCap") }
    }

    // MARK: - Cold Storage

    /// Hotness threshold for cold storage eligibility. Default: ``CIMSDefaults/coldStorageHotnessThreshold`` (0.1).
    ///
    /// Nodes below this hotness become cold storage candidates.
    var coldStorageHotnessThreshold: Float {
        get { overrideFloat("coldStorageHotnessThreshold") ?? CIMSDefaults.coldStorageHotnessThreshold }
        set { defaults.set(newValue, forKey: prefix + "coldStorageHotnessThreshold") }
    }

    /// Age threshold in days for cold storage eligibility. Default: ``CIMSDefaults/coldStorageAgeDays`` (30).
    ///
    /// Nodes must also be below ``coldStorageHotnessThreshold`` to be demoted.
    var coldStorageAgeDays: Int {
        get { overrideInt("coldStorageAgeDays") ?? CIMSDefaults.coldStorageAgeDays }
        set { defaults.set(newValue, forKey: prefix + "coldStorageAgeDays") }
    }

    // MARK: - Reset

    /// Resets a single setting to its ``CIMSDefaults`` value by removing the UserDefaults override.
    ///
    /// - Parameter key: The setting key without the `cims.` prefix (e.g., `"freshTailCount"`).
    func resetValue(_ key: String) {
        defaults.removeObject(forKey: prefix + key)
    }

    /// Resets all CIMS settings to their ``CIMSDefaults`` values.
    ///
    /// Removes every UserDefaults key that starts with the `cims.` prefix.
    func resetAll() {
        let dict = defaults.dictionaryRepresentation()
        for key in dict.keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Private Helpers

    /// Returns the UserDefaults integer for the given key, or `nil` if no override exists.
    private func overrideInt(_ key: String) -> Int? {
        defaults.object(forKey: prefix + key) != nil ? defaults.integer(forKey: prefix + key) : nil
    }

    /// Returns the UserDefaults float for the given key, or `nil` if no override exists.
    private func overrideFloat(_ key: String) -> Float? {
        defaults.object(forKey: prefix + key) != nil ? defaults.float(forKey: prefix + key) : nil
    }

    /// Returns the UserDefaults double for the given key, or `nil` if no override exists.
    private func overrideDouble(_ key: String) -> Double? {
        defaults.object(forKey: prefix + key) != nil ? defaults.double(forKey: prefix + key) : nil
    }

    /// Returns the UserDefaults string for the given key, or `nil` if no override exists.
    private func overrideString(_ key: String) -> String? {
        defaults.string(forKey: prefix + key)
    }

    /// Returns the default salience weight for the given key from ``CIMSDefaults``.
    private func defaultSalienceWeight(_ key: String) -> Float {
        switch key {
        case "salienceUrgencyWeight": CIMSDefaults.salienceUrgencyWeight
        case "salienceIdentityWeight": CIMSDefaults.salienceIdentityWeight
        case "salienceMirrorWeight": CIMSDefaults.salienceMirrorWeight
        case "salienceRecencyWeight": CIMSDefaults.salienceRecencyWeight
        default: 0.25
        }
    }

    /// Normalizes salience weights so they sum to 1.0 after one weight changed.
    ///
    /// The changed weight is left as-is; the other three are scaled proportionally
    /// so their relative ratios are preserved while the total remains exactly 1.0.
    ///
    /// - Parameter changedKey: The key of the weight that was just set.
    private func normalizeSalienceWeights(changedKey: String) {
        let keys = [
            "salienceUrgencyWeight",
            "salienceIdentityWeight",
            "salienceMirrorWeight",
            "salienceRecencyWeight",
        ]
        let otherKeys = keys.filter { $0 != changedKey }

        let changedValue = overrideFloat(changedKey) ?? defaultSalienceWeight(changedKey)
        let remaining = 1.0 - changedValue
        let otherSum = otherKeys.reduce(Float(0)) {
            $0 + (overrideFloat($1) ?? defaultSalienceWeight($1))
        }

        guard otherSum > 0 else { return }
        let scale = remaining / otherSum

        for key in otherKeys {
            let current = overrideFloat(key) ?? defaultSalienceWeight(key)
            defaults.set(current * scale, forKey: prefix + key)
        }
    }
}
