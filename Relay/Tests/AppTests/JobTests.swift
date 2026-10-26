import Foundation
import HearthKit
import HearthKitTestSupport
import Jobs
import RelayCore
import Testing

@testable import App

@Suite("Job schedules")
struct JobScheduleTests {
    let zone = Fixtures.zone

    @Test func intervalJobsRunWhenTheirTimeHasPassed() {
        let every = JobSchedule.every(15 * 60)
        let now = Fixtures.now
        #expect(every.isDue(lastRun: nil, now: now, zone: zone))
        #expect(!every.isDue(lastRun: now.addingTimeInterval(-10 * 60), now: now, zone: zone))
        #expect(every.isDue(lastRun: now.addingTimeInterval(-15 * 60), now: now, zone: zone))
    }

    @Test func theBriefRunsOnceAfterSixThirty() {
        let brief = JobSchedule.daily(hour: 6, minute: 30)
        let before = Fixtures.at("2026-10-26T06:29")
        let after = Fixtures.at("2026-10-26T06:31")
        let yesterday = Fixtures.at("2026-10-25T06:31")
        #expect(!brief.isDue(lastRun: yesterday, now: before, zone: zone))
        #expect(brief.isDue(lastRun: yesterday, now: after, zone: zone))
        #expect(!brief.isDue(lastRun: after, now: Fixtures.at("2026-10-26T09:00"), zone: zone))
        // A Mac that was off all morning doesn't send the brief at dinner.
        #expect(!brief.isDue(lastRun: yesterday, now: Fixtures.at("2026-10-26T19:00"), zone: zone))
        #expect(brief.nextRun(lastRun: after, now: after, zone: zone) == Fixtures.at("2026-10-27T06:30"))
    }

    @Test func weeklyJobsRunOnTheirDay() {
        // Mondays at 5 AM. Fixtures.now is a Monday.
        let mondays = JobSchedule.weekly(weekday: 2, hour: 5, minute: 0)
        let lastWeek = Fixtures.at("2026-10-19T05:00")
        #expect(mondays.isDue(lastRun: lastWeek, now: Fixtures.at("2026-10-26T05:10"), zone: zone))
        #expect(!mondays.isDue(lastRun: Fixtures.at("2026-10-26T05:10"), now: Fixtures.at("2026-10-26T06:00"), zone: zone))
        #expect(!mondays.isDue(lastRun: lastWeek, now: Fixtures.at("2026-10-25T05:10"), zone: zone))
    }
}

@Suite("Job runner")
struct JobRunnerTests {
    struct Flaky: RelayJob {
        let name: String
        let schedule = JobSchedule.every(60)
        let fails: Bool
        func run(_ context: JobContext) async throws {
            if fails { throw BridgeError.notRunning("no gmailkit") }
        }
    }

    @Test func runsWhatsDueAndRecordsIt() async throws {
        try await withTestApp { t in
            let runner = JobRunner(jobs: [Flaky(name: "good", fails: false), Flaky(name: "bad", fails: true)])
            let context = t.app.jobContext()
            #expect(await runner.tick(context) == ["good", "bad"])
            #expect(await runner.tick(context).isEmpty)  // neither is due again yet
            let statuses = await runner.statuses(context)
            #expect(statuses[0].lastSuccess == t.clock.now && statuses[0].lastError == nil)
            #expect(statuses[1].lastSuccess == nil && statuses[1].lastError?.contains("no gmailkit") == true)
            t.clock.advance(61)
            #expect(await runner.tick(context) == ["good", "bad"])
        }
    }

    @Test func theCalendarJobFillsTheCache() async throws {
        try await withTestApp { t in
            let context = t.app.jobContext()
            #expect(await t.app.relay.jobs.run(named: "calendar", context))
            let cached = try await Cache(db: t.app.db).get(EventsResponse.self, Cache.events)
            #expect(cached?.events.count == 3)
            #expect(await t.app.relay.jobs.run(named: "nope", context) == false)
        }
    }
}

/// "Relay jobs can't reach the executor": the timed jobs never get a way to
/// write to mail or calendars. The package keeps `Jobs` from depending on
/// `Executor`; this test keeps it that way, and keeps write tools out of `Jobs`.
@Suite("Dependency graph")
struct DependencyGraphTests {
    static let relayRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func jobsDontDependOnTheExecutor() throws {
        let manifest = try String(contentsOf: Self.relayRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
        let line = try #require(manifest.components(separatedBy: "\n").first { $0.contains(#".target(name: "Jobs""#) })
        #expect(line.contains(#"dependencies: ["RelayCore"]"#), "Jobs must depend on RelayCore only: \(line)")
        #expect(!line.contains("Executor"))
    }

    @Test func jobSourcesNeverNameAWrite() throws {
        let folder = Self.relayRoot.appendingPathComponent("Sources/Jobs")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".swift") }
        #expect(!files.isEmpty)
        let banned =
            ["import Executor", "callWrite", "GoogleWriter", "GmailkitWriter", "GmailkitBridge", "ActionExecutor"]
            + GmailkitTools.write.sorted()
        for file in files {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            for word in banned {
                #expect(!text.contains(word), "\(file) mentions \(word)")
            }
        }
    }
}
