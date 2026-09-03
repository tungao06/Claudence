import Foundation
import Testing
@testable import ClaudenceCore

// MARK: - Harness

/// A database in a fresh temporary directory, removed when the test ends.
/// Nothing here ever touches `~/Library/Application Support`.
private final class TempAnalyticsDatabase {
    let directory: URL
    let url: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceAnalyticsTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("claudence.db")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A calendar pinned to UTC so day bucketing does not depend on where the test
/// runs. The same instance goes to the store and to the service.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func makeAnalyticsSession(
    id: String = UUID().uuidString,
    project: String = "Claudence",
    startedAt: Date,
    lastActivityAt: Date? = nil,
    usage: TokenUsage = .zero,
    subagentUsage: TokenUsage = .zero,
    model: String? = "claude-opus-5"
) -> AISession {
    AISession(
        id: id,
        pid: 4242,
        procStart: "2026-09-02T10:00:00Z",
        projectName: project,
        workingDirectory: "/Users/test/\(project)",
        status: .idle,
        startedAt: startedAt,
        lastActivityAt: lastActivityAt ?? startedAt,
        usage: usage,
        subagentUsage: subagentUsage,
        model: model,
        claudeCodeVersion: "2.0.1"
    )
}

// MARK: - Price lookup

@Test("an exact model id resolves to its own four rates")
func exactPriceLookup() {
    let price = ModelPricing.current.price(for: "claude-opus-5")
    #expect(price?.modelID == "claude-opus-5")
    #expect(price?.freshInputPerMillion == 5.00)
    #expect(price?.cacheWritePerMillion == 6.25)
    #expect(price?.cacheReadPerMillion == 0.50)
    #expect(price?.outputPerMillion == 25.00)
}

@Test("a dated snapshot falls back to its family, and the longest id wins")
func familyFallback() {
    let pricing = ModelPricing.current
    #expect(pricing.price(for: "claude-sonnet-5-20260101")?.modelID == "claude-sonnet-5")
    #expect(pricing.price(for: "claude-opus-4-8-20260101")?.modelID == "claude-opus-4-8")
    #expect(pricing.price(for: "claude-haiku-4-5-20251001")?.modelID == "claude-haiku-4-5")
    #expect(pricing.price(for: "CLAUDE-SONNET-5-20260101")?.modelID == "claude-sonnet-5")
    // Vertex and Bedrock id shapes normalise onto the same entries.
    #expect(pricing.price(for: "claude-opus-4-6@20251101")?.modelID == "claude-opus-4-6")
    #expect(pricing.price(for: "us.anthropic.claude-sonnet-5-20260101-v1:0")?.modelID == "claude-sonnet-5")
}

@Test("an unknown model returns nil, never a default and never an average")
func unknownModelHasNoPrice() {
    let pricing = ModelPricing.current
    #expect(pricing.price(for: "claude-imaginary-9") == nil)
    #expect(pricing.price(for: "gpt-5") == nil)
    #expect(pricing.price(for: "<synthetic>") == nil)
    #expect(pricing.price(for: nil) == nil)
    #expect(pricing.price(for: "") == nil)
    // A different model in the same family is not a snapshot of Sonnet 5.
    #expect(pricing.price(for: "claude-sonnet-5-1") == nil)
    // Not covered upstream for all four rates, so deliberately absent.
    #expect(pricing.price(for: "claude-mythos-5-1") == nil)
}

@Test("the table exposes its provenance so a stale table is visible")
func provenanceIsExposed() {
    let provenance = ModelPricing.current.provenance
    #expect(!provenance.source.isEmpty)
    #expect(provenance.recordedOn == Date(timeIntervalSince1970: 1_782_259_200)) // 2026-06-24
    #expect(provenance.isStale(asOf: provenance.recordedOn.addingTimeInterval(60)) == false)
    #expect(provenance.isStale(asOf: provenance.recordedOn.addingTimeInterval(365 * 86_400)))
}

// MARK: - Cost math

