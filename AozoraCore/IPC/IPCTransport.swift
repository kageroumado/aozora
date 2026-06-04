import Foundation

/// Opaque identifier for a connected IPC client.
///
/// Replaces raw file descriptors in the transport-agnostic IPC layer.
/// Each transport generates IDs with a prefix to avoid collisions
/// (e.g., `"unix:3"`, `"ws:A1B2"`).
public struct IPCClientID: Hashable, Sendable, CustomStringConvertible {
    /// The raw identifier string.
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }
}

/// A handle to a connected IPC client, abstracting the underlying transport.
///
/// Each transport (Unix socket, WebSocket) provides its own implementation.
/// ``DaemonIPC`` holds handles in a dictionary and broadcasts through them
/// without knowing the transport details.
public protocol IPCClientHandle: Sendable {
    /// Unique identifier for this client connection.
    var id: IPCClientID { get }

    /// Send a message to this client.
    ///
    /// - Parameter message: The outbound IPC message to send.
    /// - Throws: If the write fails (client disconnected, transport error).
    func send(_ message: IPCOutbound) async throws

    /// Close this client's connection.
    func close() async
}
