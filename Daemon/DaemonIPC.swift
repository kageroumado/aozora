import Foundation
import GRDB
import Network

/// Transport-agnostic IPC server for app↔daemon communication.
///
/// Manages client connections from both local Unix domain sockets and remote
/// WebSocket connections. Both transports produce ``IPCClientHandle`` instances
/// that share the same request dispatch and broadcast infrastructure.
///
/// **Local** clients connect via `~/.aozora/daemon.sock` (line-delimited JSON).
/// **Remote** clients connect via WebSocket on a configurable TCP port (default 19877).
actor DaemonIPC {
    /// Filesystem path for the Unix domain socket.
    private let socketPath: String

    /// TCP port for the WebSocket server.
    private let wsPort: UInt16

    /// The listening Unix socket file descriptor.
    private var serverFd: Int32 = -1

    /// Connected clients across all transports, keyed by opaque client ID.
    private var clients: [IPCClientID: any IPCClientHandle] = [:]

    /// Unix socket client state (read task lifecycle).
    private var unixReadTasks: [IPCClientID: Task<Void, Never>] = [:]

    /// The WebSocket server instance.
    private var wsServer: WebSocketServer?

    /// The CIMS gateway for handling client requests.
    private let gateway: CIMSGateway

    /// Discord DM channel ID for cross-platform message relay.
    private(set) var discordDMChannelId: String?

    /// The daemon's central event queue, set after creation.
    ///
    /// When set, ``handleSendMessage`` enqueues messages on the event loop instead
    /// of calling `gateway.runTurn()` directly. This ensures IPC messages respect
    /// the single-turn-at-a-time invariant.
    private var eventQueue: AsyncQueue<DaemonEvent>?

    /// Set the Discord DM channel ID for cross-platform relay.
    func setDiscordDMChannel(_ channelId: String?) {
        discordDMChannelId = channelId
    }

    /// Wire the event queue so IPC messages route through the event loop.
    ///
    /// Must be called before IPC clients send messages. Without this, messages
    /// are processed directly (bypassing the event loop's turn serialization).
    func setEventQueue(_ queue: AsyncQueue<DaemonEvent>) {
        eventQueue = queue
    }

    /// Task running the Unix socket accept loop.
    private var acceptTask: Task<Void, Never>?

    /// Daemon start time for uptime calculation.
    private let startTime = Date()

    /// Creates a daemon IPC server.
    ///
    /// - Parameters:
    ///   - socketPath: Path for the Unix domain socket. Defaults to `~/.aozora/daemon.sock`.
    ///   - wsPort: TCP port for the WebSocket server. Defaults to `19877`.
    ///   - gateway: The CIMS gateway for handling client requests.
    init(
        socketPath: String = NSHomeDirectory() + "/.aozora/daemon.sock",
        wsPort: UInt16 = 19_877,
        gateway: CIMSGateway,
    ) {
        self.socketPath = socketPath
        self.wsPort = wsPort
        self.gateway = gateway
    }

    // MARK: - Lifecycle

    /// Start both Unix socket and WebSocket listeners.
    ///
    /// The Unix socket provides local same-machine IPC. The WebSocket server
    /// provides network-accessible IPC (e.g., via Tailscale).
    ///
    /// - Throws: ``IPCError`` if the Unix socket fails to bind.
    func start() throws {
        try startUnixSocket()
        startWebSocket()
    }

    /// Stop all listeners and disconnect all clients.
    func stop() {
        acceptTask?.cancel()
        acceptTask = nil

        for (id, _) in unixReadTasks {
            unixReadTasks[id]?.cancel()
            if let handle = clients[id] as? UnixSocketClientHandle {
                Darwin.close(handle.fd)
            }
        }
        unixReadTasks.removeAll()

        if serverFd >= 0 {
            Darwin.close(serverFd)
            serverFd = -1
        }
        unlink(socketPath)

        Task { await wsServer?.stop() }
        wsServer = nil

        clients.removeAll()
    }

    // MARK: - Client Management

    /// Register a client from any transport.
    func registerClient(_ handle: any IPCClientHandle) {
        clients[handle.id] = handle
    }

    /// Deregister a client by ID.
    func deregisterClient(_ id: IPCClientID) {
        clients.removeValue(forKey: id)
        if let task = unixReadTasks.removeValue(forKey: id) {
            task.cancel()
        }
    }

    // MARK: - Broadcasting

    /// Broadcast a message to all connected clients across all transports.
    ///
    /// - Parameter message: The outbound IPC message to broadcast.
    func broadcast(_ message: IPCOutbound) {
        var dead: [IPCClientID] = []
        for (id, handle) in clients {
            do {
                try handle.sendSync(message)
            } catch {
                dead.append(id)
            }
        }
        for id in dead {
            deregisterClient(id)
        }
    }

    /// Broadcast a message to all clients except the specified one.
    private func broadcastExcluding(_ message: IPCOutbound, excluding: IPCClientID) {
        for (id, handle) in clients where id != excluding {
            do {
                try handle.sendSync(message)
            } catch {
                deregisterClient(id)
            }
        }
    }

    /// Number of currently connected clients.
    var clientCount: Int {
        clients.count
    }

    // MARK: - Unix Socket Server

    /// Start the Unix domain socket listener.
    private func startUnixSocket() throws {
        unlink(socketPath)

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else { throw IPCError.socketCreation }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                UnsafeMutableRawPointer(pathPtr).copyMemory(
                    from: cstr,
                    byteCount: min(socketPath.utf8.count + 1, 104),
                )
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = String(cString: strerror(errno))
            Darwin.close(serverFd)
            serverFd = -1
            throw IPCError.bindFailed(err)
        }

        listen(serverFd, 5)

        let fd = serverFd
        acceptTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let clientFd = accept(fd, nil, nil)
                if clientFd < 0 { break }
                await self?.addUnixClient(clientFd)
            }
        }

        print("  ├─ IPC server listening on \(socketPath)")
    }

    /// Register a new Unix socket client and start its read loop.
    private func addUnixClient(_ fd: Int32) {
        let clientId = IPCClientID("unix:\(fd)")
        let handle = UnixSocketClientHandle(id: clientId, fd: fd)
        clients[clientId] = handle

        print("[IPC] Client connected (\(clientId))")

        let task = Task.detached { [weak self] in
            guard let self else { return }
            await unixReadLoop(clientId: clientId, fd: fd)
        }
        unixReadTasks[clientId] = task
    }

    /// Blocking read loop for a Unix socket client.
    private nonisolated func unixReadLoop(clientId: IPCClientID, fd: Int32) async {
        var buffer = Data()
        let readBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
        defer { readBuf.deallocate() }

        while !Task.isCancelled {
            let bytesRead = Darwin.read(fd, readBuf, 4_096)
            if bytesRead <= 0 { break }

            buffer.append(readBuf, count: bytesRead)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = Data(buffer[buffer.startIndex ..< newlineIndex])
                buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                if let request = try? JSONDecoder().decode(IPCInbound.self, from: lineData) {
                    await handleRequest(request, from: clientId)
                }
            }
        }

        Darwin.close(fd)
        await deregisterClient(clientId)
        print("[IPC] Client disconnected (\(clientId))")
    }

    // MARK: - WebSocket Server

    /// Start the WebSocket server for network-accessible IPC.
    private func startWebSocket() {
        let server = WebSocketServer(port: wsPort)
        wsServer = server

        Task {
            await server.setCallbacks(
                onConnected: { [weak self] handle in
                    await self?.registerClient(handle)
                },
                onDisconnected: { [weak self] clientId in
                    await self?.deregisterClient(clientId)
                },
                onMessage: { [weak self] clientId, request in
                    await self?.handleRequest(request, from: clientId)
                },
            )

            do {
                try await server.start()
            } catch {
                print("[WebSocket] Failed to start server: \(error)")
            }
        }
    }

    // MARK: - Request Handling

    /// Cached context estimate to avoid expensive recomputation on every poll.
    /// Lazily computed on first inspector poll, then refreshed every 30 seconds.
    private var cachedContextEstimate: (used: Int, budget: Int)?
    private var lastContextEstimateTime: Date = .distantPast

    /// Handle an inbound request from any transport.
    private func handleRequest(_ request: IPCInbound, from clientId: IPCClientID) async {
        switch request {
        case .pollInspector:
            let snapshot = await gatherInspectorData()
            sendTo(clientId, message: .inspector(snapshot))

        case let .sendMessage(sessionKey, text, images):
            print("[IPC] sendMessage received: session=\(sessionKey), text=\(text.prefix(80))")
            let attachments = (images ?? []).map {
                ImageAttachment(data: $0.data, mediaType: $0.mediaType, filename: $0.filename)
            }
            await handleSendMessage(sessionKey: sessionKey, text: text, images: attachments, clientId: clientId)

        case let .getHistory(sessionKey, limit, beforeId):
            await handleGetHistory(sessionKey: sessionKey, limit: limit, beforeId: beforeId, clientId: clientId)

        case .getContext, .compact:
            break
        }
    }

    /// Handle a `sendMessage` request by routing through the event queue.
    private func handleSendMessage(sessionKey: String, text: String, images: [ImageAttachment], clientId: IPCClientID) async {
        broadcastExcluding(.message(IPCChatMessage(
            role: "user",
            content: text,
            channel: "ipc",
            author: nil,
            timestamp: Date().timeIntervalSince1970,
        )), excluding: clientId)

        let context = IPCInboundContext(
            text: text,
            sessionKey: sessionKey,
            images: images,
        )

        if let eventQueue {
            await eventQueue.enqueue(.ipcMessage(context))
        } else {
            print("[IPC] Warning: event queue not set, running turn directly")
            let inbound = InboundMessage(
                text: text,
                parts: [MessagePart(kind: .text, ordinal: 0, content: text, metadata: nil)],
                metadata: nil,
                images: images,
            )
            let request = TurnRequest(
                turnID: UUID().uuidString,
                sessionKey: sessionKey,
                userKey: "ipc",
                message: inbound,
                receivedAt: .now,
                streaming: true,
            )
            let observer = IPCTurnObserver(ipc: self, dmChannelId: discordDMChannelId)
            do {
                try await gateway.runTurn(request, observer: observer)
                broadcast(.streamEnd)
            } catch {
                print("[IPC] Send message failed: \(error)")
            }
        }
    }

    // MARK: - History

    /// Handle a `getHistory` request by querying persisted messages.
    private func handleGetHistory(sessionKey: String?, limit: Int, beforeId: Int64?, clientId: IPCClientID) async {
        let clampedLimit = min(max(limit, 1), 100)

        do {
            let messages = try await gateway.database.dbPool.read { db -> [IPCHistoryMessage] in
                var sql: String
                var arguments: StatementArguments

                if let sessionKey {
                    if let beforeId {
                        sql = """
                        SELECT m.id, m.role, m.content, m.createdAt, c.sessionKey
                        FROM messages m
                        JOIN conversations c ON c.id = m.conversationId
                        WHERE c.sessionKey = ? AND m.id < ?
                        ORDER BY m.id DESC
                        LIMIT ?
                        """
                        arguments = [sessionKey, beforeId, clampedLimit]
                    } else {
                        sql = """
                        SELECT m.id, m.role, m.content, m.createdAt, c.sessionKey
                        FROM messages m
                        JOIN conversations c ON c.id = m.conversationId
                        WHERE c.sessionKey = ?
                        ORDER BY m.id DESC
                        LIMIT ?
                        """
                        arguments = [sessionKey, clampedLimit]
                    }
                } else {
                    if let beforeId {
                        sql = """
                        SELECT m.id, m.role, m.content, m.createdAt, c.sessionKey
                        FROM messages m
                        JOIN conversations c ON c.id = m.conversationId
                        WHERE m.id < ?
                        ORDER BY m.id DESC
                        LIMIT ?
                        """
                        arguments = [beforeId, clampedLimit]
                    } else {
                        sql = """
                        SELECT m.id, m.role, m.content, m.createdAt, c.sessionKey
                        FROM messages m
                        JOIN conversations c ON c.id = m.conversationId
                        ORDER BY m.id DESC
                        LIMIT ?
                        """
                        arguments = [clampedLimit]
                    }
                }

                let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)

                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let plainFormatter = DateFormatter()
                plainFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                plainFormatter.timeZone = TimeZone(identifier: "UTC")

                let messageIds = rows.compactMap { $0["id"] as Int64? }

                var toolCallsByMessage: [Int64: [IPCToolCallPart]] = [:]
                var toolResultsByMessage: [Int64: [IPCToolResultPart]] = [:]

                if !messageIds.isEmpty {
                    let placeholders = messageIds.map { _ in "?" }.joined(separator: ",")
                    let partSQL = """
                    SELECT mp.messageId, mp.partKind, mp.content, mp.metadata
                    FROM message_parts mp
                    WHERE mp.messageId IN (\(placeholders))
                    AND mp.partKind IN ('toolCall', 'toolResult')
                    ORDER BY mp.messageId, mp.ordinal
                    """
                    var partArgs = StatementArguments()
                    for msgId in messageIds {
                        partArgs += [msgId]
                    }
                    let partRows = try Row.fetchAll(db, sql: partSQL, arguments: partArgs)

                    for partRow in partRows {
                        let messageId: Int64 = partRow["messageId"]
                        let partKind: String = partRow["partKind"]
                        let content: String = partRow["content"]
                        let metadata: String? = partRow["metadata"]

                        if partKind == "toolCall", let metadata {
                            if let metaData = metadata.data(using: .utf8),
                               let metaJSON = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                               let tcId = metaJSON["id"] as? String,
                               let tcName = metaJSON["name"] as? String {
                                let part = IPCToolCallPart(id: tcId, name: tcName, arguments: content)
                                toolCallsByMessage[messageId, default: []].append(part)
                            }
                        } else if partKind == "toolResult", let metadata {
                            if let metaData = metadata.data(using: .utf8),
                               let metaJSON = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
                               let toolUseId = metaJSON["toolUseId"] as? String {
                                let isError = metaJSON["isError"] as? Bool ?? false
                                let part = IPCToolResultPart(toolUseId: toolUseId, content: content, isError: isError)
                                toolResultsByMessage[messageId, default: []].append(part)
                            }
                        }
                    }
                }

                return rows.map { row in
                    let msgId: Int64 = row["id"]
                    let createdAt: String = row["createdAt"] ?? ""
                    let timestamp = (isoFormatter.date(from: createdAt) ?? plainFormatter.date(from: createdAt))?.timeIntervalSince1970 ?? 0

                    let tcParts = toolCallsByMessage[msgId]
                    let trParts = toolResultsByMessage[msgId]

                    return IPCHistoryMessage(
                        id: msgId,
                        role: row["role"],
                        content: row["content"],
                        timestamp: timestamp,
                        sessionKey: row["sessionKey"],
                        author: nil,
                        toolCalls: tcParts?.isEmpty == false ? tcParts : nil,
                        toolResults: trParts?.isEmpty == false ? trParts : nil,
                    )
                }
            }

            let chronological = Array(messages.reversed())
            let hasMore = messages.count == clampedLimit

            sendTo(clientId, message: .history(messages: chronological, hasMore: hasMore))
        } catch {
            print("[IPC] getHistory failed: \(error)")
            sendTo(clientId, message: .history(messages: [], hasMore: false))
        }
    }

    // MARK: - Inspector

    /// Gather inspector telemetry data from the CIMS gateway.
    func gatherInspectorData() async -> IPCInspectorData {
        let coordinator = gateway.coordinator
        let temporal = await coordinator.currentTemporalMode
        let alloMode = await coordinator.currentAllostasisMode
        let press = await coordinator.currentPressure
        let queue = await coordinator.currentQueueDepth

        if cachedContextEstimate == nil || Date().timeIntervalSince(lastContextEstimateTime) > 30 {
            cachedContextEstimate = await coordinator.estimateContextUsage()
            lastContextEstimateTime = Date()
        }
        let contextEstimate = cachedContextEstimate ?? (used: 0, budget: 0)

        let identity = await gateway.identityStore.currentIdentity()

        var nodeCount = 0
        var messageCount = 0
        if let counts = try? await gateway.database.dbPool.read({ db -> (Int, Int) in
            let nodes = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM lcm_nodes") ?? 0
            let msgs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
            return (nodes, msgs)
        }) {
            nodeCount = counts.0
            messageCount = counts.1
        }

        return IPCInspectorData(
            temporalMode: temporal.rawValue,
            allostasisMode: alloMode.rawValue,
            pressure: press,
            contextBudgetUsed: contextEstimate.used,
            contextBudgetTotal: contextEstimate.budget,
            queueDepth: queue,
            identityClaimCount: identity.claims.count,
            dagNodeCount: nodeCount,
            messageCount: messageCount,
            sessionKey: "",
        )
    }

    // MARK: - Helpers

    /// Send a message to a specific client by ID.
    private func sendTo(_ clientId: IPCClientID, message: IPCOutbound) {
        guard let handle = clients[clientId] else { return }
        do {
            try handle.sendSync(message)
        } catch {
            deregisterClient(clientId)
        }
    }
}

