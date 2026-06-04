import AozoraCore
import Foundation
import Network
import Observation

/// Connects to the Aozora daemon via Unix domain socket or WebSocket.
///
/// `@Observable` so SwiftUI views react to connection state changes and incoming messages.
/// The client maintains a persistent connection to the daemon, receives broadcast messages
/// (chat events, status updates), and can send requests (poll inspector, send messages).
///
/// **Local**: line-delimited JSON over Unix domain socket at `~/.aozora/daemon.sock`.
/// **Remote**: JSON over WebSocket at `ws://<host>:<port>` (e.g., Tailscale).
@Observable
final class IPCClient: @unchecked Sendable {
    /// Connection lifecycle state.
    enum ConnectionState {
        /// Not connected to the daemon.
        case disconnected
        /// Connection attempt in progress.
        case connecting
        /// Connected and receiving messages.
        case connected
        /// Connection failed with an error.
        case error(String)
    }

    /// How to connect to the daemon.
    enum ConnectionMode {
        /// Local Unix domain socket.
        case unixSocket(path: String)
        /// Remote WebSocket connection.
        case webSocket(host: String, port: UInt16)
    }

    /// Current connection state.
    private(set) var connectionState: ConnectionState = .disconnected

    /// The active connection mode, set after a successful connect.
    private(set) var activeMode: ConnectionMode?

    /// Default socket path for the daemon.
    static let defaultSocketPath = NSHomeDirectory() + "/.aozora/daemon.sock"

    /// Default WebSocket port.
    static let defaultWSPort: UInt16 = 19_877

    /// Path to the daemon's Unix domain socket (for local mode).
    private let socketPath: String

    /// The connected Unix socket file descriptor (local mode).
    private var socketFd: Int32 = -1

    /// The WebSocket connection (remote mode).
    private var wsConnection: NWConnection?

    /// Background task running the read loop (Unix socket mode).
    private var readTask: Task<Void, Never>?

    /// Continuation for the incoming message stream.
    private var incomingContinuation: AsyncStream<IPCOutbound>.Continuation?

    /// Stream of messages received from the daemon.
    ///
    /// Created when ``connect()`` or ``connect(mode:)`` succeeds. Consumers
    /// (e.g., ``ChatManager``) iterate this stream to receive real-time events.
    private(set) var incomingMessages: AsyncStream<IPCOutbound>?

    /// Creates an IPC client.
    ///
    /// - Parameter socketPath: Path to the daemon socket. Defaults to `~/.aozora/daemon.sock`.
    init(socketPath: String = IPCClient.defaultSocketPath) {
        self.socketPath = socketPath
    }

    // MARK: - Connection

    /// Check whether the daemon socket file exists.
    ///
    /// A quick pre-check before attempting a local connection.
    ///
    /// - Returns: `true` if the socket file exists on disk.
    static func daemonAvailable(socketPath: String = defaultSocketPath) -> Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    /// Connect to the daemon using the best available transport.
    ///
    /// Tries the local Unix domain socket first.
    ///
    /// - Returns: `true` if the connection succeeded.
    @discardableResult
    func connect() -> Bool {
        connect(mode: .unixSocket(path: socketPath))
    }

    /// Connect to the daemon using a specific transport.
    ///
    /// - Parameter mode: The connection mode (Unix socket or WebSocket).
    /// - Returns: `true` if the connection succeeded.
    @discardableResult
    func connect(mode: ConnectionMode) -> Bool {
        switch mode {
        case let .unixSocket(path):
            connectUnixSocket(path: path)
        case let .webSocket(host, port):
            connectWebSocket(host: host, port: port)
        }
    }

    /// Disconnect from the daemon.
    ///
    /// Closes whichever transport is active and finishes the incoming message stream.
    func disconnect() {
        readTask?.cancel()
        readTask = nil

        if socketFd >= 0 {
            Darwin.close(socketFd)
            socketFd = -1
        }

        wsConnection?.cancel()
        wsConnection = nil

        incomingContinuation?.finish()
        incomingContinuation = nil
        incomingMessages = nil

        activeMode = nil
        connectionState = .disconnected
    }

    // MARK: - Unix Socket

