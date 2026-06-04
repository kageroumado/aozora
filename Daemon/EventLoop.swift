import DequeModule
import Foundation

/// All events that flow through the daemon's main event loop.
enum DaemonEvent {
    /// A new message arrived from Discord.
    case message(InboundMessage)

    /// An IPC client sent a message — route through the event loop for turn serialization.
    case ipcMessage(IPCInboundContext)

    /// The heartbeat timer fired.
    case heartbeat

    /// A turn completed (success, failure, cancellation, or silent).
    case turnCompleted(TurnCompletion)

    /// A background process exited.
    case processCompleted(ProcessCompletion)

    /// A fork turn finished — result ready for injection.
    case forkCompleted(ForkResult)

    /// A backgrounded worker finished.
    case workerCompleted(WorkerCompletion)

    /// A cron job fired and needs execution as a system-initiated turn.
    case cronJobFired(FiredJob)
}

/// Context for IPC-originated messages routed through the event queue.
///
/// Captures the metadata needed to construct a ``TurnRequest`` when the event loop
/// processes the message. Broadcast of the user message to other IPC clients happens
/// eagerly in ``DaemonIPC`` before enqueuing — only turn execution is deferred.
struct IPCInboundContext {
    let text: String
    let sessionKey: String
    let images: [ImageAttachment]
}

/// Result of a completed turn.
enum TurnCompletion {
    case completed(channelId: String, response: String)
    case silent(channelId: String)
    case failed(channelId: String, error: String)
    case cancelled(channelId: String, reason: String)

    /// Turn hit tool limit — needs auto-continuation.
    case continuation(channelId: String, summary: String, depth: Int)
}

