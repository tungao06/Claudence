import Foundation

// MARK: - View-ready aggregates

/// One day of the daily series.
///
/// `usage` is optional on purpose. A day with no sessions is a real zero and
/// carries `TokenUsage.zero`; a day the store could not answer for carries nil.
/// A chart must render those differently — a gap is not a trough.
public struct DailyPoint: Sendable, Equatable, Identifiable {
    /// Local calendar date, "YYYY-MM-DD". Same bucketing as the store's rollups.
    public let day: String
    /// Start of that local day.
    public let date: Date
    /// Measured tokens, or nil when the store could not answer.
    public let usage: TokenUsage?
    /// Estimated cost for the day, or nil when the store could not answer.
    public let cost: CostEstimate?

    public var id: String { day }

    /// Whether the store answered for this day at all.
    public var isAvailable: Bool { usage != nil }

    public init(day: String, date: Date, usage: TokenUsage?, cost: CostEstimate?) {
        self.day = day
        self.date = date
        self.usage = usage
        self.cost = cost
    }
}

/// One project's totals over a window.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public let projectName: String
    public let usage: TokenUsage
    public let sessionCount: Int
    public let cost: CostEstimate
    /// Most recent activity across the project's sessions, nil when it has none.
    public let lastActivity: Date?
    /// Mean of `lastActivityAt - startedAt` over the project's sessions. Zero
    /// when there are none. Wall-clock elapsed time, not time spent working.
    public let averageSessionDuration: TimeInterval

    public var id: String { projectName }

    public init(
        projectName: String,
        usage: TokenUsage,
        sessionCount: Int,
        cost: CostEstimate,
        lastActivity: Date?,
        averageSessionDuration: TimeInterval
    ) {
        self.projectName = projectName
        self.usage = usage
        self.sessionCount = sessionCount
        self.cost = cost
        self.lastActivity = lastActivity
        self.averageSessionDuration = averageSessionDuration
    }
}

// MARK: - Service

/// Turns stored sessions into the aggregates the dashboard draws.
///
/// The store is the only source: nothing here touches the filesystem, the
/// network, or the clock beyond the injected `now`. Token totals are never
/// recomputed — `TokenUsage.total` and `.billableInput` remain the single
/// definitions, and the day buckets are the store's own.
public struct AnalyticsService: Sendable {
    private let store: ClaudenceStore
    private let estimator: CostEstimator
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - store: injected; this type never constructs a default path.
    ///   - calendar: must match the calendar the store buckets rollups with,
    ///     or the series and the rollups disagree at day boundaries.
    ///   - now: injected so a test can pin the window.
    public init(
        store: ClaudenceStore,
        estimator: CostEstimator = CostEstimator(),
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.estimator = estimator
        self.calendar = calendar
        self.now = now
    }

    /// Provenance of the price table behind every cost figure produced here.
    public var priceProvenance: PriceTableProvenance { estimator.provenance }

    // MARK: Daily series

    /// A contiguous series of exactly `days` points, oldest first, ending today.
    ///
    /// Gaps are zero-filled rather than omitted: a chart that skips empty days
    /// compresses them away and draws a slope that never happened. When the
    /// store cannot answer, every point carries nil usage instead of a zero, so
    /// "no work" and "no data" stay distinguishable.
    ///
    /// Tokens come from `dailyTotals` (the store's incremental rollups). Cost
    /// comes from the session rows, because a rollup has no model and a model is
    /// what a price needs; both bucket on `startedAt`, so they agree.
    public func dailySeries(days: Int) -> [DailyPoint] {
        guard days > 0 else { return [] }

        let today = calendar.startOfDay(for: now())
        let dates: [Date] = (0..<days).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        guard let earliest = dates.first else { return [] }

        let before = store.health
        let totals = store.dailyTotals(days: days)
        let sessions = store.allSessions(since: earliest)
        let answered = Self.answered(before: before, after: store.health)

        var usageByDay: [String: TokenUsage] = [:]
        for row in totals { usageByDay[row.day, default: .zero] += row.usage }

        var sessionsByDay: [String: [AISession]] = [:]
        for session in sessions {
            let day = ClaudenceStore.dayString(for: session.startedAt, calendar: calendar)
            sessionsByDay[day, default: []].append(session)
        }

        return dates.map { date in
            let day = ClaudenceStore.dayString(for: date, calendar: calendar)
            guard answered else {
                return DailyPoint(day: day, date: date, usage: nil, cost: nil)
            }
            return DailyPoint(
                day: day,
                date: date,
                usage: usageByDay[day] ?? .zero,
                cost: estimator.estimate(sessions: sessionsByDay[day] ?? [])
            )
        }
    }

