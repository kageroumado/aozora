import Foundation

/// Lightweight local HTTP server that captures OAuth authorization codes.
///
/// Listens on `127.0.0.1:<port>/oauth/callback` for the provider's redirect.
/// Returns the authorization code (or error) and shuts down automatically.
/// Times out after 5 minutes if the user doesn't complete login.
///
/// **Usage:**
/// ```swift
/// let server = OAuthCallbackServer(port: 19876)
/// let result = try await server.waitForCallback(expectedState: "abc123")
/// // result is .success(code) or .error(description)
/// ```
public final class OAuthCallbackServer: @unchecked Sendable {
    /// Result of the callback.
    public enum CallbackResult: Sendable {
        case success(code: String)
        case error(description: String)
    }

    private let port: UInt16
    private let timeout: Duration
    private var serverSocket: Int32 = -1

    /// - Parameters:
    ///   - port: Local port to listen on (default 19876).
    ///   - timeout: How long to wait for the callback (default 5 minutes).
    public init(port: Int = 19_876, timeout: Duration = .seconds(300)) {
        self.port = UInt16(port)
        self.timeout = timeout
    }

    /// Start listening and wait for the OAuth callback.
    ///
    /// This method blocks until a callback arrives or the timeout expires.
    /// It handles exactly one request, sends an HTML response to the browser,
    /// and shuts down.
    ///
    /// - Parameter expectedState: The state parameter to validate (CSRF protection).
    /// - Returns: The callback result (code or error).
    public func waitForCallback(expectedState: String) async throws -> CallbackResult {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw OAuthClient.OAuthError.networkError("Failed to create socket")
        }
        serverSocket = fd

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw OAuthClient.OAuthError.networkError("Failed to bind to port \(port): \(String(cString: strerror(errno)))")
        }

        listen(fd, 1)

        return try await withThrowingTaskGroup(of: CallbackResult.self) { group in
            group.addTask {
                try await self.acceptAndHandle(fd: fd, expectedState: expectedState)
            }

            group.addTask {
                try await Task.sleep(for: self.timeout)
                throw OAuthClient.OAuthError.callbackTimeout
            }

            defer {
                group.cancelAll()
                close(fd)
                self.serverSocket = -1
            }

            return try await group.next()!
        }
    }

    private func acceptAndHandle(fd: Int32, expectedState: String) async throws -> CallbackResult {
        let clientFd = accept(fd, nil, nil)
        guard clientFd >= 0 else {
            throw OAuthClient.OAuthError.networkError("Failed to accept connection")
        }
        defer { close(clientFd) }

        // Read the HTTP request
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let bytesRead = read(clientFd, &buffer, buffer.count)
        guard bytesRead > 0 else {
            throw OAuthClient.OAuthError.networkError("Empty request")
        }

        let request = String(bytes: buffer[0 ..< bytesRead], encoding: .utf8) ?? ""

        // Parse the GET request path
        guard let pathLine = request.split(separator: "\r\n").first,
              let pathPart = pathLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(pathPart)")
        else {
            sendResponse(to: clientFd, html: errorHTML("Invalid request"))
            throw OAuthClient.OAuthError.networkError("Malformed callback request")
        }

        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
        )

        // Validate state parameter
        guard params["state"] == expectedState else {
            sendResponse(to: clientFd, html: errorHTML("Invalid state parameter (CSRF protection)"))
            return .error(description: "State mismatch — possible CSRF attack")
        }

        // Check for errors
        if let error = params["error"] {
            let description = params["error_description"] ?? error
            sendResponse(to: clientFd, html: errorHTML(description))
            return .error(description: description)
        }

        // Extract authorization code
        guard let code = params["code"] else {
            sendResponse(to: clientFd, html: errorHTML("No authorization code received"))
            return .error(description: "No authorization code in callback")
        }

        sendResponse(to: clientFd, html: successHTML())
        return .success(code: code)
    }

    private func sendResponse(to fd: Int32, html: String) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Connection: close\r
        Content-Length: \(html.utf8.count)\r
        \r
        \(html)
        """
        _ = response.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }
    }

    private func successHTML() -> String {
        """
        <!DOCTYPE html>
        <html>
        <body style="font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5;">
        <div style="text-align: center; padding: 40px; background: white; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
            <h2 style="color: #22c55e;">Authenticated</h2>
            <p>You can close this window and return to the terminal.</p>
        </div>
        </body>
        </html>
        """
    }

    private func errorHTML(_ message: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <body style="font-family: -apple-system, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; background: #f5f5f5;">
        <div style="text-align: center; padding: 40px; background: white; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
            <h2 style="color: #ef4444;">Authentication Failed</h2>
            <p>\(message)</p>
        </div>
        </body>
        </html>
        """
    }
}