/// Event-driven daemon controller.
///
/// Replaces the blocking `runMessageLoop` with a non-blocking event loop.
/// Turns run in detached Tasks — the event loop never blocks on turn execution.
/// Messages that arrive during a turn are acknowledged with 👀 and queued.
///
/// **State machine:**
/// - `idle`: No turn running. Messages start turns. Heartbeats start heartbeat turns.
/// - `processing(Task, channelId)`: A turn is running. Messages get 👀 + queued.
///   Stop words cancel the turn.
/// - `heartbeating(Task)`: A heartbeat turn is running. Messages get 👀 + queued.
actor EventLoop {
    /// Words that immediately cancel the active turn.
    private static let stopWords: Set<String> = ["stop", "cancel", "abort", "nevermind"]

    enum State {
        case idle
        case processing(task: Task<Void, Never>, channelId: String)
        case heartbeating(task: Task<Void, Never>)
    }

    /// Items waiting to be processed after the current turn completes.
    enum PendingItem {
        case discord(message: InboundMessage, channelId: String, authorId: String)
        case ipc(context: IPCInboundContext)
    }

    private var state: State = .idle
    private var pendingMessages: Deque<PendingItem> = []

    /// The channel ID of the most recently started turn.
    ///
    /// Used as a fallback routing target for background completions (e.g., ``ProcessCompletion``)
    /// that don't carry their own channel ID. Persists across turns so the result still reaches
    /// the agent even when the loop is idle.
    private var lastActiveChannelId: String = ""
    private let queue: AsyncQueue<DaemonEvent>
    private let gateway: CIMSGateway
    private let ipc: DaemonIPC
    private let heartbeatSendAlert: @Sendable (String) async -> Void
    private let heartbeatSendMessage: @Sendable (String) async -> String?
    private let heartbeatEditMessage: @Sendable (String, String) async -> Void
    private let heartbeatScheduler: HeartbeatScheduler
    private let heartbeatEngine: HeartbeatEngine

    init(
        queue: AsyncQueue<DaemonEvent>,
        gateway: CIMSGateway,
        ipc: DaemonIPC,
        heartbeatScheduler: HeartbeatScheduler,
        heartbeatEngine: HeartbeatEngine,
        heartbeatSendAlert: @escaping @Sendable (String) async -> Void,
        heartbeatSendMessage: @escaping @Sendable (String) async -> String?,
        heartbeatEditMessage: @escaping @Sendable (String, String) async -> Void,
    ) {
        self.queue = queue
        self.gateway = gateway
        self.ipc = ipc
        self.heartbeatScheduler = heartbeatScheduler
        self.heartbeatEngine = heartbeatEngine
        self.heartbeatSendAlert = heartbeatSendAlert
        self.heartbeatSendMessage = heartbeatSendMessage
        self.heartbeatEditMessage = heartbeatEditMessage
    }

    /// Main event loop — runs until cancelled.
    func run() async {
        while !Task.isCancelled {
            let event = await queue.dequeue()

            switch event {
            case let .message(message):
                await handleMessage(message)

            case let .ipcMessage(context):
                await handleIPCMessage(context)

            case .heartbeat:
                handleHeartbeat()

            case let .turnCompleted(completion):
                await handleTurnCompleted(completion)

            case let .processCompleted(completion):
                let status = completion.exitCode == 0 ? "completed successfully" : "failed (exit \(completion.exitCode))"
                let secs = Int(completion.elapsed.components.seconds)
                let text = """
                [Background process \(status): \(completion.processId)]
                Command: \(completion.command)
                Duration: \(secs)s
                
                --- Output (last 50 lines) ---
                \(completion.tailOutput.isEmpty ? "(no output)" : completion.tailOutput)
                """
                handleBackgroundResult(text, channelId: lastActiveChannelId)

            case let .forkCompleted(result):
                let secs = Int(result.elapsed.components.seconds)
                let text = """
                [Fork completed: \(result.goal)]
                Duration: \(secs)s, Tool calls: \(result.toolCallCount)
                
                \(result.response)
                """
                handleBackgroundResult(text, channelId: result.channelId)

            case let .workerCompleted(completion):
                let secs = Int(completion.elapsed.components.seconds)
                let text = """
                [Worker completed: \(completion.runId)]
                Duration: \(secs)s
                
                \(completion.summary.narrative)
                """
                handleBackgroundResult(text, channelId: completion.channelId)

            case let .cronJobFired(job):
                handleCronJob(job)
            }
        }
    }

    // MARK: - Event Handlers

    private func handleMessage(_ message: InboundMessage) async {
        guard let (channelId, _, authorId) = Self.extractMetadata(message) else { return }

        let authorName = {
            guard let metadata = message.parts.first?.metadata,
                  let metaData = metadata.data(using: .utf8),
                  let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: String]
            else { return "unknown" }
            return meta["discord_author_name"] ?? "unknown"
        }()

        print("[→] \(authorName): \(message.text.prefix(80))")
        await heartbeatScheduler.recordActivity()
        await heartbeatEngine.recordUserActivity()

        Task {
            await ipc.broadcast(.message(IPCChatMessage(
                role: "user",
                content: message.text,
                channel: "discord",
                author: authorName,
                timestamp: Date().timeIntervalSince1970,
            )))
        }

        switch state {
        case .idle:
            startTurn(message: message, channelId: channelId, authorId: authorId)

        case let .processing(task, _):
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Self.stopWords.contains(text) {
                print("[🛑] Stop word received, cancelling turn")
                task.cancel()
            } else {
                Self.reactWithEyes(message)
                pendingMessages.append(.discord(message: message, channelId: channelId, authorId: authorId))
            }

        case .heartbeating:
            Self.reactWithEyes(message)
            pendingMessages.append(.discord(message: message, channelId: channelId, authorId: authorId))
        }
    }

    private func handleHeartbeat() {
        guard case .idle = state else { return }
        let task = Task { [heartbeatEngine, heartbeatSendAlert, queue] in
            let result = await heartbeatEngine.tick()
            switch result {
            case .skip, .noSnapshot:
                break
            case let .alert(text):
                await heartbeatSendAlert(text)
            case let .acted(text):
                if !text.isEmpty { await heartbeatSendAlert(text) }
            case let .cacheFailure(diagnostic):
                await heartbeatSendAlert("Cache integrity failure — heartbeats stopped.\n\n\(diagnostic)")
                await heartbeatScheduler.stopHeartbeats()
                log("[heartbeat] Stopped due to cache failure. Use `aozora heartbeat start` to resume.")
            }
            await queue.enqueue(.turnCompleted(.silent(channelId: "")))
        }
        state = .heartbeating(task: task)
    }

    private func handleTurnCompleted(_ completion: TurnCompletion) async {
        switch completion {
        case let .completed(channelId, response):
            print("[←] \(response.prefix(80))")
            await heartbeatEngine.onRealTurnComplete()
            await ipc.broadcast(.message(IPCChatMessage(
                role: "assistant", content: response, channel: nil,
                author: nil, timestamp: Date().timeIntervalSince1970,
            )))
            await AozoraDaemon.sendDiscordMessage(channelId: channelId, content: response)

        case .silent:
            break

        case let .failed(channelId, error):
            print("[!] Turn error: \(error)")
            await AozoraDaemon.sendDiscordMessage(channelId: channelId, content: "⚠️ \(error)")

        case let .cancelled(channelId, reason):
            print("[🛑] Turn cancelled: \(reason)")
            await AozoraDaemon.sendDiscordMessage(channelId: channelId, content: "🛑 \(reason)")

        case let .continuation(channelId, summary, depth):
            print("[continuation] Depth \(depth), summary: \(summary.prefix(80))")

            // Send summary to Discord as progress (not final response)
            await AozoraDaemon.sendDiscordMessage(channelId: channelId, content: summary)
            await ipc.broadcast(.message(IPCChatMessage(
                role: "assistant", content: summary, channel: nil,
                author: nil, timestamp: Date().timeIntervalSince1970,
            )))

            // Check for stop words before continuing
            if consumeStopWord() != nil {
                print("[continuation] Cancelled by stop word")
                state = .idle
                drainPending()
                return
            }

            // Check depth limit
            let nextDepth = depth + 1
            if nextDepth >= CIMSDefaults.maxContinuationDepth {
                print("[continuation] Depth limit reached (\(nextDepth))")
                state = .idle
                drainPending()
                return
            }

            // Start continuation turn
            let continuationText = """
            [Auto-continuation] Your previous turn hit the tool limit. Here is your handoff summary:
            
            \(summary)
            
            Continue your work. You have a fresh tool budget.
            """
            let message = InboundMessage(
                text: continuationText,
                parts: [MessagePart(
                    kind: .text, ordinal: 0,
                    content: continuationText,
                    metadata: "{\"discord_channel_id\":\"\(channelId)\",\"discord_author_id\":\"system\"}",
                )],
                metadata: nil,
            )
            startTurn(message: message, channelId: channelId, authorId: "system", continuationDepth: nextDepth)
            return
        }

        state = .idle
        drainPending()
    }

    private func handleIPCMessage(_ context: IPCInboundContext) async {
        print("[→ IPC] \(context.text.prefix(80))")
        await heartbeatScheduler.recordActivity()
        await heartbeatEngine.recordUserActivity()

        switch state {
        case .idle:
            startIPCTurn(context: context)
        case .processing, .heartbeating:
            pendingMessages.append(.ipc(context: context))
        }
    }

    // MARK: - Turn Lifecycle

    private func startTurn(message: InboundMessage, channelId: String, authorId: String, continuationDepth: Int = 0) {
        lastActiveChannelId = channelId
        let task = TurnRunner.run(
            message: message,
            channelId: channelId,
            authorId: authorId,
            continuationDepth: continuationDepth,
            gateway: gateway,
            ipc: ipc,
            eventQueue: queue,
            eventLoop: self,
        )
        state = .processing(task: task, channelId: channelId)
    }

    /// Start an IPC turn in a detached Task.
    private func startIPCTurn(context: IPCInboundContext) {
        let task = TurnRunner.runIPC(
            context: context,
            gateway: gateway,
            ipc: ipc,
            eventQueue: queue,
            eventLoop: self,
        )
        state = .processing(task: task, channelId: "ipc")
    }

    /// Inject a background result into the agent's conversation.
    ///
    /// If idle, starts a new turn with the result so the agent can react immediately.
    /// If busy or heartbeating, queues it as a pending Discord message for processing
    /// after the current turn completes.
    ///
    /// Results with an empty channel ID are dropped — they have nowhere to be routed.
    private func handleBackgroundResult(_ text: String, channelId: String) {
        guard !channelId.isEmpty else {
            print("[event] Background result has no channel ID, dropping: \(text.prefix(80))")
            return
        }
        let message = InboundMessage(
            text: text,
            parts: [MessagePart(
                kind: .text, ordinal: 0,
                content: text,
                metadata: "{\"discord_channel_id\":\"\(channelId)\",\"discord_author_id\":\"system\"}",
            )],
            metadata: nil,
        )

        switch state {
        case .idle:
            startTurn(message: message, channelId: channelId, authorId: "system")
        case .processing, .heartbeating:
            pendingMessages.append(.discord(message: message, channelId: channelId, authorId: "system"))
        }
    }

    /// Handle a fired cron job by starting a system-initiated turn.
    ///
    /// The job's prompt is wrapped with metadata identifying it as cron-originated.
    /// If the event loop is busy, the job is queued as a pending message.
    private func handleCronJob(_ job: FiredJob) {
        print("[cron] Job fired: \(job.name) — \(job.prompt.prefix(60))")
        let text = """
        [Scheduled job "\(job.name)" fired]
        
        \(job.prompt)
        """
        handleBackgroundResult(text, channelId: lastActiveChannelId)
    }

    /// Process the next pending message, if any.
    ///
    /// Only one message is drained per call — subsequent messages wait for the next
    /// `.turnCompleted` event. This allows stop words between pending messages to be caught.
    private func drainPending() {
        guard let item = pendingMessages.popFirst() else { return }
        switch item {
        case let .discord(message, channelId, authorId):
            startTurn(message: message, channelId: channelId, authorId: authorId)
        case let .ipc(context):
            startIPCTurn(context: context)
        }
    }

    // MARK: - InterjectionSource Support

    /// Check for a stop-word message at the front of the pending queue.
    ///
    /// Only inspects Discord messages — IPC messages are never treated as stop words.
    /// If the first pending item is a Discord message containing a stop word, removes
    /// and returns it. Otherwise returns nil without modifying the queue.
    func consumeStopWord() -> InboundMessage? {
        guard case let .discord(message, _, _) = pendingMessages.first else { return nil }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if Self.stopWords.contains(text) {
            pendingMessages.removeFirst()
            return message
        }
        return nil
    }

    /// Consume all pending Discord messages for injection as mid-turn context.
    ///
    /// Removes Discord messages from the pending queue and returns them.
    /// IPC messages are left in place — they have different routing semantics.
    /// The coordinator injects the returned messages between tool iterations as
    /// additive context blocks, allowing users to steer an active tool chain.
    func consumePending() -> [InboundMessage] {
        var consumed: [InboundMessage] = []
        var remaining: Deque<PendingItem> = []
        for item in pendingMessages {
            if case let .discord(message, _, _) = item {
                consumed.append(message)
            } else {
                remaining.append(item)
            }
        }
        pendingMessages = remaining
        return consumed
    }

    // MARK: - Status

    /// Current daemon status for diagnostic commands (CLI, Discord slash).
    func currentStatus() async -> String {
        var lines: [String] = []

        switch state {
        case .idle:
            lines.append("**State**: idle")
        case let .processing(_, channelId):
            lines.append("**State**: processing turn")
            lines.append("**Channel**: \(channelId)")
        case .heartbeating:
            lines.append("**State**: heartbeating")
        }

        if pendingMessages.count > 0 {
            lines.append("**Pending messages**: \(pendingMessages.count)")
        }

        // Show live tool output if a tool is running
        if let snapshot = await ActiveToolOutput.shared.snapshot() {
            lines.append("")
            lines.append(snapshot.formatted())
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func extractMetadata(_ message: InboundMessage) -> (channelId: String, messageId: String?, authorId: String)? {
        guard let metadata = message.parts.first?.metadata,
              let metaData = metadata.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
              let channelId = meta["discord_channel_id"]
        else { return nil }
        return (channelId, meta["discord_message_id"], meta["discord_author_id"] ?? "unknown")
    }

    private nonisolated static func reactWithEyes(_ message: InboundMessage) {
        guard let metadata = message.parts.first?.metadata,
              let metaData = metadata.data(using: .utf8),
              let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: String],
              let channelId = meta["discord_channel_id"],
              let messageId = meta["discord_message_id"]
        else { return }
        Task { await AozoraDaemon.addReaction(channelId: channelId, messageId: messageId, emoji: "👀") }
    }
}