// MARK: - Unix Socket Client Handle

/// Transport handle for a Unix domain socket client.
///
/// Wraps a raw file descriptor and sends messages as newline-delimited JSON.
final class UnixSocketClientHandle: IPCClientHandle, @unchecked Sendable {
    let id: IPCClientID
    let fd: Int32

    private let encoder = JSONEncoder()

    init(id: IPCClientID, fd: Int32) {
        self.id = id
        self.fd = fd
    }

    func send(_ message: IPCOutbound) async throws {
        try sendSync(message)
    }

    func close() async {
        Darwin.close(fd)
    }
}

// MARK: - Synchronous Send Extension

extension IPCClientHandle {
    /// Synchronous send for use in broadcast loops where async overhead is wasteful.
    ///
    /// Unix socket handles write synchronously (Darwin.write). WebSocket handles
    /// buffer into NWConnection's send queue which is also effectively synchronous
    /// from the caller's perspective (the completion fires asynchronously but the
    /// data is enqueued immediately).
    func sendSync(_ message: IPCOutbound) throws {
        if let unix = self as? UnixSocketClientHandle {
            guard let data = try? JSONEncoder().encode(message) else { return }
            var line = data
            line.append(0x0A)
            let bytes = [UInt8](line)
            let written = Darwin.write(unix.fd, bytes, bytes.count)
            if written < 0 {
                throw IPCError.disconnected
            }
        } else if let ws = self as? WebSocketClientHandle {
            guard let data = try? JSONEncoder().encode(message) else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "ipc",
                metadata: [metadata],
            )
            ws.connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { _ in },
            )
        }
    }
}

