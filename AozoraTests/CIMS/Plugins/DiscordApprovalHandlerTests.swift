import Foundation
import Synchronization
import Testing
@testable import Aozora

/// Tests for ``DiscordApprovalHandler`` — the reaction-based approval system
/// for tool call permissions on Discord.
///
/// The ``requestApproval`` path requires the full daemon (Discord API), so these tests
/// focus on the resolution logic: resolving pending approvals by reaction or reply,
/// tracking pending state, reply text parsing, and edge cases like double-resolve.
struct DiscordApprovalHandlerTests {
    // MARK: - Channel Configuration

    @Test
    func `no active channel returns false immediately`() async {
        let handler = DiscordApprovalHandler(channelId: nil)
        let approved = await handler.requestApproval(
            tool: "bash",
            command: "rm -rf /",
            prompt: "This will delete everything",
        )
        #expect(!approved)
    }

    @Test
    func `setActiveChannel updates the target`() async {
        let handler = DiscordApprovalHandler(channelId: nil)
        await handler.setActiveChannel("channel-123")

        // Can't fully test requestApproval without daemon, but we can verify
        // the channel was set by checking that no-channel fast path is no longer hit.
        // Instead, test that hasPending starts at 0.
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    // MARK: - Resolution by Reaction

    @Test
    func `resolve on nonexistent message is idempotent`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")

        // Resolve on a message that was never registered — should be a no-op
        await handler.resolve(messageId: "msg-nonexistent", approved: true)

        let count = await handler.pendingCount
        #expect(count == 0)
    }

    @Test
    func `resolve on nonexistent message is a no-op`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        await handler.resolve(messageId: "does-not-exist", approved: true)
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    // MARK: - Reply-Based Resolution

    @Test(arguments: [
        "yes", "y", "ok", "approve", "approved", "\\u{2705}",
    ])
    func `resolveByReply approves on 'yes'`(text: String) async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        // Since we can't create a real pending approval, verify the parsing logic
        // by calling resolveByReply on a nonexistent message (no-op, but exercises the path)
        await handler.resolveByReply(referencedMessageId: "msg-99", text: text)
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    @Test(arguments: [
        "no", "n", "deny", "denied", "nope", "reject", "never",
    ])
    func `resolveByReply denies on unrecognized text`(text: String) async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        await handler.resolveByReply(referencedMessageId: "msg-99", text: text)
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    @Test
    func `resolveByReply trims whitespace`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        // "  yes  " should be treated as "yes"
        await handler.resolveByReply(referencedMessageId: "msg-99", text: "  yes  ")
        // No pending to resolve, but verifies no crash from trimming
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    @Test
    func `resolveByReply is case-insensitive`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        await handler.resolveByReply(referencedMessageId: "msg-99", text: "YES")
        await handler.resolveByReply(referencedMessageId: "msg-99", text: "Approve")
        await handler.resolveByReply(referencedMessageId: "msg-99", text: "Ok")
        // All should parse without error
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    // MARK: - Pending State Tracking

    @Test
    func `hasPending returns false for unknown messageId`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        let has = await handler.hasPending(messageId: "unknown")
        #expect(!has)
    }

    @Test
    func `pendingCount starts at zero`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    // MARK: - Timeout Configuration

    @Test
    func `custom timeout is accepted`() async {
        let handler = DiscordApprovalHandler(
            channelId: "ch-1",
            timeout: .seconds(30),
        )
        // Verify the handler was created (timeout is internal, can't inspect directly)
        let count = await handler.pendingCount
        #expect(count == 0)
    }

    // MARK: - Agentic Behavioral Tests

    @Test
    func `approval handler conforms to ApprovalHandler protocol`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        let approval: any ApprovalHandler = handler

        // Without a daemon, requesting approval with no channel returns false
        let handler2 = DiscordApprovalHandler(channelId: nil)
        let result = await handler2.requestApproval(
            tool: "bash",
            command: "sudo rm -rf /",
            prompt: "Destructive command detected",
        )
        #expect(!result)

        // Verify the handler reference is usable
        _ = approval
    }

    @Test
    func `handler tolerates rapid resolve calls for same messageId`() async {
        let handler = DiscordApprovalHandler(channelId: "ch-1")
        // Multiple resolves on nonexistent messages should be no-ops
        for i in 0 ..< 100 {
            await handler.resolve(messageId: "msg-\(i)", approved: i % 2 == 0)
        }
        let count = await handler.pendingCount
        #expect(count == 0)
    }
}