    // MARK: Project breakdown

    /// Per-project totals, heaviest first by `TokenUsage.total`, ties broken by
    /// name so the order is stable between refreshes.
    ///
    /// - Parameter since: keeps sessions that *started* at or after this instant,
    ///   matching `ClaudenceStore.projectTotals(since:)`. Nil covers everything.
    ///
    /// Built from the session rows rather than `projectTotals`, because the
    /// summary needs each session's model, start and last activity for cost,
    /// duration and recency, and mixing two aggregates would let the token total
    /// and the cost describe different sets of sessions.
    public func projectBreakdown(since: Date? = nil) -> [ProjectSummary] {
        // `allSessions(since:)` filters on last activity, which is never earlier
        // than the start, so this is a superset of the sessions wanted here.
        let candidates = store.allSessions(since: since)
        let sessions = since.map { cutoff in candidates.filter { $0.startedAt >= cutoff } } ?? candidates

        var grouped: [String: [AISession]] = [:]
        for session in sessions { grouped[session.projectName, default: []].append(session) }

        let summaries = grouped.map { name, sessions -> ProjectSummary in
            var usage = TokenUsage.zero
            var durations = 0.0
            var lastActivity: Date?
            for session in sessions {
                usage += session.usage
                durations += max(0, session.lastActivityAt.timeIntervalSince(session.startedAt))
                if lastActivity == nil || session.lastActivityAt > lastActivity! {
                    lastActivity = session.lastActivityAt
                }
            }
            return ProjectSummary(
                projectName: name,
                usage: usage,
                sessionCount: sessions.count,
                cost: estimator.estimate(sessions: sessions),
                lastActivity: lastActivity,
                averageSessionDuration: sessions.isEmpty ? 0 : durations / Double(sessions.count)
            )
        }

        return summaries.sorted {
            $0.usage.total == $1.usage.total
                ? $0.projectName < $1.projectName
                : $0.usage.total > $1.usage.total
        }
    }

    // MARK: Today

    /// Tokens recorded for today's local day, zero when there are none.
    public func todayTotal() -> TokenUsage {
        let day = ClaudenceStore.dayString(for: now(), calendar: calendar)
        return store.dailyTotals(days: 1)
            .filter { $0.day == day }
            .reduce(TokenUsage.zero) { $0 + $1.usage }
    }

    /// Estimated cost of today's sessions, with its unpriced portion.
    public func todayCost() -> CostEstimate {
        let day = ClaudenceStore.dayString(for: now(), calendar: calendar)
        let start = calendar.startOfDay(for: now())
        let sessions = store.allSessions(since: start)
            .filter { ClaudenceStore.dayString(for: $0.startedAt, calendar: calendar) == day }
        return estimator.estimate(sessions: sessions)
    }

    // MARK: Private

    /// Whether a read actually produced an answer.
    ///
    /// An empty result from a working store is data ("no sessions"); an empty
    /// result from a broken one is not. A store that was already degraded before
    /// the read still answers — it is running in memory, which is a real, if
    /// short-lived, database. A store that *became* degraded during the read
    /// swallowed a failure, and a store that is unavailable never ran the query
    /// at all: both mean the answer is missing, not zero.
    private static func answered(before: StoreHealth, after: StoreHealth) -> Bool {
        if case .unavailable = after { return false }
        if case .healthy = before, case .degraded = after { return false }
        return true
    }
}
