import Foundation
import Testing
@testable import ClaudenceCore

// MARK: - Harness

/// A database in a fresh temporary directory, removed when the test ends.
/// Nothing here ever touches `~/Library/Application Support`.
private final class TempDerivedDatabase {
    let directory: URL
    let url: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceDerivedTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("claudence.db")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// UTC so day bucketing does not depend on where the test runs. The same
/// instance goes to the store and to the service.
private let derivedUTC: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func makeDerivedSession(
    id: String = UUID().uuidString,
    project: String = "Claudence",
    startedAt: Date,
    lastActivityAt: Date? = nil,
    usage: TokenUsage = .zero,
    model: String? = "claude-opus-5"
) -> AISession {
    AISession(
        id: id,
        provider: .claudeCode,
        pid: 4242,
        procStart: "2026-09-02T10:00:00Z",
        projectName: project,
        workingDirectory: "/Users/test/\(project)",
        status: .idle,
        startedAt: startedAt,
        lastActivityAt: lastActivityAt ?? startedAt,
        usage: usage,
        model: model,
        claudeCodeVersion: "2.0.1"
    )
}

// MARK: - Day over day

@Test("dayOverDay compares today's rollup with yesterday's")
func dayOverDayComparesTwoDays() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    // The store's rollup window comes from the real clock, so the service uses
    // the real clock too and the two windows line up.
    let now = Date()
    let yesterday = try #require(derivedUTC.date(byAdding: .day, value: -1, to: now))

    store.upsert(session: makeDerivedSession(
        startedAt: yesterday, usage: TokenUsage(freshInput: 1_000, output: 0)))
    store.upsert(session: makeDerivedSession(
        startedAt: now, usage: TokenUsage(freshInput: 1_100, output: 80)))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let delta = try #require(service.dayOverDay())

    #expect(delta.today == TokenUsage(freshInput: 1_100, output: 80))
    #expect(delta.yesterday == TokenUsage(freshInput: 1_000))
    #expect(delta.hasComparison)

    // (1180 - 1000) / 1000
    let change = try #require(delta.fractionalChange)
    #expect(abs(change - 0.18) < 0.000_001)
    let percent = try #require(delta.percentChange)
    #expect(abs(percent - 18.0) < 0.000_001)
}

@Test("a drop is a negative change, and equal days are exactly zero")
func dayOverDaySignAndZero() throws {
    let down = DayOverDayDelta(
        today: TokenUsage(freshInput: 500),
        yesterday: TokenUsage(freshInput: 2_000)
    )
    let change = try #require(down.fractionalChange)
    #expect(abs(change - (-0.75)) < 0.000_001)

    let flat = DayOverDayDelta(
        today: TokenUsage(freshInput: 10, output: 5),
        yesterday: TokenUsage(cacheRead: 10, output: 5)
    )
    #expect(flat.fractionalChange == 0)
}

@Test("a zero yesterday makes the change undefined, not infinite and not 100%")
func dayOverDayZeroYesterdayIsUndefined() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()

    store.upsert(session: makeDerivedSession(
        startedAt: now, usage: TokenUsage(freshInput: 5_000)))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let delta = try #require(service.dayOverDay())

    #expect(delta.today.total == 5_000)
    #expect(delta.yesterday == TokenUsage.zero)
    #expect(delta.fractionalChange == nil)
    #expect(delta.percentChange == nil)
    #expect(delta.hasComparison == false)
}

@Test("an empty store answers with two real zeros rather than nothing")
func dayOverDayOnEmptyStore() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let service = AnalyticsService(store: store, calendar: derivedUTC)

    let delta = try #require(service.dayOverDay())
    #expect(delta.today == TokenUsage.zero)
    #expect(delta.yesterday == TokenUsage.zero)
    #expect(delta.fractionalChange == nil)
}

// MARK: - Daily chart bands

@Test("the two chart bands are exactly billableInput and output, and they sum to total")
func dailyPointBandsSumToTotal() throws {
    let usage = TokenUsage(freshInput: 11, cacheCreation: 22, cacheRead: 33, output: 44, thinking: 7)
    let point = DailyPoint(day: "2026-09-02", date: Date(), usage: usage, cost: .zero)

    let input = try #require(point.billableInput)
    let output = try #require(point.output)
    let total = try #require(point.total)

    #expect(input == 66)
    #expect(output == 44)
    // The identity the chart relies on, verified rather than assumed.
    #expect(input + output == total)
    #expect(total == usage.total)
    // Thinking is already inside output and is not a third band.
    #expect(input + output == 110)
}

@Test("a day the store could not answer for is nil in both bands, not zero")
func dailyPointBandsAreNilOnAGap() {
    let gap = DailyPoint(day: "2026-09-01", date: Date(), usage: nil, cost: nil)
    #expect(gap.isAvailable == false)
    #expect(gap.billableInput == nil)
    #expect(gap.output == nil)
    #expect(gap.total == nil)

    let empty = DailyPoint(day: "2026-09-01", date: Date(), usage: .zero, cost: .zero)
    #expect(empty.billableInput == 0)
    #expect(empty.output == 0)
    #expect(empty.total == 0)
}