@Test("a hand-computed usage split prices to the expected dollar figure")
func handComputedCost() throws {
    let estimator = CostEstimator()
    // Opus 5: $5.00 fresh, $6.25 cache write, $0.50 cache read, $25.00 output.
    let usage = TokenUsage(
        freshInput: 100_000,     // 0.50
        cacheCreation: 200_000,  // 1.25
        cacheRead: 3_000_000,    // 1.50
        output: 40_000,          // 1.00
        thinking: 12_000         // billed inside output, never priced again
    )
    let dollars = try #require(estimator.estimate(usage: usage, model: "claude-opus-5"))
    #expect(abs(dollars - 4.25) < 0.000_001)
}

@Test("cache write and cache read are genuinely different rates")
func cacheWriteAndReadDifferInTheResult() throws {
    let estimator = CostEstimator()
    let price = try #require(ModelPricing.current.price(for: "claude-opus-5"))
    #expect(price.cacheWritePerMillion != price.cacheReadPerMillion)

    let write = try #require(estimator.estimate(
        usage: TokenUsage(cacheCreation: 1_000_000), model: "claude-opus-5"))
    let read = try #require(estimator.estimate(
        usage: TokenUsage(cacheRead: 1_000_000), model: "claude-opus-5"))
    #expect(write == 6.25)
    #expect(read == 0.50)
    #expect(write != read)
    // Collapsing the two would make the same token count price identically.
    #expect(abs(write - read) > 1.0)
}

@Test("an unpriced model yields nil, not zero")
func unpricedModelYieldsNil() {
    let estimator = CostEstimator()
    #expect(estimator.estimate(usage: TokenUsage(output: 1_000), model: "claude-imaginary-9") == nil)
    #expect(estimator.estimate(usage: TokenUsage(output: 1_000), model: nil) == nil)
}

@Test("a mix of priced and unpriced sessions reports the gap and keeps the tokens")
func partialPricingIsHonest() throws {
    let estimator = CostEstimator()
    let started = Date()
    let sessions = [
        makeAnalyticsSession(startedAt: started, usage: TokenUsage(freshInput: 1_000_000), model: "claude-opus-5"),
        makeAnalyticsSession(startedAt: started, usage: TokenUsage(output: 1_000_000), model: "claude-sonnet-5"),
        makeAnalyticsSession(startedAt: started, usage: TokenUsage(freshInput: 500, output: 700), model: "claude-imaginary-9"),
        makeAnalyticsSession(startedAt: started, usage: TokenUsage(freshInput: 300), model: nil),
    ]

    let estimate = estimator.estimate(sessions: sessions)
    #expect(estimate.pricedSessions == 2)
    #expect(estimate.unpricedSessions == 2)

    // $5.00 for the Opus 5 fresh input plus $10.00 for the Sonnet 5 output.
    let dollars = try #require(estimate.estimatedDollars)
    #expect(abs(dollars - 15.00) < 0.000_001)
}

@Test("nothing priceable yields nil dollars, while nothing at all yields a complete zero")
func nothingPriceableYieldsNil() {
    let estimator = CostEstimator()
    let unpriced = estimator.estimate(sessions: [
        makeAnalyticsSession(startedAt: Date(), usage: TokenUsage(output: 10), model: "claude-imaginary-9"),
    ])
    #expect(unpriced.estimatedDollars == nil)
    #expect(unpriced.pricedDollars == 0)

    let empty = estimator.estimate(sessions: [])
    #expect(empty.estimatedDollars == 0)
    #expect(empty.unpricedSessions == 0)
}

// MARK: - Daily series

@Test("dailySeries returns exactly `days` points and zero-fills the gap")
func dailySeriesZeroFillsGaps() throws {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    // The store's own rollup window is measured from the real clock, so the
    // service uses the real clock too and the two windows line up.
    let now = Date()
    let twoDaysAgo = try #require(utc.date(byAdding: .day, value: -2, to: now))

    store.upsert(session: makeAnalyticsSession(
        project: "Alpha", startedAt: twoDaysAgo,
        usage: TokenUsage(freshInput: 1_000, output: 2_000), model: "claude-opus-5"))
    store.upsert(session: makeAnalyticsSession(
        project: "Alpha", startedAt: now,
        usage: TokenUsage(freshInput: 3_000, output: 4_000), model: "claude-opus-5"))

    let service = AnalyticsService(store: store, calendar: utc, now: { now })
    let series = service.dailySeries(days: 3)

    #expect(series.count == 3)
    #expect(series.map(\.day) == series.map(\.day).sorted())
    #expect(series.allSatisfy { $0.isAvailable })

    #expect(series[0].usage == TokenUsage(freshInput: 1_000, output: 2_000))
    // The middle day has no data at all: a real zero, present in the series.
    #expect(series[1].usage == TokenUsage.zero)
    #expect(series[1].cost?.pricedSessions == 0)
    #expect(series[1].cost?.unpricedSessions == 0)
    #expect(series[2].usage == TokenUsage(freshInput: 3_000, output: 4_000))

    // $0.005 fresh + $0.05 output on the first day.
    let firstDay = try #require(series[0].cost?.estimatedDollars)
    #expect(abs(firstDay - 0.055) < 0.000_001)
    #expect(series[2].day == ClaudenceStore.dayString(for: now, calendar: utc))
}

