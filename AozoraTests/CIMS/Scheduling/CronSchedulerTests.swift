import Foundation
import Testing
@testable import Aozora

struct CronSchedulerTests {
    @Test
    func `parses interval schedule`() {
        let schedule = CronSchedule.parse("every 30m")
        #expect(schedule != nil)
        #expect(schedule?.kind == .interval)
        #expect(schedule?.intervalMinutes == 30)
    }

    @Test
    func `parses cron expression`() {
        let schedule = CronSchedule.parse("0 9 * * *")
        #expect(schedule != nil)
        #expect(schedule?.kind == .cron)
        #expect(schedule?.expression == "0 9 * * *")
    }

    @Test
    func `parses one-shot duration`() {
        let schedule = CronSchedule.parse("2h")
        #expect(schedule != nil)
        #expect(schedule?.kind == .once)
    }

    @Test
    func `computes next run for interval`() throws {
        let schedule = CronSchedule(kind: .interval, intervalMinutes: 30, expression: nil, runAt: nil)
        let now = Date()
        let next = schedule.nextRun(after: now)
        #expect(next != nil)
        let diff = try #require(next?.timeIntervalSince(now))
        #expect(diff > 1_790 && diff < 1_810) // ~30 minutes
    }

    @Test
    func `parses various interval formats`() {
        #expect(CronSchedule.parse("every 5m")?.intervalMinutes == 5)
        #expect(CronSchedule.parse("every 2h")?.intervalMinutes == 120)
        #expect(CronSchedule.parse("every 1d")?.intervalMinutes == 1_440)
    }

    @Test
    func `CRUD operations work`() async throws {
        let db = try CIMSDatabase.inMemory()
        let scheduler = CronScheduler(db: db)

        // Create
        try await scheduler.createJob(
            name: "test-job",
            prompt: "do something",
            schedule: "every 10m",
        )

        // List
        let jobs = try await scheduler.listJobs()
        #expect(jobs.count == 1)
        #expect(jobs[0].name == "test-job")

        // Pause
        try await scheduler.pauseJob(jobId: jobs[0].jobId)
        let paused = try await scheduler.listJobs()
        #expect(paused[0].enabled == false)

        // Resume
        try await scheduler.resumeJob(jobId: jobs[0].jobId)
        let resumed = try await scheduler.listJobs()
        #expect(resumed[0].enabled == true)

        // Remove
        try await scheduler.removeJob(jobId: jobs[0].jobId)
        let empty = try await scheduler.listJobs()
        #expect(empty.isEmpty)
    }
}
