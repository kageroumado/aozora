import Foundation
import Testing
@testable import Aozora

// MARK: - Mock URL Protocol

/// A URL protocol that intercepts requests and returns pre-configured responses.
///
/// Responses are served from a static queue in FIFO order. Each response specifies
/// the HTTP status code, headers, and body data. Thread-safe via `NSLock`.
///
/// Declared at file scope so URLProtocol overrides retain their inherited
/// `nonisolated` isolation (the test target defaults to `@MainActor`).
final nonisolated class AnthropicTestURLProtocol: URLProtocol, @unchecked Sendable {
    /// A canned HTTP response to return from the mock.
    nonisolated struct MockResponse {
        let statusCode: Int
        let headers: [String: String]
        let data: Data

        init(statusCode: Int, headers: [String: String] = [:], body: String = "") {
            self.statusCode = statusCode
            self.headers = headers
            self.data = Data(body.utf8)
        }
    }

    /// Lock protecting the response queue.
    private nonisolated(unsafe) static var lock = NSLock()

    /// Queued responses to serve in order.
    private nonisolated(unsafe) static var responseQueue: [MockResponse] = []

    /// Number of requests received (for verifying retry counts).
    private nonisolated(unsafe) static var requestCount = 0

    /// The last request received (for header inspection).
    private nonisolated(unsafe) static var lastRequest: URLRequest?

    /// The body data from the last request (captured from httpBodyStream since
    /// URLSession converts httpBody to a stream before delivering to URLProtocol).
    private nonisolated(unsafe) static var lastRequestBody: Data?

    /// Reset the mock state between tests.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        responseQueue.removeAll()
        requestCount = 0
        lastRequest = nil
        lastRequestBody = nil
    }

    /// Enqueue a response to be served on the next request.
    static func enqueue(_ response: MockResponse) {
        lock.lock()
        defer { lock.unlock() }
        responseQueue.append(response)
    }

    /// Enqueue multiple responses to be served in order.
    static func enqueue(_ responses: [MockResponse]) {
        lock.lock()
        defer { lock.unlock() }
        responseQueue.append(contentsOf: responses)
    }

    /// The total number of requests received.
    static func getRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    /// The last request received, for header inspection.
    static func getLastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequest
    }

    /// The body data from the last request.
    static func getLastRequestBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestBody
    }

    /// The number of responses remaining in the queue.
    static func getResponseQueueCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return responseQueue.count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.anthropic.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Capture the body from httpBodyStream (URLSession converts httpBody to a stream).
        var bodyData: Data?
        if let body = request.httpBody {
            bodyData = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            let bufferSize = 65_536
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer {
                buffer.deallocate()
                stream.close()
            }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            bodyData = data
        }

        Self.lock.lock()
        Self.requestCount += 1
        Self.lastRequest = request
        Self.lastRequestBody = bodyData

        let response: MockResponse = if !Self.responseQueue.isEmpty {
            Self.responseQueue.removeFirst()
        } else {
            MockResponse(statusCode: 500, body: "No mock response configured")
        }
        Self.lock.unlock()

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers,
        )!

        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Tests

/// Tests for ``AnthropicProvider`` production resilience features:
/// exponential backoff with retry, prompt caching headers, and context overflow detection.
///
/// Uses ``AnthropicTestURLProtocol`` to intercept HTTP requests and return configurable
/// responses without making real API calls.
///
/// Retry tests use `maxRetries: 1` to keep test execution fast (backoff sleeps ~1s per retry).
@Suite(.serialized)
struct AnthropicProviderTests {
    // MARK: - Helpers

    /// Create a URLSession configured to use the mock protocol.
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AnthropicTestURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Create an ``AnthropicProvider`` wired to the mock session.
    private func makeProvider(
        session: URLSession,
        maxRetries: Int = 1,
    ) -> AnthropicProvider {
        AnthropicProvider(
            credential: .apiKey("sk-ant-test-key"),
            baseURL: "https://api.anthropic.com/v1/messages",
            session: session,
            maxRetries: maxRetries,
        )
    }

