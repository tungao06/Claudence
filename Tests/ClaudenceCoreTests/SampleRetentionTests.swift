import Foundation
import Testing

@testable import ClaudenceCore

/// `usage_samples` grew without a bound and nothing read it cheaply: the rollup
/// repair reads every row on a 60 second throttle. The answer is a collapse
/// rather than a delete, and the only thing that makes a collapse acceptable is
/// that the day figures come out identical afterwards. That is what these tests
/// assert.
@Suite("Sample retention")
struct SampleRetentionTests {

    private func makeStore() -> ClaudenceStore {
        ClaudenceStore(url: nil)
    }

    private func makeSession(id: String, startedAt: Date, lastActivityAt: Date, usage: TokenUsage) -> AISession {
        AISession(
            id: id,
            pid: 4242,
            procStart: "Tue Sep  1 19:27:02 2026",
            projectName: "Claudence",
            workingDirectory: "/Users/tester/project/Claudence",
            status: .running,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            usage: usage
        )
    }

    /// Twenty days of samples, four an hour on each of them, then a collapse of
    /// everything older than the full-resolution window. Every day's total has
    /// to survive it exactly: this is the test that says the retention pass is
    /// a change of resolution and not a change of the numbers.
    @Test("collapsing old samples leaves every day's total untouched")
    func collapsePreservesDailyTotals() {
        let store = makeStore()
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        let startedAt = now.addingTimeInterval(-20 * day)

        var cumulative = TokenUsage.zero
        var samples = 0
        for dayOffset in stride(from: 20, through: 0, by: -1) {
            for hour in [2, 8, 14, 20] {
                cumulative += TokenUsage(freshInput: 100, cacheRead: 400, output: 20)
                let at = now
                    .addingTimeInterval(-Double(dayOffset) * day)
                    .addingTimeInterval(Double(hour - 12) * 60 * 60)
                guard at <= now else { continue }
                store.recordUsageSample(sessionID: "one", usage: cumulative, at: at)
                samples += 1
            }
        }
        store.upsert(
            session: makeSession(id: "one", startedAt: startedAt, lastActivityAt: now, usage: cumulative)
        )
        store.recomputeRollups()
        let before = store.dailyTotals(days: 30)
        #expect(before.count > 1)

        let removed = store.compactUsageSamples(
            olderThan: now.addingTimeInterval(-Double(ClaudenceStore.sampleFullResolutionDays) * day)
        )
        store.recomputeRollups()
        let after = store.dailyTotals(days: 30)

        #expect(removed > 0)
        #expect(after.map(\.day) == before.map(\.day))
        #expect(after.map(\.usage) == before.map(\.usage))
        // The point of the exercise: far fewer rows than went in.
        #expect(store.usageSamples(sessionID: "one").count < samples)
    }

    /// The window that keeps its resolution is not touched, because the hourly
    /// chart and the seven-day share read individual samples inside it.
    @Test("samples inside the full-resolution window are left alone")
    func recentSamplesSurvive() {
        let store = makeStore()
        let now = Date()
        let hour: TimeInterval = 60 * 60

        var cumulative = TokenUsage.zero
        for step in 1...12 {
            cumulative += TokenUsage(freshInput: 10, output: 2)
            store.recordUsageSample(sessionID: "one", usage: cumulative, at: now.addingTimeInterval(-Double(step) * hour))
        }

        let removed = store.compactUsageSamples(
            olderThan: now.addingTimeInterval(-Double(ClaudenceStore.sampleFullResolutionDays) * 24 * hour)
        )
        #expect(removed == 0)
        #expect(store.usageSamples(sessionID: "one").count == 12)
    }

    /// One row per session per day, not one row per day: two sessions that ran
    /// on the same old day both keep their own last sample, or the walk would
    /// have nothing to difference for one of them.
    @Test("each session keeps its own last sample for an old day")
    func collapseKeepsOneRowPerSessionPerDay() {
        let store = makeStore()
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        let oldDay = now.addingTimeInterval(-15 * day)

        for session in ["one", "two"] {
            var cumulative = TokenUsage.zero
            for step in 0..<6 {
                cumulative += TokenUsage(freshInput: 10, output: 1)
                store.recordUsageSample(
                    sessionID: session,
                    usage: cumulative,
                    at: oldDay.addingTimeInterval(Double(step) * hourSpacing)
                )
            }
        }

        store.compactUsageSamples(olderThan: now.addingTimeInterval(-Double(ClaudenceStore.sampleFullResolutionDays) * day))

        #expect(store.usageSamples(sessionID: "one").count == 1)
        #expect(store.usageSamples(sessionID: "two").count == 1)
        // The survivor is the last one, which is what carries the day's total.
        #expect(store.usageSamples(sessionID: "one").first?.usage == TokenUsage(freshInput: 60, output: 6))
    }

    /// A sample can be recorded with a moment of its own, so a clock that steps
    /// backwards, or a write that lands late, puts a higher row id on an
    /// earlier timestamp. Keeping the highest id would then hand the day's
    /// reconciled total an endpoint that is not the day's end, and the day would
    /// come back short. The survivor is chosen by time, not by insertion order.
    @Test("the survivor is the day's last sample even when it was written first")
    func collapseKeepsTheLatestTimestampNotTheLatestRow() {
        let store = makeStore()
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60
        let oldDay = now.addingTimeInterval(-15 * day)

        // Written in the wrong order on purpose: the day's last moment first.
        store.recordUsageSample(
            sessionID: "one",
            usage: TokenUsage(freshInput: 900, output: 90),
            at: oldDay.addingTimeInterval(6 * 60 * 60)
        )
        store.recordUsageSample(
            sessionID: "one",
            usage: TokenUsage(freshInput: 100, output: 10),
            at: oldDay
        )

        store.compactUsageSamples(
            olderThan: now.addingTimeInterval(-Double(ClaudenceStore.sampleFullResolutionDays) * day)
        )

        let remaining = store.usageSamples(sessionID: "one")
        #expect(remaining.count == 1)
        #expect(remaining.first?.usage == TokenUsage(freshInput: 900, output: 90))
    }

    /// The store's own calendar decides what a day is, everywhere. A store
    /// pinned to another zone, which is how the rollup tests make day
    /// boundaries deterministic, must collapse by the same definition it
    /// reconciles by.
    @Test("a store pinned to another time zone collapses by its own days")
    func collapseFollowsTheStoresCalendar() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let store = ClaudenceStore(url: nil, calendar: utc)
        let now = Date()
        let day: TimeInterval = 24 * 60 * 60

        // Two samples either side of UTC midnight, fifteen days back: two days
        // by this store's calendar, and one day for anywhere west of Greenwich.
        let utcMidnight = utc.startOfDay(for: now.addingTimeInterval(-15 * day))
        store.recordUsageSample(
            sessionID: "one",
            usage: TokenUsage(freshInput: 100, output: 10),
            at: utcMidnight.addingTimeInterval(-30 * 60)
        )
        store.recordUsageSample(
            sessionID: "one",
            usage: TokenUsage(freshInput: 200, output: 20),
            at: utcMidnight.addingTimeInterval(30 * 60)
        )

        store.compactUsageSamples(
            olderThan: now.addingTimeInterval(-Double(ClaudenceStore.sampleFullResolutionDays) * day)
        )

        // One survivor per day, so both rows stay: they are two days here.
        #expect(store.usageSamples(sessionID: "one").count == 2)
    }

    private var hourSpacing: TimeInterval { 60 * 60 }
}