// MARK: - IPC Turn Observer

/// TurnObserver for IPC-originated turns.
///
/// Broadcasts events to connected IPC clients and relays tool activity to Discord DMs.
final class IPCTurnObserver: TurnObserver, @unchecked Sendable {
    let ipc: DaemonIPC
    let dmChannelId: String?
    private var intermediateText = ""
    private(set) var responseText = ""
    private(set) var continuationDepth: Int?
    private var toolNames: [String] = []
    private var toolMessageId: String?

    init(ipc: DaemonIPC, dmChannelId: String?) {
        self.ipc = ipc
        self.dmChannelId = dmChannelId
    }

    func handleEvent(_ event: TurnEvent) async {
        switch event {
        case let .responseCompleted(text):
            if responseText.isEmpty { responseText = text }
        case let .responseDelta(text):
            intermediateText += text
            responseText = intermediateText
            await ipc.broadcast(.streamDelta(text: text))
        case let .delta(delta):
            if let text = delta.text {
                intermediateText += text
                responseText = intermediateText
                await ipc.broadcast(.streamDelta(text: text))
            }
            if let tool = delta.toolCall {
                await ipc.broadcast(.toolCall(IPCToolCall(
                    name: tool.name, arguments: tool.arguments, id: tool.id,
                )))
                if let dmId = dmChannelId {
                    let argsPreview: String = {
                        guard let data = tool.arguments.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { return "" }
                        if let cmd = json["command"] as? String { return "(\(cmd.prefix(60)))" }
                        if let path = json["file_path"] as? String { return "(\(path.prefix(60)))" }
                        return ""
                    }()
                    toolNames.append("`\(tool.name)`\(argsPreview)")
                    let toolText = "🔧 " + toolNames.joined(separator: "\n🔧 ")
                    if let existingId = toolMessageId {
                        await AozoraDaemon.editDiscordMessage(channelId: dmId, messageId: existingId, content: toolText)
                    } else {
                        toolMessageId = await AozoraDaemon.sendDiscordMessageReturningId(channelId: dmId, content: toolText)
                    }
                }
            }
        case let .toolResult(result):
            await ipc.broadcast(.toolResult(IPCToolResult(
                id: result.toolUseId, output: result.content, isError: result.isError,
            )))
        case let .continuationNeeded(depth):
            continuationDepth = depth
        case let .forkDispatched(forkId):
            await ipc.broadcast(.toolCall(IPCToolCall(
                name: "fork", arguments: "{}", id: forkId,
            )))
        default:
            break
        }
    }
}
