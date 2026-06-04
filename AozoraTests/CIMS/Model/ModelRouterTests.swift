import Foundation
import Testing
@testable import Aozora

struct ModelRouterTests {
    let router = ModelRouter()

    // MARK: - Worker Tier (Simple Messages)

    @Test
    func `Short greeting routes to worker`() {
        let decision = router.classify(text: "hey there")
        #expect(decision.tier == .workerDefault)
    }

    @Test
    func `Casual question routes to worker`() {
        let decision = router.classify(text: "what time is it?")
        #expect(decision.tier == .workerDefault)
    }

    @Test
    func `Empty message routes to worker`() {
        let decision = router.classify(text: "")
        #expect(decision.tier == .workerDefault)
    }

    @Test
    func `Short thanks routes to worker`() {
        let decision = router.classify(text: "thanks!")
        #expect(decision.tier == .workerDefault)
    }

    @Test
    func `Simple yes/no routes to worker`() {
        let decision = router.classify(text: "yes")
        #expect(decision.tier == .workerDefault)
    }

    // MARK: - Executive Tier (Complex Messages)

    @Test
    func `Code block routes to executive`() {
        let decision = router.classify(text: "```swift\nlet x = 5\n```")
        #expect(decision.tier == .executive)
    }

    @Test
    func `File path routes to executive`() {
        let decision = router.classify(text: "check /Users/alice/Developer/foo.swift")
        #expect(decision.tier == .executive)
    }

    @Test
    func `Long message routes to executive`() {
        let long = String(repeating: "a", count: 250)
        let decision = router.classify(text: long)
        #expect(decision.tier == .executive)
    }

    @Test
    func `Think keyword routes to executive`() {
        let decision = router.classify(text: "think about this carefully")
        #expect(decision.tier == .executive)
    }

    @Test
    func `Debug keyword routes to executive`() {
        let decision = router.classify(text: "debug this crash")
        #expect(decision.tier == .executive)
    }

    @Test
    func `Ambiguous request routes to executive (conservative)`() {
        let decision = router.classify(text: "can you help me with something important please")
        #expect(decision.tier == .executive)
    }

    @Test
    func `Image attachment routes to executive`() {
        let decision = router.classify(text: "what's in this?", hasImages: true)
        #expect(decision.tier == .executive)
    }

    @Test
    func `Swift code keywords route to executive`() {
        let decision = router.classify(text: "func doSomething()")
        #expect(decision.tier == .executive)
    }

    @Test
    func `File extension routes to executive`() {
        let decision = router.classify(text: "edit main.swift")
        #expect(decision.tier == .executive)
    }

    @Test
    func `Deploy keyword routes to executive`() {
        let decision = router.classify(text: "deploy to production")
        #expect(decision.tier == .executive)
    }

    @Test
    func `Analyze request routes to executive`() {
        let decision = router.classify(text: "analyze this pattern")
        #expect(decision.tier == .executive)
    }

    // MARK: - System Tier (Cron/Heartbeat)

    @Test
    func `System user routes to workerLight`() {
        let request = TurnRequest(
            turnID: "1",
            sessionKey: "session",
            userKey: "system",
            message: InboundMessage(text: "heartbeat check", parts: [], metadata: nil),
            receivedAt: Date(),
        )
        let decision = router.classify(request)
        #expect(decision.tier == ModelTier.workerLight)
    }

    // MARK: - Decision Reasoning

    @Test
    func `Decision includes human-readable reason`() {
        let d1 = router.classify(text: "hey")
        #expect(!d1.reason.isEmpty)

        let d2 = router.classify(text: "```code```")
        #expect(d2.reason.contains("code"))

        let d3 = router.classify(text: "", hasImages: true)
        #expect(d3.reason.contains("image"))
    }

    // MARK: - Edge Cases

    @Test
    func `Short ambiguous does NOT route to executive`() {
        let decision = router.classify(text: "can you?")
        #expect(decision.tier == .workerDefault)
    }

    @Test
    func `Technical keyword in short message routes to executive`() {
        let decision = router.classify(text: "fix the bug")
        #expect(decision.tier == .executive)
    }

    @Test
    func `Build keyword routes to executive`() {
        let decision = router.classify(text: "build failed")
        #expect(decision.tier == .executive)
    }

    @Test
    func `API keyword routes to executive`() {
        let decision = router.classify(text: "the api is broken")
        #expect(decision.tier == .executive)
    }
}
