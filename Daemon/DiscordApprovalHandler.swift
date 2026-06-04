import Foundation

/// Discord-based approval handler for tool call permission requests.
///
/// When a tool call requires approval, this handler sends a message to the active Discord
/// channel with approval/denial reactions (✅/❌). It then adds the reactions as options
/// and waits for the user to react or reply. The handler uses a continuation-based approach
/// where the ``EventLoop`` resolves pending approvals when a matching reaction or reply arrives.
///
/// Approval requests time out after a configurable duration (default: 60 seconds).
///
actor DiscordApprovalHandler: ApprovalHandler {
    /// A pending approval request awaiting user response.
    private struct PendingApproval {
        /// The Discord message ID of the approval prompt.
        let messageId: String
        /// Continuation to resume when the user responds.
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Active approval requests keyed by Discord message ID.
    private var pending: [String: PendingApproval] = [:]

    /// The Discord channel ID to send approval prompts to.
    private var activeChannelId: String?

    /// Timeout duration for approval requests.
    private let timeout: Duration

    /// Creates a Discord approval handler.
    ///
    /// - Parameters:
    ///   - channelId: The Discord channel ID for approval prompts.
    ///   - timeout: How long to wait for a response before auto-denying.
    init(channelId: String? = nil, timeout: Duration = .seconds(60)) {
        self.activeChannelId = channelId
        self.timeout = timeout
    }

    /// Update the active channel for approval prompts.
    ///
    /// Called when the daemon switches to a new Discord channel.
    func setActiveChannel(_ channelId: String?) {
        activeChannelId = channelId
    }

    // MARK: - ApprovalHandler Conformance

    nonisolated func requestApproval(tool: String, command: String?, prompt: String) async -> Bool {
        await requestApprovalIsolated(tool: tool, command: command, prompt: prompt)
    }

    /// Actor-isolated implementation of approval request.
    private func requestApprovalIsolated(tool: String, command: String?, prompt: String) async -> Bool {
        guard let channelId = activeChannelId else {
            return false
        }

        let description = if let command {
            "**\(tool)**: `\(command)`"
        } else {
            "**\(tool)**"
        }

        let approvalMessage = """
        🔐 **Approval Required**
        \(prompt)
        
        \(description)
        
        React ✅ to approve or ❌ to deny (auto-denies in 60s)
        """

        guard let messageId = await AozoraDaemon.sendDiscordMessageReturningId(
            channelId: channelId,
            content: approvalMessage,
        ) else {
            return false
        }

        await AozoraDaemon.addReaction(channelId: channelId, messageId: messageId, emoji: "✅")
        await AozoraDaemon.addReaction(channelId: channelId, messageId: messageId, emoji: "❌")

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.registerPending(messageId: messageId, continuation: continuation)
        }
    }

    /// Register a pending approval for later resolution.
    private func registerPending(messageId: String, continuation: CheckedContinuation<Bool, Never>) {
        pending[messageId] = PendingApproval(messageId: messageId, continuation: continuation)

        Task {
            try? await Task.sleep(for: timeout)
            await self.resolveIfPending(messageId: messageId, approved: false)
        }
    }

    // MARK: - Resolution

    /// Resolve a pending approval request.
    ///
    /// Called by the event loop when a user reacts to or replies to an approval message.
    ///
    /// - Parameters:
    ///   - messageId: The approval message's Discord ID.
    ///   - approved: Whether the user approved (`true`) or denied (`false`).
    func resolve(messageId: String, approved: Bool) {
        resolveIfPending(messageId: messageId, approved: approved)
    }

    /// Resolve a pending approval by message reference (reply).
    ///
    /// When a user replies with "yes", "approve", "ok", etc., the event loop calls this
    /// with the referenced message ID.
    ///
    /// - Parameters:
    ///   - referencedMessageId: The approval message being replied to.
    ///   - text: The reply text.
    func resolveByReply(referencedMessageId: String, text: String) {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let approved = ["yes", "y", "ok", "approve", "approved", "✅"].contains(lower)
        resolveIfPending(messageId: referencedMessageId, approved: approved)
    }

    /// Check if there's a pending approval for a given message ID.
    func hasPending(messageId: String) -> Bool {
        pending[messageId] != nil
    }

    /// The number of currently pending approval requests.
    var pendingCount: Int {
        pending.count
    }

    // MARK: - Private

    /// Resolve a pending approval if it exists, removing it from the pending map.
    private func resolveIfPending(messageId: String, approved: Bool) {
        guard let approval = pending.removeValue(forKey: messageId) else { return }
        approval.continuation.resume(returning: approved)
    }
}
