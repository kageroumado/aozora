import AozoraCore
import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "app.aozora", category: "chat")

/// Manages chat conversations, message streaming, and turn execution.
///
/// Operates in two modes:
/// - **In-process**: Talks directly to a ``CIMSGateway`` (existing behavior).
/// - **IPC**: Receives events from ``IPCClient`` connected to the daemon.
///
/// Mode is determined at initialization and cannot change at runtime.
/// Messages are view-layer only — CIMS ``MemoryStore`` handles persistence
/// internally during the turn pipeline.
///
/// -> Spec: Chat UI Design Chat System
@Observable
final class ChatManager {
    /// The data source backing this manager.
    enum DataSource {
        /// Direct in-process access to the CIMS gateway.
        case inProcess(CIMSGateway)
        /// Remote access via IPC to a running daemon.
        case ipc(IPCClient)
    }

    /// The active data source.
    private let dataSource: DataSource

    /// Current session key used for turn requests.
    private(set) var sessionKey: SessionKey = "default"

    /// User key for this session.
    private(set) var userKey: UserKey = "default"

    /// All messages in the current conversation.
    var messages: [ChatMessage] = []

    /// Whether a response is currently streaming.
    var isStreaming = false

    /// Callback for inspector data received via IPC (set by InspectorManager).
    @ObservationIgnored var onInspectorData: ((IPCInspectorData) -> Void)?

    /// Whether older messages are being loaded.
    var isLoadingHistory = false

    /// Whether there are more historical messages to load.
    var hasMoreHistory = false

    /// ID of the oldest loaded message (for pagination cursor).
    @ObservationIgnored private var oldestMessageId: Int64?

    /// Active stream task, if any.
    @ObservationIgnored private var currentStreamTask: Task<Void, Never>?

    /// Task listening for IPC messages (IPC mode only).
    @ObservationIgnored private var ipcListenerTask: Task<Void, Never>?

    /// Texts of messages recently sent via IPC, used to deduplicate echoed user messages.
    @ObservationIgnored private var recentlySentTexts: Set<String> = []

    /// Creates a chat manager backed by the given gateway (in-process mode).
    ///
    /// - Parameter gateway: The initialized CIMS gateway.
    init(gateway: CIMSGateway) {
        self.dataSource = .inProcess(gateway)
    }

    /// Creates a chat manager backed by an IPC client (daemon mode).
    ///
    /// Starts listening for incoming IPC messages immediately.
    ///
    /// - Parameter ipcClient: The connected IPC client.
    init(ipcClient: IPCClient) {
        self.dataSource = .ipc(ipcClient)
        startIPCListener(ipcClient)

        ipcClient.send(.getHistory(sessionKey: nil, limit: 50, beforeId: nil))
    }

    // MARK: - Sending

    /// Send a user message and start streaming the assistant response.
    ///
    /// In **in-process mode**: creates a ``TurnRequest``, runs it through the gateway,
    /// and processes the event stream.
    ///
    /// In **IPC mode**: sends the message to the daemon via ``IPCClient``. The response
    /// arrives asynchronously via the IPC listener.
    ///
    /// - Parameters:
    ///   - text: The user's message text.
    ///   - images: Optional image attachments as `(data, mediaType)` pairs.
    func send(text: String, images: [(Data, String)] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !images.isEmpty else { return }

        switch dataSource {
        case let .inProcess(gateway):
            sendViaGateway(text: trimmed, gateway: gateway, images: images)
        case let .ipc(client):
            sendViaIPC(text: trimmed, client: client, images: images)
        }
    }

    /// Cancel the current streaming turn.
    ///
    /// Cancels the active stream task and marks the last assistant message
    /// as complete if it was still streaming.
    func cancel() {
        currentStreamTask?.cancel()
        currentStreamTask = nil
        isStreaming = false

        if let last = messages.last, last.role == .assistant {
            if case .streaming = last.status {
                last.status = .complete
            }
        }
    }

    // MARK: - History

