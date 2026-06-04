import Foundation
import Testing
@testable import Aozora

struct DestructiveCommandGuardTests {
    // MARK: - Should Block

    @Test
    func `blocks plain rm`() {
        let result = DestructiveCommandGuard.check("rm file.txt"); #expect(result != .allowed)
    }
    @Test
    func `blocks rm -rf`() {
        let result = DestructiveCommandGuard.check("rm -rf /some/dir"); #expect(result != .allowed)
    }
    @Test
    func `blocks rm with flags`() {
        let result = DestructiveCommandGuard.check("rm -f -- *.log"); #expect(result != .allowed)
    }
    @Test
    func `blocks shred`() {
        let result = DestructiveCommandGuard.check("shred secret.key"); #expect(result != .allowed)
    }
    @Test
    func `blocks unlink`() {
        let result = DestructiveCommandGuard.check("unlink /tmp/socket"); #expect(result != .allowed)
    }
    @Test
    func `blocks find -delete`() {
        let result = DestructiveCommandGuard.check("find /tmp -name '*.log' -delete"); #expect(result != .allowed)
    }
    @Test
    func `blocks find -exec rm`() {
        let result = DestructiveCommandGuard.check("find . -name '*.bak' -exec rm {} \\;"); #expect(result != .allowed)
    }
    @Test
    func `blocks rm after &&`() {
        let result = DestructiveCommandGuard.check("echo done && rm file.txt"); #expect(result != .allowed)
    }
    @Test
    func `blocks rm after semicolon`() {
        let result = DestructiveCommandGuard.check("cd /tmp; rm -rf build/"); #expect(result != .allowed)
    }
    @Test
    func `blocks rm after pipe`() {
        let result = DestructiveCommandGuard.check("ls | xargs rm"); #expect(result != .allowed)
    }
    @Test
    func `blocks sudo rm`() {
        let result = DestructiveCommandGuard.check("sudo rm -rf /var/log/old"); #expect(result != .allowed)
    }
    @Test
    func `blocks backslash-escaped rm`() {
        let result = DestructiveCommandGuard.check("\\rm file.txt"); #expect(result != .allowed)
    }
    @Test
    func `blocks subshell rm`() {
        let result = DestructiveCommandGuard.check("bash -c 'rm -rf /tmp/build'"); #expect(result != .allowed)
    }
    @Test
    func `blocks absolute path to rm`() {
        let result = DestructiveCommandGuard.check("/bin/rm file.txt"); #expect(result != .allowed)
    }

    // MARK: - Should Allow

    @Test
    func `allows git rm`() {
        let result = DestructiveCommandGuard.check("git rm --cached file.txt"); #expect(result == .allowed)
    }
    @Test
    func `allows cargo rm`() {
        let result = DestructiveCommandGuard.check("cargo rm serde"); #expect(result == .allowed)
    }
    @Test
    func `allows echo containing rm`() {
        let result = DestructiveCommandGuard.check("echo 'rm -rf is dangerous'"); #expect(result == .allowed)
    }
    @Test
    func `allows grep for rm pattern`() {
        let result = DestructiveCommandGuard.check("grep -r 'rm -rf' docs/"); #expect(result == .allowed)
    }
    @Test
    func `allows trash command`() {
        let result = DestructiveCommandGuard.check("trash old-dir/"); #expect(result == .allowed)
    }
    @Test
    func `allows normal commands`() {
        #expect(DestructiveCommandGuard.check("ls -la") == .allowed)
        #expect(DestructiveCommandGuard.check("swift build") == .allowed)
        #expect(DestructiveCommandGuard.check("cat file.txt") == .allowed)
        #expect(DestructiveCommandGuard.check("mkdir -p new/dir") == .allowed)
    }

    // MARK: - Auto-Rewrite

    @Test
    func `rewrites simple rm to trash`() {
        let result = DestructiveCommandGuard.check("rm file.txt")
        if case let .rewrite(cmd) = result { #expect(cmd == "trash file.txt") } else { Issue.record("Expected rewrite, got \(result)") }
    }
    @Test
    func `rewrites rm -rf to trash`() {
        let result = DestructiveCommandGuard.check("rm -rf build/")
        if case let .rewrite(cmd) = result { #expect(cmd == "trash build/") } else { Issue.record("Expected rewrite, got \(result)") }
    }
    @Test
    func `rewrites rm with multiple files to trash`() {
        let result = DestructiveCommandGuard.check("rm a.txt b.txt c.txt")
        if case let .rewrite(cmd) = result { #expect(cmd == "trash a.txt b.txt c.txt") } else { Issue.record("Expected rewrite, got \(result)") }
    }
    @Test
    func `blocks complex rm (cannot safely rewrite)`() {
        let result = DestructiveCommandGuard.check("find . -name '*.o' | xargs rm")
        if case .blocked = result { } else { Issue.record("Expected blocked, got \(result)") }
    }
}
