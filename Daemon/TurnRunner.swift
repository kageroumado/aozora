import Foundation

/// Executes turns in detached Tasks, posting results back to the event queue.
///
/// Each turn runs in `Task.detached` so it never blocks the event loop.
/// The observer handles Discord I/O (typing, tool messages, IPC) during execution.
/// When the turn completes (or fails/cancels), a `.turnCompleted` event is posted.
enum TurnRunner {
    /// Run a user turn in a detached Task.
    ///
    /// Wires an ``InterjectionProxy`` so the coordinator's tool loop can inspect the
    /// EventLoop's pending queue between iterations — injecting user messages as additive
    /// context and cancelling on stop words.
    ///
    /// - Parameters:
    ///   - message: The triggering inbound message.
    ///   - channelId: Discord channel to post responses to.
    ///   - authorId: Discord user ID of the message author.
    ///   - gateway: The CIMS gateway that runs the turn.
    ///   - ipc: IPC broadcaster for streaming events.
    ///   - eventQueue: Queue to post completion events to.
    ///   - eventLoop: The running event loop — used to create the ``InterjectionProxy``.
    static func run(
        message: InboundMessage,
        channelId: String,
        authorId: String,
        continuationDepth: Int = 0,
        gateway: CIMSGateway,
        ipc: DaemonIPC,
        eventQueue: AsyncQueue<DaemonEvent>,
        eventLoop: EventLoop,
    ) -> Task<Void, Never> {
        Task.detached {
            let request = TurnRequest(
                turnID: String(Int64(Date().timeIntervalSince1970 * 1_000)),
                sessionKey: "discord:\(channelId)",
                userKey: authorId,
                message: message,
                receivedAt: Date(),
                continuationDepth: continuationDepth,
            )

            let typingTask = Task {
                while !Task.isCancelled {
                    await AozoraDaemon.triggerTyping(channelId: channelId)
                    try? await Task.sleep(for: .seconds(8))
                }
            }
            defer { typingTask.cancel() }

            let proxy = InterjectionProxy(eventLoop: eventLoop)
            await gateway.coordinator.setInterjectionSource(proxy)

            let observer = DiscordTurnObserver(channelId: channelId, ipc: ipc)

            do {
                try await gateway.runTurn(request, observer: observer)
                await ipc.broadcast(.streamEnd)

                let response = observer.finalResponse
                if let depth = observer.continuationDepth {
                    await eventQueue.enqueue(.turnCompleted(
                        .continuation(channelId: channelId, summary: response, depth: depth),
                    ))
                } else if response.isEmpty {
                    await eventQueue.enqueue(.turnCompleted(.silent(channelId: channelId)))
                } else {
                    await eventQueue.enqueue(.turnCompleted(
                        .completed(channelId: channelId, response: response),
                    ))
                }
            } catch is CancellationError {
                await eventQueue.enqueue(.turnCompleted(
                    .cancelled(channelId: channelId, reason: "Cancelled"),
                ))
            } catch {
                // Task.cancel() often propagates as a wrapped error (e.g.,
                // modelError("Network error: cancelled")) rather than
                // CancellationError. Check Task.isCancelled to classify correctly.
                if Task.isCancelled {
                    await eventQueue.enqueue(.turnCompleted(
                        .cancelled(channelId: channelId, reason: "Cancelled"),
                    ))
                } else {
                    await eventQueue.enqueue(.turnCompleted(
                        .failed(channelId: channelId, error: "\(error)"),
                    ))
                }
            }
        }
    }

