import Foundation

// MARK: - Permission Policy

/// The policy to apply when a tool call matches a permission rule.
///
/// Policies form a three-state decision space: unconditional allow, unconditional deny,
/// or conditional approval that requires external confirmation (e.g., from the user
/// via a messaging channel).
public nonisolated enum PermissionPolicy: String, Sendable, Codable {
    /// The tool call is permitted without further checks.
    case allow

    /// The tool call is blocked. The engine returns a ``PermissionDecision/denied(reason:)``
    /// with the matched rule's context.
    case deny

    /// The tool call requires explicit approval before proceeding.
    /// Until granted, the engine returns ``PermissionDecision/requiresApproval(prompt:)``.
    case ask
}

// MARK: - Permission Rule

/// A single permission rule that maps a tool (and optionally a command pattern) to a policy.
///
/// Rules are evaluated in priority order: deny rules override allow rules, and pattern-specific
/// rules override wildcard rules. For bash tools, the ``pattern`` field provides regex matching
/// against the `command` parameter.
///
/// ```swift
/// PermissionRule(tool: "bash", pattern: #"rm\s+-rf\s+/"#, policy: .deny)
/// PermissionRule(tool: "read", pattern: nil, policy: .allow)
/// PermissionRule(tool: "*", pattern: nil, policy: .allow)
/// ```
public nonisolated struct PermissionRule: Sendable, Codable {
    /// The tool name this rule applies to, or `"*"` for a wildcard matching all tools.
    public let tool: String

    /// Optional regex pattern for matching bash command strings.
    ///
    /// Only meaningful when ``tool`` is `"bash"`. The pattern is matched against the
    /// `command` parameter value using `NSRegularExpression`. A `nil` pattern matches
    /// all invocations of the tool.
    public let pattern: String?

    /// The policy to apply when this rule matches.
    public let policy: PermissionPolicy

    public init(tool: String, pattern: String?, policy: PermissionPolicy) {
        self.tool = tool
        self.pattern = pattern
        self.policy = policy
    }
}

// MARK: - Permission Decision

/// The outcome of evaluating a tool call against the permission engine's rule set.
///
/// Callers (typically ``ToolRegistry``) switch on the decision to either proceed with
/// execution, return an error, or surface an approval prompt.
public nonisolated enum PermissionDecision: Sendable, Equatable {
    /// The tool call is permitted.
    case allowed

    /// The tool call is denied with a human-readable reason.
    case denied(reason: String)

    /// The tool call needs approval before it can proceed.
    /// The associated prompt describes what is being requested.
    case requiresApproval(prompt: String)
}

// MARK: - Permission Engine

