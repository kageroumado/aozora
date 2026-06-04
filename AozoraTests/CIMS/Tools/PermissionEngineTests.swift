import Foundation
import Testing
@testable import Aozora

struct PermissionEngineTests {
    @Test
    func `allow rule permits tool execution`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "read", pattern: nil, policy: .allow),
        ])

        let decision = await engine.evaluate(tool: "read")
        #expect(decision == .allowed)
    }

    @Test
    func `deny rule blocks tool execution`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: nil, policy: .deny),
        ])

        let decision = await engine.evaluate(tool: "bash", command: "echo hello")
        if case .denied = decision { } else {
            Issue.record("Expected denied, got \(decision)")
        }
    }

    @Test
    func `ask rule returns requiresApproval`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "write", pattern: nil, policy: .ask),
        ])

        let decision = await engine.evaluate(tool: "write")
        if case .requiresApproval = decision { } else {
            Issue.record("Expected requiresApproval, got \(decision)")
        }
    }

    @Test
    func `session grant upgrades ask to allowed`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "write", pattern: nil, policy: .ask),
        ])

        let before = await engine.evaluate(tool: "write")
        if case .requiresApproval = before { } else {
            Issue.record("Expected requiresApproval before grant, got \(before)")
        }

        await engine.grantSession(tool: "write")

        let after = await engine.evaluate(tool: "write")
        #expect(after == .allowed)
    }

    @Test
    func `bash pattern allow rule permits matching command`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: #"^swift build"#, policy: .allow),
            PermissionRule(tool: "bash", pattern: nil, policy: .deny),
        ])

        let allowed = await engine.evaluate(tool: "bash", command: "swift build --build-tests")
        #expect(allowed == .allowed)

        let denied = await engine.evaluate(tool: "bash", command: "echo hello")
        if case .denied = denied { } else {
            Issue.record("Expected denied for non-matching command, got \(denied)")
        }
    }

    @Test
    func `bash pattern deny rule blocks matching command`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: #"rm\s+-rf\s+/"#, policy: .deny),
            PermissionRule(tool: "bash", pattern: nil, policy: .allow),
        ])

        let denied = await engine.evaluate(tool: "bash", command: "rm -rf /")
        if case .denied = denied { } else {
            Issue.record("Expected denied for destructive command, got \(denied)")
        }

        let allowed = await engine.evaluate(tool: "bash", command: "echo safe")
        #expect(allowed == .allowed)
    }

    @Test
    func `deny overrides allow when both match`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: #"rm\s+-rf"#, policy: .deny),
            PermissionRule(tool: "bash", pattern: #"rm"#, policy: .allow),
            PermissionRule(tool: "bash", pattern: nil, policy: .allow),
        ])

        let decision = await engine.evaluate(tool: "bash", command: "rm -rf /tmp/build")
        if case .denied = decision { } else {
            Issue.record("Expected deny to override allow, got \(decision)")
        }
    }

    @Test
    func `default policy applies when no rules match`() async {
        let allowEngine = PermissionEngine(defaultPolicy: .allow)
        let decision1 = await allowEngine.evaluate(tool: "unknown_tool")
        #expect(decision1 == .allowed)

        let denyEngine = PermissionEngine(defaultPolicy: .deny)
        let decision2 = await denyEngine.evaluate(tool: "unknown_tool")
        if case .denied = decision2 { } else {
            Issue.record("Expected denied with deny default, got \(decision2)")
        }

        let askEngine = PermissionEngine(defaultPolicy: .ask)
        let decision3 = await askEngine.evaluate(tool: "unknown_tool")
        if case .requiresApproval = decision3 { } else {
            Issue.record("Expected requiresApproval with ask default, got \(decision3)")
        }
    }

    @Test
    func `DestructiveCommandGuard still works independently of permission layer`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: nil, policy: .allow),
        ])

        let permissionDecision = await engine.evaluate(
            tool: "bash",
            command: "rm -rf /important",
        )
        #expect(permissionDecision == .allowed)

        let guardVerdict = DestructiveCommandGuard.check("rm -rf /important")
        #expect(guardVerdict != .allowed)
    }

    @Test
    func `wildcard rule applies to unmatched tools`() async {
        let engine = PermissionEngine(defaultPolicy: .deny)
        await engine.loadRules([
            PermissionRule(tool: "*", pattern: nil, policy: .allow),
        ])

        let decision = await engine.evaluate(tool: "some_new_tool")
        #expect(decision == .allowed)
    }

    @Test
    func `tool-specific rule takes precedence over wildcard`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: nil, policy: .deny),
            PermissionRule(tool: "*", pattern: nil, policy: .allow),
        ])

        let bashDecision = await engine.evaluate(tool: "bash", command: "echo hi")
        if case .denied = bashDecision { } else {
            Issue.record("Expected bash denied despite wildcard allow, got \(bashDecision)")
        }

        let readDecision = await engine.evaluate(tool: "read")
        #expect(readDecision == .allowed)
    }

    @Test
    func `session grant does not override deny`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: nil, policy: .deny),
        ])

        await engine.grantSession(tool: "bash")

        let decision = await engine.evaluate(tool: "bash", command: "echo hello")
        if case .denied = decision { } else {
            Issue.record("Expected deny to persist despite session grant, got \(decision)")
        }
    }

    @Test
    func `pattern-scoped session grant only matches specific commands`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: nil, policy: .ask),
        ])

        await engine.grantSession(tool: "bash", pattern: #"^git push"#)

        let pushDecision = await engine.evaluate(tool: "bash", command: "git push origin main")
        #expect(pushDecision == .allowed)

        let otherDecision = await engine.evaluate(tool: "bash", command: "echo hello")
        if case .requiresApproval = otherDecision { } else {
            Issue.record("Expected requiresApproval for non-matching command, got \(otherDecision)")
        }
    }

    @Test
    func `clearSessionGrants removes all grants`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "write", pattern: nil, policy: .ask),
        ])

        await engine.grantSession(tool: "write")
        let granted = await engine.evaluate(tool: "write")
        #expect(granted == .allowed)

        await engine.clearSessionGrants()
        let cleared = await engine.evaluate(tool: "write")
        if case .requiresApproval = cleared { } else {
            Issue.record("Expected requiresApproval after clearing grants, got \(cleared)")
        }
    }

    @Test
    func `loadRules replaces previous rules`() async {
        let engine = PermissionEngine()
        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: nil, policy: .deny),
        ])

        let denied = await engine.evaluate(tool: "bash", command: "echo hi")
        if case .denied = denied { } else {
            Issue.record("Expected denied, got \(denied)")
        }

        await engine.loadRules([
            PermissionRule(tool: "bash", pattern: nil, policy: .allow),
        ])

        let allowed = await engine.evaluate(tool: "bash", command: "echo hi")
        #expect(allowed == .allowed)
    }

    @Test
    func `default rules deny rm -rf /`() async {
        let engine = PermissionEngine()
        await engine.loadRules(PermissionEngine.defaultRules)

        let decision = await engine.evaluate(
            tool: "bash",
            command: "rm -rf /var/log",
        )
        if case .denied = decision { } else {
            Issue.record("Expected default rules to deny rm -rf /, got \(decision)")
        }

        let safeDecision = await engine.evaluate(
            tool: "bash",
            command: "swift build",
        )
        #expect(safeDecision == .allowed)
    }
}