// MARK: - InterjectionProxy

/// Bridges the EventLoop's pending message queue to the coordinator's ``InterjectionSource``.
///
/// Created by ``TurnRunner`` at the start of each Discord turn and passed to the coordinator
/// via ``CIMSCoordinator/setInterjectionSource(_:)``. The coordinator's tool loop calls
/// ``consumeStopWord()`` and ``consumePending()`` between tool iterations, crossing actor
/// boundaries to inspect the EventLoop's pending queue.
///
/// Actor references are `Sendable` in Swift 6, so this class is naturally `Sendable`
/// without resorting to `@unchecked`.
final class InterjectionProxy: InterjectionSource, Sendable {
    private let eventLoop: EventLoop

    /// Creates a proxy that forwards interjection queries to the given event loop.
    ///
    /// - Parameter eventLoop: The running ``EventLoop`` whose pending queue is inspected.
    init(eventLoop: EventLoop) {
        self.eventLoop = eventLoop
    }

    /// Forwards to ``EventLoop/consumeStopWord()``, crossing the actor boundary.
    func consumeStopWord() async -> InboundMessage? {
        await eventLoop.consumeStopWord()
    }

    /// Forwards to ``EventLoop/consumePending()``, crossing the actor boundary.
    func consumePending() async -> [InboundMessage] {
        await eventLoop.consumePending()
    }
}
