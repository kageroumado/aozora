#if OBSERVER_ENABLED

    import Foundation

    // MARK: - Observer Control Protocol

    /// Control interface for the subcortical observer (Qwen3-1.7B).
    ///
    /// This protocol defines how the command router and coordinator interact with the
    /// observer service. The observer may be:
    /// - **In-process** (Swift `ObserverEngine` running locally)
    /// - **Out-of-process** (Python service via Unix domain socket)
    ///
    /// Both implementations conform to this protocol, so the command system doesn't
    /// care where the observer lives.
    public nonisolated protocol ObserverControl: Sendable {
        /// Get the observer's current health status.
        func health() async -> ObserverHealthReport

        /// Start the observer cycle loop.
        func start() async

        /// Stop the observer cycle loop gracefully.
        func stop() async

        /// Trigger an immediate cycle (bypass the interval timer).
        func triggerCycle() async

        /// Inject novelty text into the observer's next cycle.
        ///
        /// The text is added to the plate as a perturbation source,
        /// fighting attractor collapse.
        func injectNovelty(_ text: String) async

        /// Change the cycle interval.
        ///
        /// - Parameter seconds: New interval in seconds (minimum 10).
        func setCycleInterval(_ seconds: Int) async

        /// Get the latest observer signal (text generated from hidden state).
        func latestSignal() async -> String?
    }

    // MARK: - Health Report

    /// Snapshot of the observer's current state.
    public struct ObserverHealthReport: Sendable {
        /// Whether the observer cycle loop is running.
        public let isRunning: Bool

        /// Current cycle number.
        public let cycleNumber: Int

        /// Current plate entropy (lower = more collapsed).
        public let plateEntropy: Double

        /// Current plate magnitude (L2 norm).
        public let plateMagnitude: Double

        /// Cycle interval in seconds.
        public let cycleIntervalSeconds: Int

        /// Text from the most recent observer signal.
        public let lastSignalText: String?

        /// When the last cycle completed.
        public let lastCycleAt: Date?

        public init(isRunning: Bool, cycleNumber: Int, plateEntropy: Double, plateMagnitude: Double, cycleIntervalSeconds: Int, lastSignalText: String?, lastCycleAt: Date?) {
            self.isRunning = isRunning
            self.cycleNumber = cycleNumber
            self.plateEntropy = plateEntropy
            self.plateMagnitude = plateMagnitude
            self.cycleIntervalSeconds = cycleIntervalSeconds
            self.lastSignalText = lastSignalText
            self.lastCycleAt = lastCycleAt
        }
    }

    // MARK: - Socket-based Observer Control

    /// Communicates with the Python observer service via Unix domain socket.
    ///
    /// Protocol: newline-delimited JSON over a Unix domain socket.
    /// Each request is a JSON object with `"command"` and optional `"params"`.
    /// Each response is a JSON object with `"status"` ("ok" or "error") and `"data"`.
    public actor SocketObserverControl: ObserverControl {
        private let socketPath: String

        public init(socketPath: String = "/tmp/aozora-observer.sock") {
            self.socketPath = socketPath
        }

        public func health() async -> ObserverHealthReport {
            guard let response = await send(command: "health") else {
                return ObserverHealthReport(
                    isRunning: false, cycleNumber: 0,
                    plateEntropy: 0, plateMagnitude: 0,
                    cycleIntervalSeconds: 0, lastSignalText: nil, lastCycleAt: nil,
                )
            }
            return ObserverHealthReport(
                isRunning: response["is_running"] as? Bool ?? false,
                cycleNumber: response["cycle_number"] as? Int ?? 0,
                plateEntropy: response["plate_entropy"] as? Double ?? 0,
                plateMagnitude: response["plate_magnitude"] as? Double ?? 0,
                cycleIntervalSeconds: response["cycle_interval_seconds"] as? Int ?? 0,
                lastSignalText: response["last_signal_text"] as? String,
                lastCycleAt: nil,
            )
        }

        public func start() async {
            _ = await send(command: "start")
        }

        public func stop() async {
            _ = await send(command: "stop")
        }

        public func triggerCycle() async {
            _ = await send(command: "trigger_cycle")
        }

        public func injectNovelty(_ text: String) async {
            _ = await send(command: "inject_novelty", params: ["text": text])
        }

        public func setCycleInterval(_ seconds: Int) async {
            _ = await send(command: "set_interval", params: ["seconds": seconds])
        }

        public func latestSignal() async -> String? {
            let response = await send(command: "latest_signal")
            return response?["signal_text"] as? String
        }

        // MARK: - Socket Communication

        private func send(command: String, params: [String: Any] = [:]) async -> [String: Any]? {
            // Create socket
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            // Connect
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = socketPath.utf8CString
            guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }

            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                    for (i, byte) in pathBytes.enumerated() {
                        dest[i] = byte
                    }
                }
            }

            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connectResult == 0 else { return nil }

            // Build request
            var request: [String: Any] = ["command": command]
            if !params.isEmpty {
                request["params"] = params
            }
            guard let requestData = try? JSONSerialization.data(withJSONObject: request),
                  var requestStr = String(data: requestData, encoding: .utf8)
            else { return nil }
            requestStr += "\n"

            // Send
            _ = requestStr.withCString { ptr in
                Darwin.send(fd, ptr, strlen(ptr), 0)
            }

            // Receive
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let bytesRead = recv(fd, &buffer, buffer.count - 1, 0)
            guard bytesRead > 0 else { return nil }

            let responseData = Data(buffer[0 ..< bytesRead])
            guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  json["status"] as? String == "ok"
            else { return nil }

            return json["data"] as? [String: Any]
        }
    }

#endif