    /// Connect via local Unix domain socket.
    private func connectUnixSocket(path: String) -> Bool {
        connectionState = .connecting

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            connectionState = .error("Failed to create socket")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                UnsafeMutableRawPointer(pathPtr).copyMemory(
                    from: cstr,
                    byteCount: min(path.utf8.count + 1, 104),
                )
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            Darwin.close(fd)
            connectionState = .disconnected
            return false
        }

        socketFd = fd
        connectionState = .connected
        activeMode = .unixSocket(path: path)

        let (stream, continuation) = AsyncStream<IPCOutbound>.makeStream()
        incomingMessages = stream
        incomingContinuation = continuation

        readTask = Task.detached { [weak self, continuation] in
            guard let self else { return }
            unixReadLoop(fd: fd, continuation: continuation)
        }

        return true
    }

    /// Blocking read loop for Unix socket.
    private nonisolated func unixReadLoop(fd: Int32, continuation: AsyncStream<IPCOutbound>.Continuation) {
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

                if let message = try? JSONDecoder().decode(IPCOutbound.self, from: lineData) {
                    continuation.yield(message)
                }
            }
        }

        continuation.finish()

        DispatchQueue.main.async { [weak self] in
            self?.incomingContinuation = nil
            self?.connectionState = .disconnected
            self?.activeMode = nil
        }
    }

    // MARK: - WebSocket

    /// Connect via WebSocket to a remote daemon.
    private func connectWebSocket(host: String, port: UInt16) -> Bool {
        connectionState = .connecting

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: parameters,
        )

        let (stream, continuation) = AsyncStream<IPCOutbound>.makeStream()
        incomingMessages = stream
        incomingContinuation = continuation

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                DispatchQueue.main.async {
                    self.connectionState = .connected
                    self.activeMode = .webSocket(host: host, port: port)
                }
                wsReceiveNext(connection: connection, continuation: continuation)

            case let .failed(error):
                DispatchQueue.main.async {
                    self.connectionState = .error(error.localizedDescription)
                }
                continuation.finish()

            case .cancelled:
                continuation.finish()
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                    self.activeMode = nil
                }

            default:
                break
            }
        }

        let queue = DispatchQueue(label: "aozora.ws-client", qos: .userInitiated)
        connection.start(queue: queue)
        wsConnection = connection

        return true
    }

    /// Recursive WebSocket receive loop.
    private nonisolated func wsReceiveNext(
        connection: NWConnection,
        continuation: AsyncStream<IPCOutbound>.Continuation,
    ) {
        connection.receiveMessage { [weak self] content, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("[IPCClient] WebSocket receive error: \(error)")
                continuation.finish()
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                    self.activeMode = nil
                }
                return
            }

            if let content, !content.isEmpty {
                if let message = try? JSONDecoder().decode(IPCOutbound.self, from: content) {
                    continuation.yield(message)
                }
            }

            if isComplete {
                continuation.finish()
                DispatchQueue.main.async {
                    self.connectionState = .disconnected
                    self.activeMode = nil
                }
                return
            }

            wsReceiveNext(connection: connection, continuation: continuation)
        }
    }

    // MARK: - Sending

    /// Send a request to the daemon.
    ///
    /// Dispatches to the active transport (Unix socket write or WebSocket send).
    ///
    /// - Parameter message: The inbound IPC message to send.
    func send(_ message: IPCInbound) {
        guard let data = try? JSONEncoder().encode(message) else { return }

        switch activeMode {
        case .unixSocket:
            guard socketFd >= 0 else { return }
            var line = data
            line.append(0x0A)
            let bytes = [UInt8](line)
            let written = Darwin.write(socketFd, bytes, bytes.count)
            if written < 0 {
                connectionState = .error("Write failed")
                disconnect()
            }

        case .webSocket:
            guard let connection = wsConnection else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(
                identifier: "ipc",
                metadata: [metadata],
            )
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    if let error {
                        DispatchQueue.main.async {
                            self?.connectionState = .error("Send failed: \(error.localizedDescription)")
                        }
                    }
                },
            )

        case nil:
            break
        }
    }

    /// Request an inspector telemetry snapshot from the daemon.
    func pollInspector() {
        send(.pollInspector)
    }
}
