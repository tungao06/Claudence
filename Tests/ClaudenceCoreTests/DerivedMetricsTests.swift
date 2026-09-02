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

// MARK: - Sessions active today

@Test("sessionsActiveToday counts a session that started yesterday and is still working")
func sessionsActiveTodayCountsCarryOver() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let startOfToday = derivedUTC.startOfDay(for: now)
    let yesterday = try #require(derivedUTC.date(byAdding: .day, value: -1, to: now))
    let twoDaysAgo = try #require(derivedUTC.date(byAdding: .day, value: -2, to: now))

    // Started today.
    store.upsert(session: makeDerivedSession(id: "today", startedAt: startOfToday))
    // Started yesterday, still going. This is the row the tile's denominator
    // exists for: counting by start date would leave it out and print a total
    // smaller than the live count beside it.
    store.upsert(session: makeDerivedSession(
        id: "carry-over", startedAt: yesterday, lastActivityAt: now))
    // Finished before today and never came back.
    store.upsert(session: makeDerivedSession(
        id: "old", startedAt: twoDaysAgo, lastActivityAt: yesterday))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    #expect(service.sessionsActiveToday() == 2)
}

@Test("an empty store answers zero sessions today rather than nothing")
func sessionsActiveTodayOnEmptyStore() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let service = AnalyticsService(store: store, calendar: derivedUTC)

    // Zero and nil are different claims: a working store saying "none today" is
    // an answer, and the tile prints it.
    #expect(service.sessionsActiveToday() == 0)
}

// MARK: - Recent sessions

@Test("recentSessions returns finished sessions, which is what a history table is")
func recentSessionsIncludesEndedSessions() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let threeDaysAgo = try #require(derivedUTC.date(byAdding: .day, value: -3, to: now))
    let fortyDaysAgo = try #require(derivedUTC.date(byAdding: .day, value: -40, to: now))

    store.upsert(session: makeDerivedSession(
        id: "recent", startedAt: threeDaysAgo, lastActivityAt: threeDaysAgo))
    store.markEnded(sessionID: "recent", at: threeDaysAgo)
    store.upsert(session: makeDerivedSession(
        id: "ancient", startedAt: fortyDaysAgo, lastActivityAt: fortyDaysAgo))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let window = try #require(derivedUTC.date(byAdding: .day, value: -30, to: now))
    let sessions = try #require(service.recentSessions(since: window))

    #expect(sessions.map(\.id) == ["recent"])
    #expect(sessions[0].status == .completed)
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

// MARK: - Hourly series

private func usage(_ total: Int) -> TokenUsage {
    TokenUsage(freshInput: total, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0)
}

/// A fixed instant on the hour, so the buckets a test asserts on are the ones
/// it names rather than whatever the clock happened to be when it ran.
private func onTheHour(_ hoursAgo: Int, from now: Date) -> Date {
    let top = derivedUTC.dateInterval(of: .hour, for: now)!.start
    return derivedUTC.date(byAdding: .hour, value: -hoursAgo, to: top)!
}

@Test("hourlySeries differentiates the running totals rather than summing them")
func hourlySeriesDifferentiatesSamples() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let start = onTheHour(3, from: now)

    // A session running before the range, so its first in-range sample has a
    // baseline to subtract from. Totals climb 100 -> 300 -> 900.
    store.upsert(session: makeDerivedSession(
        id: "long", startedAt: onTheHour(9, from: now), lastActivityAt: now))
    store.recordUsageSample(
        sessionID: "long", usage: usage(100), at: onTheHour(4, from: now).addingTimeInterval(600))
    store.recordUsageSample(
        sessionID: "long", usage: usage(300), at: start.addingTimeInterval(600))
    store.recordUsageSample(
        sessionID: "long", usage: usage(900), at: onTheHour(2, from: now).addingTimeInterval(600))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let points = service.hourlySeries(in: start..<now)

    // 200 in the first hour and 600 in the second: differences, not totals. A
    // series that summed the samples would report 300 and 900.
    #expect(points.first(where: { $0.date == start })?.usage?.total == 200)
    #expect(points.first(where: { $0.date == onTheHour(2, from: now) })?.usage?.total == 600)
}