    /// Build a minimal ``Prompt`` for testing via ``PromptBuilder``.
    private func makePrompt(
        systemPrompt: String = "You are a test assistant.",
        userMessage: String = "Hello",
    ) -> Prompt {
        var sections: [ContextSection] = []

        if !systemPrompt.isEmpty {
            sections.append(ContextSection(
                kind: .systemPrompt,
                content: systemPrompt,
                tokenEstimate: systemPrompt.utf8.count / 4,
            ))
        }

        sections.append(ContextSection(
            kind: .freshTail,
            content: userMessage,
            tokenEstimate: userMessage.utf8.count / 4,
        ))

        let total = sections.reduce(0) { $0 + $1.tokenEstimate }

        let context = AssembledContext(
            sections: sections,
            totalTokens: total,
            currentMessageText: userMessage,
        )

        return PromptBuilder().build(context: context, credential: .apiKey, tools: []).prompt
    }

    /// Build a valid Anthropic Messages API JSON response body.
    private func makeSuccessJSON(text: String = "Hello, world!") -> String {
        """
        {"id":"msg_test","type":"message","role":"assistant","content":[{"type":"text","text":"\(text)"}],"model":"claude-sonnet-4-6","stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
        """
    }

    // MARK: - Retry Tests

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Retry on 429 rate limit: succeeds after one transient failure`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 429, body: "rate limited"),
            .init(statusCode: 200, body: makeSuccessJSON()),
        ])

        let provider = makeProvider(session: session, maxRetries: 1)
        let prompt = makePrompt()

        let response = try await provider.complete(prompt, tier: .workerDefault)
        #expect(response.content == "Hello, world!")
        #expect(AnthropicTestURLProtocol.getRequestCount() == 2)
    }

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Retry on 500 server error: succeeds after one failure`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 500, body: "internal server error"),
            .init(statusCode: 200, body: makeSuccessJSON()),
        ])

        let provider = makeProvider(session: session, maxRetries: 1)
        let prompt = makePrompt()

        let response = try await provider.complete(prompt, tier: .workerDefault)
        #expect(response.content == "Hello, world!")
        #expect(AnthropicTestURLProtocol.getRequestCount() == 2)
    }

    @Test
    func `No retry on 400 client error: fails immediately`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 400, body: "invalid request body"),
        ])

        let provider = makeProvider(session: session, maxRetries: 1)
        let prompt = makePrompt()

        await #expect(throws: CIMSError.self) {
            _ = try await provider.complete(prompt, tier: .workerDefault)
        }

        #expect(AnthropicTestURLProtocol.getRequestCount() == 1)
    }

    @Test(
        .timeLimit(.minutes(1)),
    )
    func `Max retries exceeded: throws error after all attempts`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 429, body: "rate limited"),
            .init(statusCode: 429, body: "rate limited"),
        ])

        let provider = makeProvider(session: session, maxRetries: 1)
        let prompt = makePrompt()

        await #expect(throws: CIMSError.self) {
            _ = try await provider.complete(prompt, tier: .workerDefault)
        }

        #expect(AnthropicTestURLProtocol.getRequestCount() == 2)
    }

    // MARK: - Context Overflow Tests

    @Test
    func `Context overflow from 413: throws contextOverflow`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 413, body: "Request too large: 150000 tokens > 100000 maximum"),
        ])

        let provider = makeProvider(session: session, maxRetries: 0)
        let prompt = makePrompt()

        do {
            _ = try await provider.complete(prompt, tier: .workerDefault)
            Issue.record("Expected contextOverflow error")
        } catch let error as CIMSError {
            guard case let .contextOverflow(actual, max) = error else {
                Issue.record("Expected contextOverflow, got \(error)")
                return
            }
            #expect(actual == 150_000)
            #expect(max == 100_000)
        }
    }

    @Test
    func `Context overflow from 400 body: detects token limit language`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 400, body: "maximum context length exceeded: 200000 tokens > 128000 limit"),
        ])

        let provider = makeProvider(session: session, maxRetries: 0)
        let prompt = makePrompt()

        do {
            _ = try await provider.complete(prompt, tier: .workerDefault)
            Issue.record("Expected contextOverflow error")
        } catch let error as CIMSError {
            guard case let .contextOverflow(actual, max) = error else {
                Issue.record("Expected contextOverflow, got \(error)")
                return
            }
            #expect(actual == 200_000)
            #expect(max == 128_000)
        }
    }

    @Test
    func `400 without context overflow keywords: throws modelError`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 400, body: "invalid model parameter"),
        ])

        let provider = makeProvider(session: session, maxRetries: 0)
        let prompt = makePrompt()

        do {
            _ = try await provider.complete(prompt, tier: .workerDefault)
            Issue.record("Expected modelError")
        } catch let error as CIMSError {
            guard case let .modelError(message) = error else {
                Issue.record("Expected modelError, got \(error)")
                return
            }
            #expect(message.contains("400"))
        }
    }

    // MARK: - Prompt Caching Tests

    @Test
    func `Request includes prompt caching headers and system content blocks`() async throws {
        AnthropicTestURLProtocol.reset()
        let session = makeMockSession()

        AnthropicTestURLProtocol.enqueue([
            .init(statusCode: 200, body: makeSuccessJSON()),
        ])

        let provider = makeProvider(session: session, maxRetries: 0)
        let prompt = makePrompt(systemPrompt: "You are a helpful test assistant.")

        _ = try await provider.complete(prompt, tier: .workerDefault)

        let lastRequest = AnthropicTestURLProtocol.getLastRequest()
        #expect(lastRequest != nil)

        let betaHeader = lastRequest?.value(forHTTPHeaderField: "anthropic-beta")
        #expect(betaHeader == "prompt-caching-2024-07-31")

        // URLSession converts httpBody to httpBodyStream before delivering to URLProtocol,
        // so we read the captured body from the mock instead.
        guard let bodyData = AnthropicTestURLProtocol.getLastRequestBody(),
              let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        else {
            Issue.record("Could not parse request body")
            return
        }

        guard let systemContent = body["system"] as? [[String: Any]] else {
            Issue.record("System content should be an array of content blocks")
            return
        }

        #expect(systemContent.count == 1)

        let firstBlock = systemContent[0]
        #expect(firstBlock["type"] as? String == "text")
        #expect(firstBlock["text"] as? String == "You are a helpful test assistant.")

        guard let cacheControl = firstBlock["cache_control"] as? [String: String] else {
            Issue.record("Expected cache_control on system content block")
            return
        }
        #expect(cacheControl["type"] == "ephemeral")
    }

    // MARK: - Backoff Computation Tests

    @Test
    func `Backoff computation: exponential growth with attempt number`() {
        let b0 = AnthropicProvider.computeBackoff(attempt: 0, retryAfterHeader: nil)
        let b1 = AnthropicProvider.computeBackoff(attempt: 1, retryAfterHeader: nil)
        let b2 = AnthropicProvider.computeBackoff(attempt: 2, retryAfterHeader: nil)
        let b3 = AnthropicProvider.computeBackoff(attempt: 3, retryAfterHeader: nil)
        let b4 = AnthropicProvider.computeBackoff(attempt: 4, retryAfterHeader: nil)

        #expect(b0 >= .seconds(1) && b0 <= .milliseconds(1_250))
        #expect(b1 >= .seconds(2) && b1 <= .milliseconds(2_500))
        #expect(b2 >= .seconds(4) && b2 <= .milliseconds(5_000))
        #expect(b3 >= .seconds(8) && b3 <= .milliseconds(10_000))
        #expect(b4 >= .seconds(16) && b4 <= .milliseconds(20_000))
    }

    @Test
    func `Backoff computation: Retry-After header sets minimum`() {
        let backoff = AnthropicProvider.computeBackoff(attempt: 0, retryAfterHeader: "30")
        #expect(backoff >= .seconds(30))
    }

    // MARK: - Token Count Parsing Tests

    @Test
    func `Parse token counts from error body`() {
        let (actual, max) = AnthropicProvider.parseTokenCounts(
            from: "prompt is too long: 150000 tokens > 100000 maximum",
        )
        #expect(actual == 150_000)
        #expect(max == 100_000)
    }

    @Test
    func `Parse token counts with commas`() {
        let (actual, max) = AnthropicProvider.parseTokenCounts(
            from: "prompt is too long: 1,500,000 tokens > 200,000 maximum",
        )
        #expect(actual == 1_500_000)
        #expect(max == 200_000)
    }

    @Test
    func `Parse token counts returns zeros for unparseable body`() {
        let (actual, max) = AnthropicProvider.parseTokenCounts(
            from: "something went wrong",
        )
        #expect(actual == 0)
        #expect(max == 0)
    }
}