    /// Run an IPC-originated turn in a detached Task.
    ///
    /// Handles the full IPC turn lifecycle: creates the request, runs it through the gateway,
    /// broadcasts the response to IPC clients, and optionally relays to Discord DMs.
    /// Posts `.turnCompleted` when done so the event loop can process pending items.
    ///
    /// Wires an ``InterjectionProxy`` so the coordinator can inspect the EventLoop's pending
    /// queue between tool iterations — same mechanism as Discord turns.
    ///
    /// - Parameters:
    ///   - context: IPC inbound context carrying the message and session metadata.
    ///   - gateway: The CIMS gateway that runs the turn.
    ///   - ipc: IPC broadcaster for streaming events.
    ///   - eventQueue: Queue to post completion events to.
    ///   - eventLoop: The running event loop — used to create the ``InterjectionProxy``.
    static func runIPC(
        context: IPCInboundContext,
        gateway: CIMSGateway,
        ipc: DaemonIPC,
        eventQueue: AsyncQueue<DaemonEvent>,
        eventLoop: EventLoop,
    ) -> Task<Void, Never> {
        Task.detached {
            let inbound = InboundMessage(
                text: context.text,
                parts: [MessagePart(kind: .text, ordinal: 0, content: context.text, metadata: nil)],
                metadata: nil,
                images: context.images,
            )

            let request = TurnRequest(
                turnID: UUID().uuidString,
                sessionKey: context.sessionKey,
                userKey: "ipc",
                message: inbound,
                receivedAt: .now,
                streaming: true,
            )

            let proxy = InterjectionProxy(eventLoop: eventLoop)
            await gateway.coordinator.setInterjectionSource(proxy)

            let dmChannelId = await ipc.discordDMChannelId
            let observer = IPCTurnObserver(ipc: ipc, dmChannelId: dmChannelId)

            do {
                try await gateway.runTurn(request, observer: observer)
                await ipc.broadcast(.streamEnd)

                if !observer.responseText.isEmpty {
                    await ipc.broadcast(.message(IPCChatMessage(
                        role: "assistant",
                        content: observer.responseText,
                        channel: nil,
                        author: nil,
                        timestamp: Date().timeIntervalSince1970,
                    )))

                    if let dmId = dmChannelId {
                        await AozoraDaemon.sendDiscordMessage(channelId: dmId, content: observer.responseText)
                    }
                }

                if let depth = observer.continuationDepth, let dmId = dmChannelId {
                    await eventQueue.enqueue(.turnCompleted(
                        .continuation(channelId: dmId, summary: observer.responseText, depth: depth),
                    ))
                } else {
                    await eventQueue.enqueue(.turnCompleted(.silent(channelId: "")))
                }
            } catch is CancellationError {
                await eventQueue.enqueue(.turnCompleted(.cancelled(channelId: "", reason: "IPC turn cancelled")))
            } catch {
                if Task.isCancelled {
                    await eventQueue.enqueue(.turnCompleted(.cancelled(channelId: "", reason: "IPC turn cancelled")))
                } else {
                    print("[IPC] Send message failed: \(error)")
                    await eventQueue.enqueue(.turnCompleted(.failed(channelId: "", error: "\(error)")))
                }
            }
        }
    }
}

// MARK: - Discord Turn Observer

/// TurnObserver that handles Discord I/O during a user turn.
final class DiscordTurnObserver: TurnObserver, @unchecked Sendable {
    let channelId: String
    let ipc: DaemonIPC
    private var intermediateText = ""
    private(set) var responseText = ""
    private(set) var continuationDepth: Int?
    private var toolLines: [String] = []
    private var toolMessageId: String?

    init(channelId: String, ipc: DaemonIPC) {
        self.channelId = channelId
        self.ipc = ipc
    }