@Test("an hour with no sample is a gap, not a zero")
func hourlySeriesLeavesUnsampledHoursUnmeasured() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let start = onTheHour(3, from: now)

    store.upsert(session: makeDerivedSession(
        id: "long", startedAt: onTheHour(9, from: now), lastActivityAt: now))
    store.recordUsageSample(
        sessionID: "long", usage: usage(100), at: onTheHour(4, from: now))
    store.recordUsageSample(
        sessionID: "long", usage: usage(400), at: start.addingTimeInterval(60))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let points = service.hourlySeries(in: start..<now)

    // Claudence cannot tell an hour in which nothing happened from an hour in
    // which it was not running, so it claims neither.
    #expect(points.first(where: { $0.date == start })?.usage?.total == 300)
    #expect(points.first(where: { $0.date == onTheHour(2, from: now) })?.usage == nil)
    #expect(points.allSatisfy { $0.usage?.total != 0 })
}

@Test("a session that began inside the range counts its first sample in full")
func hourlySeriesCountsAFirstSampleForANewSession() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let start = onTheHour(3, from: now)

    // Born inside the range: nothing in its total predates the range, so the
    // whole of it belongs to the hour it was sampled in.
    store.upsert(session: makeDerivedSession(
        id: "fresh", startedAt: start.addingTimeInterval(60), lastActivityAt: now))
    store.recordUsageSample(
        sessionID: "fresh", usage: usage(500), at: start.addingTimeInterval(600))

    // Born before it: its first sample carries history from outside the range
    // and opens no bucket of its own.
    store.upsert(session: makeDerivedSession(
        id: "older", startedAt: onTheHour(20, from: now), lastActivityAt: now))
    store.recordUsageSample(
        sessionID: "older", usage: usage(9_000), at: start.addingTimeInterval(700))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let points = service.hourlySeries(in: start..<now)

    #expect(points.first(where: { $0.date == start })?.usage?.total == 500)
}

@Test("a cumulative regression contributes zero and the climb back is not counted twice")
func hourlySeriesDoesNotRecountAfterARegression() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let start = onTheHour(4, from: now)

    // The real shape of session 6ff2ff43 in the shipped database: a running
    // total that fell and then climbed back over the level it fell from.
    store.upsert(session: makeDerivedSession(
        id: "6ff2ff43", startedAt: onTheHour(20, from: now), lastActivityAt: now))
    store.recordUsageSample(
        sessionID: "6ff2ff43", usage: usage(189_121_530), at: onTheHour(5, from: now))
    store.recordUsageSample(
        sessionID: "6ff2ff43", usage: usage(51_512_855), at: start.addingTimeInterval(600))
    store.recordUsageSample(
        sessionID: "6ff2ff43", usage: usage(189_121_530),
        at: onTheHour(3, from: now).addingTimeInterval(600))
    store.recordUsageSample(
        sessionID: "6ff2ff43", usage: usage(200_000_000),
        at: onTheHour(2, from: now).addingTimeInterval(600))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let points = service.hourlySeries(in: start..<now)

    // The fall is a cursor reset, not a refund, so it is worth nothing. The
    // climb back to 189,121,530 restates tokens already drawn and is worth
    // nothing either. Only the 10,878,470 above the previous high is new.
    #expect(points.first(where: { $0.date == start })?.usage?.total == 0)
    #expect(points.first(where: { $0.date == onTheHour(3, from: now) })?.usage?.total == 0)
    #expect(
        points.first(where: { $0.date == onTheHour(2, from: now) })?.usage?.total == 10_878_470)

    let drawn = points.compactMap(\.usage).reduce(TokenUsage.zero, +)
    #expect(drawn.total == 10_878_470)
}