    /// Load older messages (called when user scrolls to top).
    ///
    /// Sends a paginated history request using the oldest loaded message ID
    /// as the cursor. No-op if already loading or no more history exists.
    func loadMoreHistory() {
        guard !isLoadingHistory, hasMoreHistory else { return }
        guard case let .ipc(client) = dataSource else { return }

        isLoadingHistory = true
        client.send(.getHistory(sessionKey: nil, limit: 50, beforeId: oldestMessageId))
    }

    // MARK: - In-Process Mode

    /// Send a message via the in-process gateway.
    private func sendViaGateway(text: String, gateway: CIMSGateway, images: [(Data, String)] = []) {
        let userMessage = ChatMessage(role: .user, text: text, status: .complete)
        for (data, mediaType) in images {
            userMessage.appendImage(data: data, mediaType: mediaType)
        }
        messages.append(userMessage)

        let inbound = InboundMessage(
            text: text,
            parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
            metadata: nil,
        )

        let turnID = UUID().uuidString
        let request = TurnRequest(
            turnID: turnID,
            sessionKey: sessionKey,
            userKey: userKey,
            message: inbound,
            receivedAt: .now,
            streaming: true,
        )

        isStreaming = true

        currentStreamTask?.cancel()
        currentStreamTask = Task(name: "ChatManager.send") {
            let (stream, continuation) = AsyncThrowingStream<TurnEvent, any Error>.makeStream()
            let observer = StreamBridgeObserver(continuation: continuation)

            Task.detached {
                do {
                    try await gateway.runTurn(request, observer: observer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            await processStream(stream)
        }
    }

    // MARK: - IPC Mode

    /// Send a message via the IPC client to the daemon.
    private func sendViaIPC(text: String, client: IPCClient, images: [(Data, String)] = []) {
        let userMessage = ChatMessage(role: .user, text: text, status: .complete)
        for (data, mediaType) in images {
            userMessage.appendImage(data: data, mediaType: mediaType)
        }
        messages.append(userMessage)
        recentlySentTexts.insert(text)
        isStreaming = true

        // IPCImageData is defined in AozoraCore by the other agent.
        // Build the IPC image array if the type is available.
        let ipcImages: [IPCImageData]? = images.isEmpty ? nil : images.map {
            IPCImageData(data: $0.0, mediaType: $0.1)
        }
        client.send(.sendMessage(sessionKey: sessionKey, text: text, images: ipcImages))
    }

    /// Start listening for incoming IPC messages from the daemon.
    ///
    /// Translates ``IPCOutbound`` messages into ``ChatMessage`` mutations,
    /// mirroring the event processing done for in-process ``TurnEvent``s.
    ///
    /// - Parameter client: The connected IPC client.
    private func startIPCListener(_ client: IPCClient) {
        guard let stream = client.incomingMessages else { return }

        ipcListenerTask = Task(name: "ChatManager.ipcListener") { [weak self] in
            var currentAssistantMessage: ChatMessage?

            for await message in stream {
                guard let self else { break }

                switch message {
                case let .message(chat):
                    let role: ChatMessage.MessageRole = chat.role == "user" ? .user : .assistant

                    if role == .assistant {
                        if let existing = currentAssistantMessage {
                            // Blocks were already built from stream events (deltas, tool calls).
                            // Just mark complete — don't replace blocks with the flat text.
                            existing.status = .complete
                        } else {
                            // No streaming preceded this — create a fresh message (e.g., from history)
                            let msg = ChatMessage(role: role, text: chat.content, status: .complete)
                            messages.append(msg)
                        }
                        currentAssistantMessage = nil
                        isStreaming = false
                    } else {
                        if recentlySentTexts.remove(chat.content) != nil {
                            continue
                        }
                        let msg = ChatMessage(role: role, text: chat.content, status: .complete)
                        messages.append(msg)
                        currentAssistantMessage = nil
                    }

                case let .streamDelta(text):
                    if let msg = currentAssistantMessage {
                        msg.appendText(text)
                        msg.status = .streaming
                    } else {
                        let msg = ChatMessage(role: .assistant, text: "", status: .streaming)
                        msg.appendText(text)
                        currentAssistantMessage = msg
                        messages.append(msg)
                        isStreaming = true
                    }

                case .streamEnd:
                    if let msg = currentAssistantMessage {
                        msg.status = .complete
                    }
                    isStreaming = false

                case let .toolCall(tool):
                    if currentAssistantMessage == nil {
                        let msg = ChatMessage(role: .assistant, text: "", status: .streaming)
                        currentAssistantMessage = msg
                        messages.append(msg)
                        isStreaming = true
                    }
                    if let msg = currentAssistantMessage {
                        let toolInfo = ToolCallInfo(
                            id: tool.id,
                            name: tool.name,
                            arguments: tool.arguments,
                        )
                        msg.appendToolCall(toolInfo)
                    }

                case let .toolResult(result):
                    if let msg = currentAssistantMessage,
                       let tool = msg.toolCalls.last(where: { $0.id == result.id }) {
                        tool.status = result.isError ? .error : .success
                        tool.isError = result.isError
                        tool.resultContent = result.output
                    }

                case let .history(historyMessages, hasMore):
                    hasMoreHistory = hasMore
                    isLoadingHistory = false

                    if !historyMessages.isEmpty {
                        if let first = historyMessages.first {
                            if oldestMessageId == nil || first.id < oldestMessageId! {
                                oldestMessageId = first.id
                            }
                        }

                        let chatMessages = historyMessages.compactMap { msg -> ChatMessage? in
                            if msg.role == "tool" { return nil }

                            let role: ChatMessage.MessageRole = msg.role == "user" ? .user : .assistant

                            let chatMsg = ChatMessage(
                                role: role,
                                text: msg.content,
                                timestamp: Date(timeIntervalSince1970: msg.timestamp),
                                status: .complete,
                            )

                            if let toolCalls = msg.toolCalls {
                                for tc in toolCalls {
                                    let toolInfo = ToolCallInfo(
                                        id: tc.id,
                                        name: tc.name,
                                        status: .success,
                                        arguments: tc.arguments,
                                    )
                                    chatMsg.appendToolCall(toolInfo)
                                }
                            }

                            if let toolResults = msg.toolResults {
                                for tr in toolResults {
                                    if let tool = chatMsg.toolCalls.first(where: { $0.id == tr.toolUseId }) {
                                        tool.status = tr.isError ? .error : .success
                                        tool.isError = tr.isError
                                        tool.resultContent = tr.content
                                    }
                                }
                            }

                            return chatMsg
                        }
                        messages.insert(contentsOf: chatMessages, at: 0)
                    }

                case let .inspector(data):
                    onInspectorData?(data)

                case .status:
                    break
                }
            }
        }
    }

    // MARK: - Stream Processing (In-Process)

    /// Process a stream of turn events, updating the assistant message in real time.
    ///
    /// Maps each ``TurnEvent`` to the appropriate ``ChatMessage`` mutation:
    /// - `acknowledged` -> create placeholder assistant message
    /// - `delta` -> append text, track tool calls
    /// - `responseDelta` -> append text (post-tool response text creates new block)
    /// - `responseCompleted` -> finalize message status
    /// - `hold` -> show hold indicator
    /// - `workerDispatched` / `workerCompleted` -> track tool-like worker activity
    /// - `toolBackgrounded` / `toolBackgroundCompleted` / `toolBackgroundCancelled` -> background tool status
    /// - `error` -> mark message as failed
    ///
    /// - Parameter stream: The bridged stream of turn events from ``StreamBridgeObserver``.
    private func processStream(_ stream: AsyncThrowingStream<TurnEvent, any Error>) async {
        var assistantMessage: ChatMessage?

        do {
            for try await event in stream {
                switch event {
                case .acknowledged:
                    let msg = ChatMessage(role: .assistant, text: "", status: .sending)
                    assistantMessage = msg
                    messages.append(msg)

                case .thinking:
                    break

                case let .delta(modelDelta):
                    guard let msg = assistantMessage else { break }

                    if let text = modelDelta.text {
                        msg.appendText(text)
                    }
                    msg.status = .streaming

                    if let toolCall = modelDelta.toolCall {
                        let toolInfo = ToolCallInfo(
                            id: toolCall.id,
                            name: toolCall.name,
                            arguments: toolCall.arguments,
                        )
                        msg.appendToolCall(toolInfo)
                    }

                case let .responseDelta(text):
                    guard let msg = assistantMessage else {
                        let newMsg = ChatMessage(role: .assistant, text: text, status: .streaming)
                        assistantMessage = newMsg
                        messages.append(newMsg)
                        break
                    }
                    msg.appendText(text)
                    msg.status = .streaming

                case let .hold(message):
                    assistantMessage?.holdMessage = message

                case let .workerDispatched(runId):
                    guard let msg = assistantMessage else { break }
                    let toolInfo = ToolCallInfo(
                        name: "worker_\(runId)",
                        displayName: "Worker",
                    )
                    msg.appendToolCall(toolInfo)

                case let .workerCompleted(runId, summary):
                    guard let msg = assistantMessage else { break }
                    if let tool = msg.toolCalls.last(where: { $0.name == "worker_\(runId)" }) {
                        tool.status = .success
                        tool.resultContent = summary.narrative
                    }

                case .responseCompleted:
                    if let msg = assistantMessage {
                        msg.status = .complete
                        msg.holdMessage = nil
                    }

                case let .toolResult(result):
                    if let msg = assistantMessage,
                       let tool = msg.toolCalls.last(where: { $0.id == result.toolUseId }) {
                        tool.status = result.isError ? .error : .success
                        tool.isError = result.isError
                        tool.resultContent = result.content
                    }

                case let .toolBackgrounded(info):
                    guard let msg = assistantMessage else { break }
                    if let tool = msg.toolCalls.last(where: { $0.id == info.toolCallId }) {
                        tool.status = .backgrounded
                    }

                case let .toolBackgroundCompleted(toolCallId, content, _):
                    guard let msg = assistantMessage else { break }
                    if let tool = msg.toolCalls.last(where: { $0.id == toolCallId }) {
                        tool.status = .success
                        tool.resultContent = content
                    }

                case let .toolBackgroundCancelled(toolCallId, reason):
                    guard let msg = assistantMessage else { break }
                    if let tool = msg.toolCalls.last(where: { $0.id == toolCallId }) {
                        tool.status = .error
                        tool.resultContent = reason
                    }

                case let .error(cimsError):
                    let description = cimsError.localizedDescription
                    if let msg = assistantMessage {
                        msg.status = .error(description)
                    } else {
                        let errorMsg = ChatMessage(
                            role: .assistant,
                            text: "Error: \(description)",
                            status: .error(description),
                        )
                        messages.append(errorMsg)
                    }

                case .continuationNeeded, .forkDispatched:
                    break
                }
            }
        } catch {
            logger.error("Stream error: \(error.localizedDescription)")
            if let msg = assistantMessage {
                msg.status = .error(error.localizedDescription)
            } else {
                let errorMsg = ChatMessage(
                    role: .assistant,
                    text: "Turn failed: \(error.localizedDescription)",
                    status: .error(error.localizedDescription),
                )
                messages.append(errorMsg)
            }
        }

        if let msg = assistantMessage, case .streaming = msg.status {
            msg.status = .complete
        }

        isStreaming = false
    }

    // MARK: - Utilities

    /// Format an internal tool name for display.
    ///
    /// Replaces underscores with spaces and capitalizes each word.
    ///
    /// - Parameter name: The internal tool name (e.g., `dispatch_worker`).
    /// - Returns: A human-readable name (e.g., "Dispatch Worker").
    private static func formatToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

// MARK: - Stream Bridge Observer

/// Bridges the ``TurnObserver`` protocol to ``AsyncThrowingStream`` for UI consumption.
///
/// The coordinator calls `handleEvent` which yields events to the stream continuation.
/// The ``ChatManager`` iterates the stream on the MainActor for real-time UI updates.
private final class StreamBridgeObserver: TurnObserver, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<TurnEvent, any Error>.Continuation

    init(continuation: AsyncThrowingStream<TurnEvent, any Error>.Continuation) {
        self.continuation = continuation
    }

    func handleEvent(_ event: TurnEvent) async {
        continuation.yield(event)
    }
}
