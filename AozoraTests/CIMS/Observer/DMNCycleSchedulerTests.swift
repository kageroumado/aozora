import Foundation
import Testing
@testable import Aozora

/// Mock delegate that records cycle calls for verification.
actor MockDMNCycleDelegate: DMNCycleDelegate {
    /// Number of times ``observerCycleDue(input:)`` was called.
    private(set) var callCount = 0

    /// The inputs received from cycle calls.
    private(set) var receivedInputs: [DMNCycleInput] = []

    nonisolated func observerCycleDue(input: DMNCycleInput) async {
        await recordCall(input: input)
    }

    private func recordCall(input: DMNCycleInput) {
        callCount += 1
        receivedInputs.append(input)
    }
}

struct DMNCycleSchedulerTests {
    @Test
    func `Start and stop toggles isRunning`() async {
        let scheduler = DMNCycleScheduler(cycleInterval: 100)

        #expect(await scheduler.isRunning == false)

        await scheduler.start()
        #expect(await scheduler.isRunning == true)

        await scheduler.stop()
        #expect(await scheduler.isRunning == false)
    }

    @Test
    func `Multiple start calls are idempotent`() async {
        let scheduler = DMNCycleScheduler(cycleInterval: 100)

        await scheduler.start()
        await scheduler.start()
        await scheduler.start()
        #expect(await scheduler.isRunning == true)

        await scheduler.stop()
        #expect(await scheduler.isRunning == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Delegate is called after cycle interval`() async throws {
        let delegate = MockDMNCycleDelegate()
        let scheduler = DMNCycleScheduler(cycleInterval: 0.1, delegate: delegate)

        await scheduler.start()

        // Poll until the delegate is called rather than sleeping a fixed duration,
        // since Task.detached scheduling + actor hops can take variable time under load.
        for _ in 0 ..< 50 {
            if await delegate.callCount >= 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        await scheduler.stop()

        let count = await delegate.callCount
        #expect(count >= 1, "Delegate should have been called at least once")
    }

    @Test
    func `triggerEarly causes immediate delegate call`() async throws {
        let delegate = MockDMNCycleDelegate()
        let scheduler = DMNCycleScheduler(cycleInterval: 100, delegate: delegate)

        await scheduler.triggerEarly(reason: "test")

        try await Task.sleep(for: .milliseconds(100))

        let count = await delegate.callCount
        #expect(count >= 1, "Delegate should have been called from triggerEarly")
    }
}
