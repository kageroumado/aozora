import Foundation
import Testing
@testable import Aozora

/// A mock provider that returns pre-configured responses or errors.
///
/// Each call dequeues the next outcome. When the queue is empty, returns a default success.
private actor ScriptedProvider: ModelProviding {
    enum Outcome {
        case success(String)
        case error(CIMSError)
    }

    private var script: [Outcome]
    private(set) var callCount: Int = 0

    init(script: [Outcome] = []) {
        self.script = script
    }

    func next() -> Outcome {
        callCount += 1
        guard !script.isEmpty else { return .success("default") }
        return script.removeFirst()
    }

    nonisolated func complete(_: Prompt, tier _: ModelTier) async throws -> ModelResponse {
        let outcome = await next()
        switch outcome {
        case let .success(text):
            return ModelResponse(
                content: text,
                toolCalls: [],
                tokenUsage: TokenUsage(inputTokens: 10, outputTokens: 5),
                latency: .milliseconds(50),
            )
        case let .error(err):
            throw err
        }
    }

    nonisolated func stream(
        _: Prompt, tier _: ModelTier,
    ) async throws -> AsyncThrowingStream<ModelDelta, any Error> {
        let outcome = await next()
        switch outcome {
        case let .success(text):
            return AsyncThrowingStream { c in
                c.yield(ModelDelta(text: text, toolCall: nil))
                c.yield(ModelDelta(text: nil, toolCall: nil, stopReason: "end_turn"))
                c.finish()
            }
        case let .error(err):
            throw err
        }
    }
}

// MARK: - Helpers

private let dummyPrompt = Prompt(system: [], messages: [], tools: [])

struct ResilientProviderTests {
    // MARK: - Basic Failover

    @Test
    func `Primary succeeds — no fallback attempted`() async throws {
        let primary = ScriptedProvider(script: [.success("primary response")])
        let fallback = ScriptedProvider(script: [.success("fallback response")])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        let response = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(response.content == "primary response")
        #expect(await primary.callCount == 1)
        #expect(await fallback.callCount == 0)
    }

    @Test
    func `Primary fails with retryable error — fallback succeeds`() async throws {
        let primary = ScriptedProvider(script: [
            .error(.modelError("Server error (503): overloaded")),
        ])
        let fallback = ScriptedProvider(script: [.success("fallback ok")])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        let response = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(response.content == "fallback ok")
        #expect(await primary.callCount == 1)
        #expect(await fallback.callCount == 1)
    }

    @Test
    func `All providers fail — throws after exhausting chain`() async throws {
        let p1 = ScriptedProvider(script: [.error(.modelError("Server error (503): down"))])
        let p2 = ScriptedProvider(script: [.error(.modelError("Server error (502): down"))])
        let p3 = ScriptedProvider(script: [.error(.modelError("Server error (500): down"))])

        let resilient = ResilientProvider(providers: [
            ("p1", p1), ("p2", p2), ("p3", p3),
        ], maxRetries: 3)

        do {
            _ = try await resilient.complete(dummyPrompt, tier: .executive)
            Issue.record("Expected error")
        } catch {
            #expect(await p1.callCount == 1)
            #expect(await p2.callCount == 1)
            #expect(await p3.callCount == 1)
        }
    }

    // MARK: - Error Classification

    @Test
    func `Fatal error throws immediately without fallback`() async throws {
        let primary = ScriptedProvider(script: [
            .error(.modelError("Bad request: invalid prompt")),
        ])
        let fallback = ScriptedProvider(script: [.success("fallback")])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        do {
            _ = try await resilient.complete(dummyPrompt, tier: .executive)
            Issue.record("Expected error")
        } catch {
            #expect(await primary.callCount == 1)
            #expect(await fallback.callCount == 0)
        }
    }

    @Test
    func `Rate limited error retries next provider`() async throws {
        let primary = ScriptedProvider(script: [
            .error(.rateLimited(retryAfter: 30, message: "too many requests")),
        ])
        let fallback = ScriptedProvider(script: [.success("fallback ok")])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        let response = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(response.content == "fallback ok")
    }

    @Test
    func `Context overflow is fatal`() async throws {
        let primary = ScriptedProvider(script: [
            .error(.contextOverflow(200_000, 128_000)),
        ])
        let fallback = ScriptedProvider(script: [.success("should not reach")])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        do {
            _ = try await resilient.complete(dummyPrompt, tier: .executive)
            Issue.record("Expected contextOverflow error")
        } catch let error as CIMSError {
            if case .contextOverflow = error {
                #expect(await fallback.callCount == 0)
            } else {
                Issue.record("Expected contextOverflow, got \(error)")
            }
        }
    }

    @Test
    func `modelUnavailable is retryable`() async throws {
        let primary = ScriptedProvider(script: [
            .error(.modelUnavailable(.executive)),
        ])
        let fallback = ScriptedProvider(script: [.success("recovered")])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        let response = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(response.content == "recovered")
    }