@Test("dailySeries on an empty store is all zeros, and days <= 0 is empty")
func dailySeriesOnEmptyStore() {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    let service = AnalyticsService(store: store, calendar: utc)

    let series = service.dailySeries(days: 7)
    #expect(series.count == 7)
    #expect(series.allSatisfy { $0.usage == TokenUsage.zero })
    // An empty day is answered data, not a gap in the store's knowledge.
    #expect(series.allSatisfy { $0.isAvailable })
    #expect(service.dailySeries(days: 0).isEmpty)
    #expect(service.dailySeries(days: -3).isEmpty)
}

// MARK: - Project breakdown

@Test("projectBreakdown groups, counts, prices and sorts by tokens descending")
func projectBreakdownGroupsAndSorts() throws {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    let now = Date()

    store.upsert(session: makeAnalyticsSession(
        project: "Alpha", startedAt: now.addingTimeInterval(-3_600),
        lastActivityAt: now.addingTimeInterval(-3_000),
        usage: TokenUsage(freshInput: 1_000_000), model: "claude-opus-5"))
    store.upsert(session: makeAnalyticsSession(
        project: "Alpha", startedAt: now.addingTimeInterval(-1_800),
        lastActivityAt: now.addingTimeInterval(-600),
        usage: TokenUsage(freshInput: 1_000_000), model: "claude-imaginary-9"))
    store.upsert(session: makeAnalyticsSession(
        project: "Beta", startedAt: now.addingTimeInterval(-900),
        lastActivityAt: now.addingTimeInterval(-300),
        usage: TokenUsage(freshInput: 500), model: "claude-sonnet-5"))

    let service = AnalyticsService(store: store, calendar: utc, now: { now })
    let breakdown = service.projectBreakdown()

    #expect(breakdown.map(\.projectName) == ["Alpha", "Beta"])
    #expect(breakdown[0].sessionCount == 2)
    #expect(breakdown[0].usage.total == 2_000_000)
    #expect(breakdown[1].sessionCount == 1)
    #expect(breakdown[1].usage.total == 500)

    // Alpha is half unpriced, and says so rather than under-reporting silently.
    #expect(breakdown[0].cost.unpricedSessions == 1)
    let alpha = try #require(breakdown[0].cost.estimatedDollars)
    #expect(abs(alpha - 5.00) < 0.000_001)

    #expect(breakdown[1].cost.unpricedSessions == 0)

    // 600s and 1200s elapsed.
    #expect(abs(breakdown[0].averageSessionDuration - 900) < 1)
    let lastActivity = try #require(breakdown[0].lastActivity)
    #expect(abs(lastActivity.timeIntervalSince(now) + 600) < 1)
}

/// The defect this pins: the tokens column excluded subagents while the cost
/// column on the same row included them, so a project heavy on subagents was
/// understated by a factor that changed per row and sorted below projects it
/// dwarfed. Measured 3.2x on the live database on 2026-09-03.
@Test("projectBreakdown counts subagent tokens, and sorts on the combined figure")
func projectBreakdownIncludesSubagents() throws {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    let now = Date()

    // Heavy: a small parent that spawned most of its work.
    store.upsert(session: makeAnalyticsSession(
        project: "Heavy", startedAt: now.addingTimeInterval(-3_600),
        usage: TokenUsage(freshInput: 150_000),
        subagentUsage: TokenUsage(freshInput: 334_000),
        model: "claude-opus-5"))
    // Plain: a larger parent with no subagents. Smaller than Heavy combined,
    // larger than Heavy's parent alone -- exactly the case that sorted wrong.
    store.upsert(session: makeAnalyticsSession(
        project: "Plain", startedAt: now.addingTimeInterval(-1_800),
        usage: TokenUsage(freshInput: 200_000),
        model: "claude-opus-5"))

    let service = AnalyticsService(store: store, calendar: utc, now: { now })
    let breakdown = service.projectBreakdown()

    #expect(breakdown.map(\.projectName) == ["Heavy", "Plain"])
    #expect(breakdown[0].usage.total == 484_000)
    #expect(breakdown[1].usage.total == 200_000)

    // And the cost describes the same tokens the count does. Opus 5 fresh
    // input at $5 per million: 484k -> $2.42, not 150k -> $0.75.
    let heavy = try #require(breakdown[0].cost.estimatedDollars)
    #expect(abs(heavy - 2.42) < 0.000_001)
}

