import Foundation
import Testing
@testable import ClaudenceCore

// Defect 9.7: the counts behind the words "active" and "today".
//
// Both words had more than one definition on one window. These tests pin the
// two definitions the whole application now uses:
//
//   active  a session doing work now, `status == .running`; every session with
//           a live process is *live*, and the two counts are named apart.
//   today   the day the work happened, `lastActivityAt >= startOfDay`, never
//           the day the session started.
//
// The surfaces that print these words live in the `Claudence` executable
// target, which this test target does not depend on, so what is testable here
// is the arithmetic they read. See the commit message for the call sites.

// MARK: - Harness

/// A database in a fresh temporary directory, removed when the test ends.
private final class TempCountingDatabase {
    let directory: URL
    let url: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceCountingTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("claudence.db")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// UTC so day bucketing does not depend on where the test runs.
private let countingUTC: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func makeCountingSession(
    id: String = UUID().uuidString,
    project: String = "Claudence",
    status: SessionStatus = .idle,
    startedAt: Date,
    lastActivityAt: Date? = nil,
    usage: TokenUsage = TokenUsage(output: 1_000),
    model: String? = "claude-opus-5"
) -> AISession {
    AISession(
        id: id,
        provider: .claudeCode,
        pid: 4242,
        procStart: "2026-09-02T10:00:00Z",
        projectName: project,
        workingDirectory: "/Users/test/\(project)",
        status: status,
        startedAt: startedAt,
        lastActivityAt: lastActivityAt ?? startedAt,
        usage: usage,
        model: model,
        claudeCodeVersion: "2.0.1"
    )
}

// MARK: - Active and live

@Test("activeCount counts the sessions doing work, liveCount counts every live session")
func activeCountIsRunningAndLiveCountIsEverySession() {
    let now = Date()
    let snapshot = MonitorSnapshot(sessions: [
        makeCountingSession(id: "busy", status: .running, startedAt: now),
        makeCountingSession(id: "waiting", status: .idle, startedAt: now)
    ])

    // The exact arrangement the defect names: one busy session and one idle
    // one. The two numbers differ, so the two words must.
    #expect(snapshot.activeCount == 1)
    #expect(snapshot.liveCount == 2)
}

@Test("active is always a subset of live, so the tile's fraction cannot invert")
func activeCountNeverExceedsLiveCount() {
    let now = Date()
    let statuses: [SessionStatus] = [.running, .idle, .running, .completed, .waiting]
    let snapshot = MonitorSnapshot(
        sessions: statuses.enumerated().map { index, status in
            makeCountingSession(id: "s\(index)", status: status, startedAt: now)
        }
    )

    #expect(snapshot.activeCount == 2)
    #expect(snapshot.liveCount == 5)
    // The property the Active-sessions tile depends on. Both halves are counted
    // off one array, which is what makes it a property rather than a hope.
    #expect(snapshot.activeCount <= snapshot.liveCount)
}

@Test("an empty snapshot counts zero of zero rather than nothing")
func emptySnapshotCountsZero() {
    #expect(MonitorSnapshot.empty.activeCount == 0)
    #expect(MonitorSnapshot.empty.liveCount == 0)
}

// MARK: - Today

@Test("todayCost prices the session that started yesterday and worked today")
func todayCostCountsTheCarryOverSession() throws {
    let temp = TempCountingDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: countingUTC)
    let now = Date()
    let yesterday = try #require(countingUTC.date(byAdding: .day, value: -1, to: now))
    let twoDaysAgo = try #require(countingUTC.date(byAdding: .day, value: -2, to: now))

    // Opened last night, still working this morning. Keyed on its start date
    // this session is yesterday's and the cost tile read $0.00 on a day whose
    // token total was not zero.
    store.upsert(session: makeCountingSession(
        id: "carry-over", startedAt: yesterday, lastActivityAt: now))
    // Finished before today and never came back.
    store.upsert(session: makeCountingSession(
        id: "old", startedAt: twoDaysAgo, lastActivityAt: yesterday))

    let service = AnalyticsService(store: store, calendar: countingUTC, now: { now })
    let cost = try #require(service.todayCost())
    #expect(cost.pricedSessions + cost.unpricedSessions == 1)
    #expect(try #require(cost.estimatedDollars) > 0)
}

@Test("todayCost and sessionsActiveToday describe the same set of sessions")
func todayCostAndSessionCountAgree() throws {
    let temp = TempCountingDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: countingUTC)
    let now = Date()
    let startOfToday = countingUTC.startOfDay(for: now)
    let yesterday = try #require(countingUTC.date(byAdding: .day, value: -1, to: now))
    let twoDaysAgo = try #require(countingUTC.date(byAdding: .day, value: -2, to: now))

    store.upsert(session: makeCountingSession(id: "today", startedAt: startOfToday))
    store.upsert(session: makeCountingSession(
        id: "carry-over", startedAt: yesterday, lastActivityAt: now))
    store.upsert(session: makeCountingSession(
        id: "old", startedAt: twoDaysAgo, lastActivityAt: yesterday))

    let service = AnalyticsService(store: store, calendar: countingUTC, now: { now })
    let cost = try #require(service.todayCost())
    let count = try #require(service.sessionsActiveToday())

    // One definition, two readings of it. These sat beside each other on the
    // dashboard disagreeing: the count included the overnight session and the
    // cost did not.
    #expect(count == 2)
    #expect(cost.pricedSessions + cost.unpricedSessions == count)
}

@Test("a session that only started today, with no later activity, is today's")
func aSessionStartedTodayCountsToday() throws {
    let temp = TempCountingDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: countingUTC)
    let now = Date()

    store.upsert(session: makeCountingSession(id: "fresh", startedAt: now))

    let service = AnalyticsService(store: store, calendar: countingUTC, now: { now })
    #expect(service.sessionsActiveToday() == 1)
    let cost = try #require(service.todayCost())
    #expect(cost.pricedSessions + cost.unpricedSessions == 1)
}