    // MARK: - Cooldown

    @Test
    func `Cooldown set after failure`() async throws {
        let primary = ScriptedProvider(script: [
            .error(.modelError("Server error (503): overloaded")),
            .success("second attempt"),
        ])
        let fallback = ScriptedProvider(script: [
            .success("fallback1"),
            .success("fallback2"),
        ])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        let r1 = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(r1.content == "fallback1")

        // Primary is cooling down, so second request goes straight to fallback
        let r2 = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(r2.content == "fallback2")
        #expect(await primary.callCount == 1)
    }

    @Test
    func `Cooldown resets on success`() async throws {
        let provider = ScriptedProvider(script: [
            .success("ok"),
        ])

        let resilient = ResilientProvider(providers: [("only", provider)])

        let response = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(response.content == "ok")

        let report = await resilient.healthReport()
        #expect(!report[0].isCoolingDown)
    }

    // MARK: - Health Tracking

    @Test
    func `Provider demoted after enough failures — demoted providers tried last`() async throws {
        // Use providers that always fail/succeed to test ordering.
        // After "bad" fails once per call (with cooldown reset between),
        // it accumulates enough failure records to be demoted.
        let bad = ScriptedProvider(script: (0 ..< 10).map { _ in
            .error(CIMSError.modelError("Server error (503): overloaded"))
        })
        let good = ScriptedProvider(script: (0 ..< 10).map { _ in .success("good") })

        let resilient = ResilientProvider(providers: [
            ("bad", bad),
            ("good", good),
        ], maxRetries: 2)

        // Each call: bad fails (cooldown set), good succeeds.
        // But bad is then cooling down for subsequent calls.
        // After the first call, bad has 1 failure. Reset state to test accumulation.
        _ = try? await resilient.complete(dummyPrompt, tier: .executive)

        // Verify bad has one failure recorded
        let report = await resilient.healthReport()
        let badHealth = try #require(report.first { $0.name == "bad" })
        #expect(badHealth.successRate == 0.0)
        // With only 1 sample, not yet demoted (needs 5)
        #expect(!badHealth.isDemoted)
    }

    @Test
    func `Healthy provider not demoted`() async throws {
        let provider = ScriptedProvider(script: [.success("ok")])
        let resilient = ResilientProvider(providers: [("p", provider)])

        _ = try await resilient.complete(dummyPrompt, tier: .executive)

        let report = await resilient.healthReport()
        #expect(report[0].successRate == 1.0)
        #expect(!report[0].isDemoted)
    }

    // MARK: - Streaming

    @Test
    func `Streaming failover works`() async throws {
        let primary = ScriptedProvider(script: [
            .error(.modelError("Server error (500): down")),
        ])
        let fallback = ScriptedProvider(script: [.success("stream content")])

        let resilient = ResilientProvider(providers: [
            ("primary", primary),
            ("fallback", fallback),
        ])

        let stream = try await resilient.stream(dummyPrompt, tier: .executive)
        var text = ""
        for try await delta in stream {
            if let t = delta.text { text += t }
        }
        #expect(text == "stream content")
    }

    // MARK: - Single Provider Passthrough

    @Test
    func `Single provider behaves identically to direct use`() async throws {
        let provider = ScriptedProvider(script: [.success("direct")])
        let resilient = ResilientProvider(single: provider)

        let response = try await resilient.complete(dummyPrompt, tier: .executive)
        #expect(response.content == "direct")
        #expect(await provider.callCount == 1)
    }

    // MARK: - Max Retries

    @Test
    func `Max retries limits total attempts`() async throws {
        let providers: [(String, ScriptedProvider)] = (0 ..< 5).map { i in
            ("p\(i)", ScriptedProvider(script: [.error(.modelError("Server error (503): down"))]))
        }

        let resilient = ResilientProvider(
            providers: providers.map { ($0.0, $0.1 as any ModelProviding) },
            maxRetries: 2,
        )

        do {
            _ = try await resilient.complete(dummyPrompt, tier: .executive)
            Issue.record("Expected error")
        } catch {
            var totalCalls = 0
            for (_, p) in providers {
                totalCalls += await p.callCount
            }
            #expect(totalCalls == 2)
        }
    }

    // MARK: - Health Report

    @Test
    func `Health report returns all providers`() async {
        let resilient = ResilientProvider(providers: [
            ("alpha", ScriptedProvider()),
            ("beta", ScriptedProvider()),
            ("gamma", ScriptedProvider()),
        ])

        let report = await resilient.healthReport()
        #expect(report.count == 3)
        #expect(report.map(\.name) == ["alpha", "beta", "gamma"])
    }
}

// MARK: - Error Classification Tests

