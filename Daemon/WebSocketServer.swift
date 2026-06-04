import Foundation
import Network

/// WebSocket server for network-accessible IPC.
///
/// Listens on a TCP port with WebSocket protocol upgrade, accepts connections
/// from remote clients (e.g., the macOS app over Tailscale). Each connection
/// is wrapped as an ``IPCClientHandle`` and registered with ``DaemonIPC``.
///
/// Uses Network.framework (`NWListener` + `NWProtocolWebSocket.Options`) —
/// zero external dependencies.
actor WebSocketServer {
    /// The TCP port to listen on.
    private let port: UInt16

    /// The NWListener instance.
    private var listener: NWListener?

    /// Active connections keyed by client ID.
    private var connections: [IPCClientID: WebSocketClientHandle] = [:]

    /// Dispatch queue for Network.framework callbacks.
    private let queue = DispatchQueue(label: "aozora.ws-server", qos: .userInitiated)

    // MARK: - Callbacks

    /// Called when a new WebSocket client connects.
    var onClientConnected: (@Sendable (any IPCClientHandle) async -> Void)?

    /// Called when a WebSocket client disconnects.
    var onClientDisconnected: (@Sendable (IPCClientID) async -> Void)?

    /// Called when a message is received from a client.
    var onMessageReceived: (@Sendable (IPCClientID, IPCInbound) async -> Void)?

    /// Create a WebSocket server.
    ///
    /// - Parameter port: TCP port to listen on (default 19877).
    init(port: UInt16 = 19_877) {
        self.port = port
    }

    /// Set all callbacks at once (avoids multiple cross-actor hops).
    func setCallbacks(
        onConnected: @escaping @Sendable (any IPCClientHandle) async -> Void,
        onDisconnected: @escaping @Sendable (IPCClientID) async -> Void,
        onMessage: @escaping @Sendable (IPCClientID, IPCInbound) async -> Void,
    ) {
        onClientConnected = onConnected
        onClientDisconnected = onDisconnected
        onMessageReceived = onMessage
    }

    // MARK: - Lifecycle

    /// Start listening for WebSocket connections.
    ///
    /// - Throws: If the listener fails to start.
    func start() throws {
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let nwPort = NWEndpoint.Port(rawValue: port)!
        let nwListener = try NWListener(using: parameters, on: nwPort)

        nwListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleNewConnection(connection) }
        }

        nwListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("  ├─ WebSocket IPC listening on 0.0.0.0:\(nwPort)")
            case let .failed(error):
                print("[WebSocket] Listener failed: \(error)")
            default:
                break
            }
        }

        nwListener.start(queue: queue)
        listener = nwListener
    }

    /// Stop the WebSocket server and disconnect all clients.
    func stop() {
        listener?.cancel()
        listener = nil

        for handle in connections.values {
            handle.connection.cancel()
        }
        connections.removeAll()
    }

    // MARK: - Connection Handling

    /// Handle a new inbound WebSocket connection.
    private func handleNewConnection(_ connection: NWConnection) {
        let clientId = IPCClientID("ws:\(UUID().uuidString.prefix(8))")
        let handle = WebSocketClientHandle(id: clientId, connection: connection)
        connections[clientId] = handle

        connection.stateUpdateHandler = { [weak self, clientId] state in
            switch state {
            case .ready:
                print("[WebSocket] Client connected (\(clientId))")
                Task {
                    guard let self else { return }
                    await self.onClientConnected?(handle)
                    await self.startReceiving(clientId: clientId, connection: connection)
                }
            case .failed, .cancelled:
                Task {
                    guard let self else { return }
                    await self.removeConnection(clientId)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    /// Start receiving WebSocket messages from a connection.
    private func startReceiving(clientId: IPCClientID, connection: NWConnection) {
        receiveNext(clientId: clientId, connection: connection)
    }

    /// Receive the next WebSocket message (recursive pattern).
    private nonisolated func receiveNext(clientId: IPCClientID, connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("[WebSocket] Receive error (\(clientId)): \(error)")
                Task { await self.removeConnection(clientId) }
                return
            }

            guard let content, !content.isEmpty else {
                if isComplete {
                    Task { await self.removeConnection(clientId) }
                    return
                }
                receiveNext(clientId: clientId, connection: connection)
                return
            }

            // Decode the WebSocket text frame as IPCInbound
            if let request = try? JSONDecoder().decode(IPCInbound.self, from: content) {
                Task {
                    await self.onMessageReceived?(clientId, request)
                }
            }

            // Continue receiving
            receiveNext(clientId: clientId, connection: connection)
        }
    }

    /// Remove a connection and notify the delegate.
    private func removeConnection(_ clientId: IPCClientID) async {
        guard let handle = connections.removeValue(forKey: clientId) else { return }
        handle.connection.cancel()
        print("[WebSocket] Client disconnected (\(clientId))")
        await onClientDisconnected?(clientId)
    }
}

// MARK: - WebSocket Client Handle

/// Transport handle for a single WebSocket connection.
///
/// Wraps an `NWConnection` with WebSocket protocol and implements
/// ``IPCClientHandle`` for transport-agnostic message dispatch.
final class WebSocketClientHandle: IPCClientHandle, @unchecked Sendable {
    let id: IPCClientID
    let connection: NWConnection

    private let encoder = JSONEncoder()

    init(id: IPCClientID, connection: NWConnection) {
        self.id = id
        self.connection = connection
    }

    func send(_ message: IPCOutbound) async throws {
        guard let data = try? encoder.encode(message) else { return }

        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(
            identifier: "ipc",
            metadata: [metadata],
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                },
            )
        }
    }

    func close() async {
        connection.cancel()
    }
}