    func handleEvent(_ event: TurnEvent) async {
        switch event {
        case let .responseCompleted(text):
            responseText = text

        case let .responseDelta(text):
            intermediateText += text
            await ipc.broadcast(.streamDelta(text: text))

        case let .delta(delta):
            if let text = delta.text {
                intermediateText += text
                await ipc.broadcast(.streamDelta(text: text))
            }
            if let toolCall = delta.toolCall {
                await ipc.broadcast(.toolCall(IPCToolCall(
                    name: toolCall.name,
                    arguments: toolCall.arguments,
                    id: toolCall.id,
                )))
                let argsPreview = Self.formatToolPreview(toolCall)
                let trimmed = intermediateText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    toolLines.append(trimmed)
                    intermediateText = ""
                }
                toolLines.append("🔧 `\(toolCall.name)`\(argsPreview)")
                await updateToolMessage()
            }

        case let .toolResult(result):
            await ipc.broadcast(.toolResult(IPCToolResult(
                id: result.toolUseId, output: result.content, isError: result.isError,
            )))

        case let .toolBackgrounded(info):
            toolLines.append("⏳ `\(info.toolName)` moved to background")
            await updateToolMessage()

        case let .toolBackgroundCompleted(_, content, elapsed):
            let secs = Int(elapsed.components.seconds)
            toolLines.append("✅ Background (\(secs)s): \(content.prefix(60))")
            await updateToolMessage()

        case let .toolBackgroundCancelled(_, reason):
            toolLines.append("🛑 \(reason)")
            await updateToolMessage()

        case let .workerDispatched(runId):
            await ipc.broadcast(.toolCall(IPCToolCall(
                name: "dispatch_worker", arguments: "{}", id: runId,
            )))

        case let .workerCompleted(runId, _):
            await ipc.broadcast(.toolResult(IPCToolResult(
                id: runId, output: "Worker completed", isError: false,
            )))

        case let .continuationNeeded(depth):
            continuationDepth = depth

        case let .forkDispatched(forkId):
            toolLines.append("🔀 Fork dispatched (id: \(forkId))")
            await updateToolMessage()

        case .acknowledged, .thinking, .hold, .error:
            break
        }
    }

    /// Final response text (falls back to accumulated intermediate text).
    var finalResponse: String {
        let text = responseText.isEmpty ? intermediateText : responseText
        return Self.stripTimestamp(text)
    }

    private func updateToolMessage() async {
        let text = toolLines.joined(separator: "\n")
        if let existingId = toolMessageId {
            await AozoraDaemon.editDiscordMessage(channelId: channelId, messageId: existingId, content: text)
        } else {
            toolMessageId = await AozoraDaemon.sendDiscordMessageReturningId(channelId: channelId, content: text)
        }
    }

    private static func formatToolPreview(_ toolCall: ToolCall) -> String {
        guard let data = toolCall.arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        if let cmd = json["command"] as? String { return "(`\(cmd.prefix(60))`)" }
        if let path = json["file_path"] as? String { return "(`\(path.prefix(60))`)" }
        if let pattern = json["pattern"] as? String { return "(`\(pattern.prefix(40))`)" }
        return ""
    }

    private static func stripTimestamp(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(
            of: #"^\s*\[[A-Z][a-z]+ \d{4}-\d{2}-\d{2} \d{2}:\d{2} [A-Z/+\d]+\]\s*"#,
            with: "",
            options: .regularExpression,
        )
        return cleaned.isEmpty ? text : cleaned
    }
}

// MARK: - Heartbeat Turn Observer

/// TurnObserver for heartbeat turns — collects response and manages tool activity in DMs.
final class HeartbeatTurnObserver: TurnObserver, @unchecked Sendable {
    private let sendMessageReturningId: @Sendable (String) async -> String?
    private let editMessage: @Sendable (String, String) async -> Void
    private var intermediateText = ""
    private(set) var responseText = ""
    private var toolLines: [String] = []
    private var toolMessageId: String?

    init(
        sendMessageReturningId: @escaping @Sendable (String) async -> String?,
        editMessage: @escaping @Sendable (String, String) async -> Void,
    ) {
        self.sendMessageReturningId = sendMessageReturningId
        self.editMessage = editMessage
    }

    func handleEvent(_ event: TurnEvent) async {
        switch event {
        case let .responseCompleted(text):
            responseText = text
        case let .responseDelta(text):
            intermediateText += text
        case let .delta(delta):
            if let text = delta.text {
                intermediateText += text
            }
            if let toolCall = delta.toolCall {
                let trimmed = intermediateText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    toolLines.append(trimmed)
                    intermediateText = ""
                }
                toolLines.append("🔧 `\(toolCall.name)`")
                let toolText = toolLines.joined(separator: "\n")
                if let existingId = toolMessageId {
                    await editMessage(existingId, toolText)
                } else {
                    toolMessageId = await sendMessageReturningId(toolText)
                }
            }
        default:
            break
        }

        if responseText.isEmpty {
            responseText = intermediateText
        }
    }
}