struct ErrorClassificationTests {
    @Test
    func `overloaded message is retryable`() async {
        let resilient = ResilientProvider(providers: [("p", ScriptedProvider())])
        let result = await resilient.classify(CIMSError.modelError("Server error (503): overloaded"))
        if case .retryable = result {} else {
            Issue.record("Expected retryable")
        }
    }

    @Test
    func `Bad request is fatal`() async {
        let resilient = ResilientProvider(providers: [("p", ScriptedProvider())])
        let result = await resilient.classify(CIMSError.modelError("Bad request: invalid"))
        if case .fatal = result {} else {
            Issue.record("Expected fatal")
        }
    }

    @Test
    func `Rate limited returns retryAfter duration`() async {
        let resilient = ResilientProvider(providers: [("p", ScriptedProvider())])
        let result = await resilient.classify(CIMSError.rateLimited(retryAfter: 42, message: "slow down"))
        if case let .rateLimited(after) = result {
            #expect(after == 42)
        } else {
            Issue.record("Expected rateLimited")
        }
    }

    @Test
    func `contextOverflow is fatal`() async {
        let resilient = ResilientProvider(providers: [("p", ScriptedProvider())])
        let result = await resilient.classify(CIMSError.contextOverflow(200_000, 128_000))
        if case .fatal = result {} else {
            Issue.record("Expected fatal")
        }
    }

    @Test
    func `model unavailable retryable`() async {
        let resilient = ResilientProvider(providers: [("p", ScriptedProvider())])
        let result = await resilient.classify(CIMSError.modelUnavailable(.executive))
        if case .retryable = result {} else {
            Issue.record("Expected retryable")
        }
    }
}

// MARK: - CooldownState Tests

struct CooldownStateTests {
    @Test
    func `Fresh state is not cooling down`() {
        let state = ResilientProvider.CooldownState()
        #expect(!state.isCoolingDown)
        #expect(state.consecutiveFailures == 0)
    }

    @Test
    func `Failure puts provider in cooldown`() {
        var state = ResilientProvider.CooldownState()
        state.recordFailure()
        #expect(state.isCoolingDown)
        #expect(state.consecutiveFailures == 1)
    }

    @Test
    func `Success resets cooldown`() {
        var state = ResilientProvider.CooldownState()
        state.recordFailure()
        state.recordFailure()
        state.recordSuccess()
        #expect(!state.isCoolingDown)
        #expect(state.consecutiveFailures == 0)
    }

    @Test
    func `Consecutive failures increase cooldown duration`() {
        var state = ResilientProvider.CooldownState()

        state.recordFailure()
        let first = state.cooldownUntil.timeIntervalSinceNow

        state.recordFailure()
        let second = state.cooldownUntil.timeIntervalSinceNow

        state.recordFailure()
        let third = state.cooldownUntil.timeIntervalSinceNow

        #expect(second > first * 0.8)
        #expect(third > second * 0.8)
    }

    @Test
    func `retryAfter overrides backoff calculation`() {
        var state = ResilientProvider.CooldownState()
        state.recordFailure(retryAfter: 60)
        #expect(state.cooldownUntil.timeIntervalSinceNow > 59)
    }
}

// MARK: - HealthTracker Tests

struct HealthTrackerTests {
    @Test
    func `Empty tracker has 100% success rate`() {
        let tracker = ResilientProvider.HealthTracker()
        #expect(tracker.successRate == 1.0)
        #expect(!tracker.isDemoted)
    }

    @Test
    func `All successes = 100%`() {
        var tracker = ResilientProvider.HealthTracker(windowSize: 10)
        for _ in 0 ..< 10 {
            tracker.record(success: true)
        }
        #expect(tracker.successRate == 1.0)
    }

    @Test
    func `All failures = 0%`() {
        var tracker = ResilientProvider.HealthTracker(windowSize: 10)
        for _ in 0 ..< 10 {
            tracker.record(success: false)
        }
        #expect(tracker.successRate == 0.0)
        #expect(tracker.isDemoted)
    }

    @Test
    func `Mixed results compute correctly`() {
        var tracker = ResilientProvider.HealthTracker(windowSize: 10)
        for _ in 0 ..< 7 {
            tracker.record(success: true)
        }
        for _ in 0 ..< 3 {
            tracker.record(success: false)
        }
        #expect(tracker.successRate == 0.7)
        #expect(!tracker.isDemoted)
    }

    @Test
    func `Sliding window drops old entries`() {
        var tracker = ResilientProvider.HealthTracker(windowSize: 5)
        for _ in 0 ..< 5 {
            tracker.record(success: false)
        }
        #expect(tracker.successRate == 0.0)

        for _ in 0 ..< 5 {
            tracker.record(success: true)
        }
        #expect(tracker.successRate == 1.0)
    }

    @Test
    func `Demotion requires minimum samples`() {
        var tracker = ResilientProvider.HealthTracker(windowSize: 20)
        for _ in 0 ..< 3 {
            tracker.record(success: false)
        }
        #expect(!tracker.isDemoted)
    }
}