@Test("projectBreakdown honours `since` on the session start")
func projectBreakdownSinceWindow() {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    let now = Date()

    store.upsert(session: makeAnalyticsSession(
        project: "Old", startedAt: now.addingTimeInterval(-10_000),
        lastActivityAt: now, usage: TokenUsage(output: 10)))
    store.upsert(session: makeAnalyticsSession(
        project: "New", startedAt: now.addingTimeInterval(-100),
        lastActivityAt: now, usage: TokenUsage(output: 20)))

    let service = AnalyticsService(store: store, calendar: utc, now: { now })
    let recent = service.projectBreakdown(since: now.addingTimeInterval(-1_000))
    #expect(recent.map(\.projectName) == ["New"])
    #expect(service.projectBreakdown().count == 2)
}

@Test("an empty store yields empty results rather than a crash")
func emptyStoreYieldsEmptyResults() {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    let service = AnalyticsService(store: store, calendar: utc)

    #expect(service.projectBreakdown().isEmpty)
    #expect(service.projectBreakdown(since: Date()).isEmpty)
    #expect(service.todayTotal() == TokenUsage.zero)
    #expect(service.todayCost() == CostEstimate())
}

// MARK: - Today

@Test("todayTotal sums today's rollup and ignores earlier days")
func todayTotalCountsOnlyToday() throws {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    let now = Date()
    let threeDaysAgo = try #require(utc.date(byAdding: .day, value: -3, to: now))

    store.upsert(session: makeAnalyticsSession(
        project: "Alpha", startedAt: now, usage: TokenUsage(freshInput: 10, cacheRead: 90)))
    store.upsert(session: makeAnalyticsSession(
        project: "Beta", startedAt: now, usage: TokenUsage(output: 5)))
    store.upsert(session: makeAnalyticsSession(
        project: "Old", startedAt: threeDaysAgo, usage: TokenUsage(output: 999)))

    let service = AnalyticsService(store: store, calendar: utc, now: { now })
    let today = try #require(service.todayTotal())
    #expect(today == TokenUsage(freshInput: 10, cacheRead: 90, output: 5))
    // Never recomputed here: the contract's own definitions.
    #expect(today.billableInput == 100)
    #expect(today.total == 105)

    let cost = try #require(service.todayCost())
    #expect(cost.pricedSessions + cost.unpricedSessions == 2)
    #expect(cost.unpricedSessions == 0)
}

@Test("today reads stay unavailable after a prior store failure, never zero")
func todayReadsSurviveALatchedFailure() throws {
    let temp = TempAnalyticsDatabase()
    let store = ClaudenceStore(url: temp.url, calendar: utc)
    let now = Date()
    store.upsert(session: makeAnalyticsSession(startedAt: now, usage: TokenUsage(output: 5)))

    let service = AnalyticsService(store: store, calendar: utc, now: { now })
    #expect(service.todayTotal()?.total == 5)

    // Every statement throws from here on, so the first failing read is the
    // "prior failure": it degrades the store, and health has nowhere left to
    // move for the reads that follow.
    try #require(store.connection).close()
    _ = service.dailySeries(days: 1)

    #expect(service.todayTotal() == nil)
    #expect(service.todayCost() == nil)
    // The siblings, which the latch also broke once it had swallowed the first
    // transition.
    #expect(service.sessionsActiveToday() == nil)
    #expect(service.dayOverDay() == nil)
    #expect(service.dailySeries(days: 1).allSatisfy { !$0.isAvailable })
}