@Test("every point in a real series carries both bands")
func dailySeriesPointsCarryBands() {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()

    store.upsert(session: makeDerivedSession(
        startedAt: now, usage: TokenUsage(freshInput: 100, cacheRead: 900, output: 250)))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let series = service.dailySeries(days: 3)

    #expect(series.allSatisfy { $0.billableInput != nil && $0.output != nil })
    #expect(series.allSatisfy { ($0.billableInput ?? -1) + ($0.output ?? -1) == ($0.total ?? -2) })
    #expect(series.last?.billableInput == 1_000)
    #expect(series.last?.output == 250)
}

// MARK: - Share of recent activity

@Test("shares divide the locally measured total and sum to one")
func recentSharesDivideTheMeasuredTotal() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let anHourAgo = now.addingTimeInterval(-3_600)

    store.upsert(session: makeDerivedSession(
        id: "a", project: "Alpha", startedAt: anHourAgo, lastActivityAt: now,
        usage: TokenUsage(freshInput: 700, output: 50)))
    store.upsert(session: makeDerivedSession(
        id: "b", project: "Beta", startedAt: anHourAgo, lastActivityAt: anHourAgo,
        usage: TokenUsage(freshInput: 200, output: 50)))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let shares = try #require(service.shareOfRecentTokens())

    #expect(shares.window == AnalyticsService.recentActivityWindow)
    #expect(shares.until == now)
    #expect(shares.measuredTotal.total == 1_000)
    #expect(shares.sessions.map(\.sessionID) == ["a", "b"])

    let first = try #require(shares.share(ofSession: "a"))
    let second = try #require(shares.share(ofSession: "b"))
    #expect(abs(first - 0.75) < 0.000_001)
    #expect(abs(second - 0.25) < 0.000_001)
    #expect(abs(first + second - 1.0) < 0.000_001)
    #expect(shares.share(ofSession: "missing") == nil)
}

@Test("a session that has been quiet longer than the window is excluded from both sides")
func recentSharesExcludeStaleSessions() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let sixHoursAgo = now.addingTimeInterval(-6 * 3_600)

    store.upsert(session: makeDerivedSession(
        id: "live", startedAt: now, lastActivityAt: now,
        usage: TokenUsage(freshInput: 400)))
    store.upsert(session: makeDerivedSession(
        id: "stale", startedAt: sixHoursAgo, lastActivityAt: sixHoursAgo,
        usage: TokenUsage(freshInput: 9_000)))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let shares = try #require(service.shareOfRecentTokens())

    #expect(shares.sessions.map(\.sessionID) == ["live"])
    // The excluded session's tokens are not in the denominator either.
    #expect(shares.measuredTotal.total == 400)
    #expect(shares.share(ofSession: "live") == 1.0)
    #expect(shares.share(ofSession: "stale") == nil)
}

@Test("a window that measured nothing leaves every share undefined rather than zero")
func recentSharesUndefinedWhenNothingMeasured() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()

    store.upsert(session: makeDerivedSession(
        id: "quiet", startedAt: now, lastActivityAt: now, usage: .zero))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let shares = try #require(service.shareOfRecentTokens())

    #expect(shares.measuredTotal == TokenUsage.zero)
    #expect(shares.sessions.count == 1)
    #expect(shares.sessions[0].share == nil)
}

@Test("an empty store yields an answered, empty window rather than nil")
func recentSharesOnEmptyStore() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let service = AnalyticsService(store: store, calendar: derivedUTC)

    let shares = try #require(service.shareOfRecentTokens())
    #expect(shares.sessions.isEmpty)
    #expect(shares.measuredTotal == TokenUsage.zero)
}

@Test("a custom window narrows the set, and the window bounds are reported")
func recentSharesHonourACustomWindow() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let twoHoursAgo = now.addingTimeInterval(-2 * 3_600)

    store.upsert(session: makeDerivedSession(
        id: "recent", startedAt: now, lastActivityAt: now, usage: TokenUsage(output: 10)))
    store.upsert(session: makeDerivedSession(
        id: "older", startedAt: twoHoursAgo, lastActivityAt: twoHoursAgo,
        usage: TokenUsage(output: 90)))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })

    let fiveHours = try #require(service.shareOfRecentTokens())
    #expect(fiveHours.sessions.count == 2)

    let oneHour = try #require(service.shareOfRecentTokens(window: 3_600))
    #expect(oneHour.sessions.map(\.sessionID) == ["recent"])
    #expect(oneHour.since == now.addingTimeInterval(-3_600))
    #expect(oneHour.measuredTotal.total == 10)
}