/// Config-driven permission engine with three evaluation layers: static rules,
/// bash pattern matching, and session grants.
///
/// The engine evaluates tool calls against a prioritized rule set:
/// 1. **Deny rules** — checked first; any matching deny rule blocks the call immediately.
/// 2. **Pattern rules** — for bash tools, regex patterns match against the command string.
///    Pattern-specific rules take precedence over tool-level rules.
/// 3. **Session grants** — runtime-accumulated approvals from the user. A session grant
///    for a tool+pattern combination upgrades an `.ask` decision to `.allowed`.
/// 4. **Static tool rules** — per-tool policies (allow/deny/ask).
/// 5. **Wildcard rule** — a rule with `tool: "*"` serves as the default for unmatched tools.
/// 6. **Default policy** — if no rules match at all, the engine falls back to its
///    configured default policy (`.allow` for private projects).
///
/// Deny always wins: a deny rule cannot be overridden by session grants or allow rules.
public actor PermissionEngine {
    /// All loaded permission rules, evaluated in the order described above.
    private var rules: [PermissionRule] = []

    /// Session-scoped grants accumulated at runtime (tool name -> set of granted patterns).
    ///
    /// A `nil` pattern in the set means the entire tool is granted for this session.
    private var sessionGrants: [String: Set<String?>] = [:]

    /// The fallback policy when no rules match a tool call.
    private let defaultPolicy: PermissionPolicy

    /// Default rules for a private project — deny dangerous bash patterns, allow everything else.
    public static let defaultRules: [PermissionRule] = [
        PermissionRule(tool: "bash", pattern: #"rm\s+-rf\s+/"#, policy: .deny),
    ]

    /// Creates a permission engine with the given default policy.
    ///
    /// - Parameter defaultPolicy: The fallback policy when no rules match. Defaults to `.allow`.
    public init(defaultPolicy: PermissionPolicy = .allow) {
        self.defaultPolicy = defaultPolicy
    }

    /// Replace the current rule set with new rules.
    ///
    /// This clears all existing rules and replaces them with the provided list.
    /// Session grants are preserved across rule reloads.
    ///
    /// - Parameter rules: The new permission rules to load.
    public func loadRules(_ rules: [PermissionRule]) {
        self.rules = rules
    }

    /// Grant a session-scoped permission for a tool, optionally scoped to a command pattern.
    ///
    /// Session grants allow `.ask` rules to be bypassed for the remainder of the session.
    /// They do NOT override `.deny` rules — deny is absolute.
    ///
    /// - Parameters:
    ///   - tool: The tool name to grant.
    ///   - pattern: Optional command pattern scope. When `nil`, grants the entire tool.
    public func grantSession(tool: String, pattern: String? = nil) {
        sessionGrants[tool, default: []].insert(pattern)
    }

    /// Clear all session grants, returning to the static rule set only.
    public func clearSessionGrants() {
        sessionGrants.removeAll()
    }

    /// Evaluate whether a tool call is permitted.
    ///
    /// The evaluation follows the priority order: deny rules first, then pattern-specific
    /// rules, then session grants, then static tool rules, then wildcard, then default.
    ///
    /// - Parameters:
    ///   - tool: The tool name being invoked.
    ///   - command: The bash command string, if the tool is `"bash"`. Ignored for other tools.
    /// - Returns: A ``PermissionDecision`` indicating whether the call is allowed, denied,
    ///   or requires approval.
    public func evaluate(tool: String, command: String? = nil) -> PermissionDecision {
        // Phase 1: Collect all matching rules, separated by specificity.
        var toolDenyRules: [PermissionRule] = []
        var patternDenyRules: [PermissionRule] = []
        var patternAllowRules: [PermissionRule] = []
        var patternAskRules: [PermissionRule] = []
        var toolRules: [PermissionRule] = []
        var wildcardRules: [PermissionRule] = []

        for rule in rules {
            if rule.tool == "*" {
                wildcardRules.append(rule)
                continue
            }

            guard rule.tool == tool else { continue }

            if let pattern = rule.pattern, let command {
                guard matches(pattern: pattern, against: command) else { continue }
                switch rule.policy {
                case .deny: patternDenyRules.append(rule)
                case .allow: patternAllowRules.append(rule)
                case .ask: patternAskRules.append(rule)
                }
            } else if rule.pattern == nil {
                if rule.policy == .deny {
                    toolDenyRules.append(rule)
                } else {
                    toolRules.append(rule)
                }
            }
        }

        // Phase 2: Pattern-specific deny always wins.
        if let rule = patternDenyRules.first {
            return .denied(reason: "Matched deny pattern: \(rule.pattern ?? tool)")
        }

        // Phase 3: Pattern-specific allow rules override tool-level rules.
        if !patternAllowRules.isEmpty {
            return .allowed
        }

        // Phase 4: Pattern-specific ask rules — check session grants first.
        if let rule = patternAskRules.first {
            if hasSessionGrant(tool: tool, command: command) {
                return .allowed
            }
            let prompt = "Tool '\(tool)' with pattern '\(rule.pattern ?? "")' requires approval"
            return .requiresApproval(prompt: prompt)
        }

        // Phase 5: Tool-level deny (after pattern-specific rules so patterns can override).
        if !toolDenyRules.isEmpty {
            return .denied(reason: "Tool '\(tool)' is denied by policy")
        }

        // Phase 6: Tool-level rules (non-deny, non-pattern).
        if let rule = toolRules.first {
            switch rule.policy {
            case .allow:
                return .allowed
            case .ask:
                if hasSessionGrant(tool: tool, command: command) {
                    return .allowed
                }
                return .requiresApproval(prompt: "Tool '\(tool)' requires approval")
            case .deny:
                return .denied(reason: "Tool '\(tool)' is denied by policy")
            }
        }

        // Phase 7: Wildcard rules.
        if let rule = wildcardRules.first {
            switch rule.policy {
            case .allow: return .allowed
            case .deny: return .denied(reason: "All tools denied by wildcard policy")
            case .ask:
                if hasSessionGrant(tool: tool, command: command) {
                    return .allowed
                }
                return .requiresApproval(prompt: "Tool '\(tool)' requires approval (wildcard policy)")
            }
        }

        // Phase 8: Default policy.
        switch defaultPolicy {
        case .allow:
            return .allowed
        case .deny:
            return .denied(reason: "No matching rule; default policy is deny")
        case .ask:
            if hasSessionGrant(tool: tool, command: command) {
                return .allowed
            }
            return .requiresApproval(prompt: "Tool '\(tool)' requires approval (default policy)")
        }
    }

    // MARK: - Private Helpers

    /// Test whether a regex pattern matches the given command string.
    ///
    /// Returns `false` on invalid regex patterns rather than crashing.
    private func matches(pattern: String, against command: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let range = NSRange(command.startIndex..., in: command)
        return regex.firstMatch(in: command, range: range) != nil
    }

    /// Check whether a session grant exists for the given tool and command.
    ///
    /// A grant with `nil` pattern covers all commands for that tool.
    /// A grant with a specific pattern must match the command.
    private func hasSessionGrant(tool: String, command: String?) -> Bool {
        guard let grants = sessionGrants[tool] else { return false }

        for grantPattern in grants {
            if grantPattern == nil {
                return true
            }
            if let command, let pattern = grantPattern, matches(pattern: pattern, against: command) {
                return true
            }
        }
        return false
    }
}