@Test("the high-water mark is per field, so fields that never fell keep counting")
func hourlySeriesHoldsThePeakPerField() throws {
    let temp = TempDerivedDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: derivedUTC)
    let now = Date()
    let start = onTheHour(4, from: now)

    func sample(_ fresh: Int, _ cacheRead: Int, _ output: Int) -> TokenUsage {
        TokenUsage(freshInput: fresh, cacheRead: cacheRead, output: output)
    }

    // Only cacheRead regresses. Fresh input and output climb steadily through
    // it, and the hours they were spent in must still report them.
    store.upsert(session: makeDerivedSession(
        id: "partial", startedAt: onTheHour(20, from: now), lastActivityAt: now))
    store.recordUsageSample(
        sessionID: "partial", usage: sample(100, 1_000, 10), at: onTheHour(5, from: now))
    store.recordUsageSample(
        sessionID: "partial", usage: sample(120, 400, 12), at: start.addingTimeInterval(600))
    store.recordUsageSample(
        sessionID: "partial", usage: sample(140, 1_000, 14),
        at: onTheHour(3, from: now).addingTimeInterval(600))
    store.recordUsageSample(
        sessionID: "partial", usage: sample(160, 1_200, 16),
        at: onTheHour(2, from: now).addingTimeInterval(600))

    let service = AnalyticsService(store: store, calendar: derivedUTC, now: { now })
    let points = service.hourlySeries(in: start..<now)

    let first = try #require(points.first(where: { $0.date == start })?.usage)
    #expect(first == sample(20, 0, 2))

    let second = try #require(points.first(where: { $0.date == onTheHour(3, from: now) })?.usage)
    #expect(second == sample(20, 0, 2))

    let third = try #require(points.first(where: { $0.date == onTheHour(2, from: now) })?.usage)
    #expect(third == sample(20, 200, 2))
}

@Test("the five-hour range ends at the reset rather than at the clock")
func fiveHourRangeEndsAtTheReset() {
    let now = Date()
    let resetsAt = now.addingTimeInterval(-30 * 60)

    let range = AnalyticsService.fiveHourRange(resetsAt: resetsAt, now: now)
    #expect(range.upperBound == resetsAt)
    #expect(range.lowerBound == resetsAt.addingTimeInterval(-5 * 60 * 60))

    // A reset still ahead is the ordinary case, and the range stops at now:
    // hours that have not happened would otherwise draw as silence.
    let ahead = AnalyticsService.fiveHourRange(resetsAt: now.addingTimeInterval(3600), now: now)
    #expect(ahead.upperBound == now)
}

// MARK: - Reset stamps

@Test("a reset later today is stamped with the clock time and no day")
func resetStampOmitsTheDayWhenItIsToday() throws {
    let now = Date()
    let later = now.addingTimeInterval(90 * 60)
    let stamp = try #require(Format.resetStamp(later, now: now, calendar: derivedUTC))

    // The common case is a five-hour window rolling over the same day, and a
    // date printed on every reading would make it harder to read for the sake
    // of the rare one.
    #expect(!stamp.contains("Tomorrow"))
    #expect(!stamp.contains(","))
}

@Test("a reset tomorrow says so")
func resetStampNamesTomorrow() throws {
    let now = Date()
    let tomorrow = try #require(derivedUTC.date(byAdding: .day, value: 1, to: now))
    let stamp = try #require(Format.resetStamp(tomorrow, now: now, calendar: derivedUTC))
    #expect(stamp.hasPrefix("Tomorrow "))
}

@Test("a reset that has already passed still has a time, unlike a countdown to it")
func resetStampSurvivesAPastReset() throws {
    let now = Date()
    let past = now.addingTimeInterval(-30 * 60)

    // `timeUntil` is right to refuse: a countdown to a moment that has gone is
    // meaningless. A time that has gone is still a time, and the window may
    // simply not have been re-read yet.
    #expect(Format.timeUntil(past, now: now) == nil)
    #expect(Format.resetStamp(past, now: now, calendar: derivedUTC) != nil)
}

@Test("no reported reset is stamped as nothing rather than as a default")
func resetStampRefusesToInventOne() {
    #expect(Format.resetStamp(nil, now: Date(), calendar: derivedUTC) == nil)
}

@Suite("Share formatting")
struct ShareFormattingTests {

    /// The case that made this exist. Measured on a live session: 2 k of fresh
    /// input against a 197.7 M total is 0.001%, and the rounding formatter
    /// printed `0%` beside a count of `2k` on the same row.
    @Test("A real but tiny spend is never rounded down to zero")
    func tinySpendIsNotZero() {
        #expect(Format.share(2_000 / 197_700_000.0) == "<1%")
        #expect(Format.share(0.0049) == "<1%")
    }

    @Test("Nothing spent is zero, because that one is true")
    func nothingIsZero() {
        #expect(Format.share(0) == "0%")
    }

    @Test("Half a point rounds up rather than collapsing")
    func halfAPointRoundsUp() {
        #expect(Format.share(0.005) == "1%")
    }

    @Test("Ordinary shares round to whole percents")
    func ordinarySharesRound() {
        #expect(Format.share(0.5) == "50%")
        #expect(Format.share(0.984) == "98%")
        #expect(Format.share(1) == "100%")
    }
}
