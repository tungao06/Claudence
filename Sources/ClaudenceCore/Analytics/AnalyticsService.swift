import Foundation

// MARK: - View-ready aggregates

/// One hour of the hourly series.
///
/// The five-hour usage window is shorter than a single column of the daily
/// chart, so a daily series cannot say anything about it: the whole window
/// lives inside one bar. This is the finer grain that can.
///
/// `usage` is optional for the same reason `DailyPoint`'s is, and the rule for
/// which it is differs from the daily one because the source differs. Days come
/// from rollups, which exist for every day the application has ever recorded,
/// so a missing day is a store failure. Hours come from samples, which exist
/// only while Claudence is running and a session is active, so an hour with no
/// sample is a *gap*: the application cannot tell an hour in which nothing
/// happened from an hour in which it was not there to watch. Rendering that as
/// a zero would be inventing a measurement, which this project does not do.
public struct HourPoint: Sendable, Equatable, Identifiable {
    /// Bucket key, "YYYY-MM-DD HH" in local time.
    public let hour: String
    /// Start of that local hour.
    public let date: Date
    /// Measured tokens, or nil when no sample covers the hour.
    public let usage: TokenUsage?

    public var id: String { hour }

    public var isAvailable: Bool { usage != nil }

    public init(hour: String, date: Date, usage: TokenUsage?) {
        self.hour = hour
        self.date = date
        self.usage = usage
    }
}

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

    /// The span the five-hour meter is measuring.
    ///
    /// Ends at the reset, or at now while the reset is still ahead: drawing
    /// hours that have not happened yet would put empty columns after the live
    /// one and read as five hours of silence rather than as the future.
    ///
    /// Here rather than in the dashboard adapter because it is a fact about the
    /// window, not about how a chart draws it, and because the adapter is in the
    /// application target and nothing there can be tested.
    public static func fiveHourRange(resetsAt: Date?, now: Date) -> Range<Date> {
        let end = resetsAt.map { min($0, now) } ?? now
        let start = end.addingTimeInterval(-fiveHourWindowLength)
        // A clock that moved backwards, or a reset already five hours behind,
        // would otherwise produce a range the store reads as empty in a way
        // that looks like missing data rather than like a bad range.
        guard start < end else {
            return now.addingTimeInterval(-fiveHourWindowLength)..<now
        }
        return start..<end
    }

    private static let fiveHourWindowLength: TimeInterval = 5 * 60 * 60

    /// Tokens hour by hour across `range`, oldest first.
    ///
    /// Built by differentiating `usage_samples`, which hold each session's
    /// running total. A sample's rise above the highest total that session has
    /// reached is attributed to the hour the *later* sample falls in: that is
    /// where the tokens were observed, and splitting a delta across the
    /// boundary it may straddle would be a guess about when inside the interval
    /// the work happened. The comparison is against that high-water mark rather
    /// than against the previous sample because the samples are not monotonic.
    ///
    /// The first sample a session ever has is a special case with two wrong
    /// answers available. Counting its whole total puts every token the session
    /// spent before Claudence started watching into one hour, which draws a
    /// spike that never happened; discarding it loses everything the session
    /// spent before its second sample, which for a short session is nearly all
    /// of it. It is counted only when the session also *started* inside the
    /// range, which is the case where the total genuinely belongs to the range
    /// and to no earlier hour.
    ///
    /// An hour no sample falls in has no measurement rather than a zero. See
    /// `HourPoint`.
    public func hourlySeries(in range: Range<Date>) -> [HourPoint] {
        let starts = Self.hourStarts(in: range, calendar: calendar)
        guard !starts.isEmpty else { return [] }

        let before = store.health
        let rows = store.usageSamples(in: range)
        let sessions = store.allSessions(since: range.lowerBound)
        guard Self.answered(before: before, after: store.health) else {
            return starts.map {
                HourPoint(hour: Self.hourString(for: $0, calendar: calendar), date: $0, usage: nil)
            }
        }

        // A session that began inside the range is the one case where a first
        // sample carries no history from before it.
        let startedInRange = Set(
            sessions.filter { range.contains($0.startedAt) }.map(\.id)
        )

        var measured: [String: TokenUsage] = [:]
        // The highest running total each session has reached, not merely the
        // sample before this one. `usage_samples` is not monotonic, and against
        // the previous sample alone every token between the floor of a
        // regression and the level it fell from is drawn a second time on the
        // way back up.
        var peak: [String: TokenUsage] = [:]
        for row in rows {
            let mark = peak[row.sessionID]
            peak[row.sessionID] = Self.higher(mark ?? .zero, row.usage)

            let delta: TokenUsage
            if let mark {
                delta = Self.increase(from: mark, to: row.usage)
            } else if startedInRange.contains(row.sessionID) {
                delta = row.usage
            } else {
                // The baseline row, or a session whose history predates the
                // range. Either way it establishes a floor and contributes
                // nothing of its own.
                continue
            }

            // The baseline row sits before the range and must not open a bucket
            // of its own even when it is also a session's first sample.
            guard range.contains(row.sampledAt) else { continue }
            let key = Self.hourString(for: row.sampledAt, calendar: calendar)
            measured[key, default: .zero] += delta
        }

        return starts.map { start in
            let key = Self.hourString(for: start, calendar: calendar)
            return HourPoint(hour: key, date: start, usage: measured[key])
        }
    }

    /// Every hour start the range touches, oldest first. A range that begins
    /// mid-hour still yields that hour: the tokens in it were spent inside the
    /// window even though the bucket is wider than the window's edge.
    static func hourStarts(in range: Range<Date>, calendar: Calendar) -> [Date] {
        guard range.lowerBound < range.upperBound else { return [] }
        guard var cursor = calendar.dateInterval(of: .hour, for: range.lowerBound)?.start else {
            return []
        }
        var result: [Date] = []
        // Bounded, so a malformed range or a calendar that refuses to advance
        // cannot spin here. A week of hours is well past anything this draws.
        while cursor < range.upperBound, result.count < 24 * 7 {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    static func hourString(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(
            format: "%04d-%02d-%02d %02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0
        )
    }

    /// The rise of a running total above the highest it has already reached,
    /// floored at zero per field.
    ///
    /// Totals only ever climb while a session lives, so a fall means the
    /// session's transcript was rotated or its cursor reset. Nothing is lost
    /// when that happens: the tokens below the mark were drawn when they were
    /// first observed. What the floor prevents is the opposite failure, of
    /// drawing them again as the counter climbs back to where it was, which is
    /// what measuring against the previous sample did. A negative bar would be
    /// a second, louder wrong answer.
    private static func increase(from earlier: TokenUsage, to later: TokenUsage) -> TokenUsage {
        TokenUsage(
            freshInput: max(0, later.freshInput - earlier.freshInput),
            cacheCreation: max(0, later.cacheCreation - earlier.cacheCreation),
            cacheRead: max(0, later.cacheRead - earlier.cacheRead),
            output: max(0, later.output - earlier.output),
            thinking: max(0, later.thinking - earlier.thinking)
        )
    }

    /// The per-field maximum of two running totals.
    ///
    /// Per field rather than per total, because each field is its own
    /// cumulative counter and none of them can legitimately fall. Holding one
    /// mark against `total` would make a regression in any single field
    /// suppress the fields that kept climbing through it, and there would be no
    /// honest way to split a recovered total back across a breakdown the chart
    /// shows cache separately in.
    private static func higher(_ lhs: TokenUsage, _ rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            freshInput: max(lhs.freshInput, rhs.freshInput),
            cacheCreation: max(lhs.cacheCreation, rhs.cacheCreation),
            cacheRead: max(lhs.cacheRead, rhs.cacheRead),
            output: max(lhs.output, rhs.output),
            thinking: max(lhs.thinking, rhs.thinking)
        )
    }

    // MARK: Project breakdown

    /// Per-project totals, heaviest first by `TokenUsage.total`, ties broken by
    /// name so the order is stable between refreshes.
    ///
    /// - Parameter since: keeps sessions that *started* at or after this instant,
    ///   matching `ClaudenceStore.projectTotals(since:)`. Nil covers everything.
    ///
    /// Built from the session rows, because the summary needs each session's
    /// model, start and last activity for cost, duration and recency, and
    /// mixing two aggregates would let the token total and the cost describe
    /// different sets of sessions.
    ///
    /// **Combined usage, not parent-only.** This summed `session.usage` until
    /// 2026-09-03, while the cost on the same row went through
    /// `CostEstimator`, which prices `combinedUsage`. The tokens cell therefore
    /// excluded subagents and the cost cell beside it included them. Measured
    /// on the live database: `claudence-99` rendered 149.8 M tokens against a
    /// true 484.0 M, understated 3.2x, and was drawn second in a table it
    /// should have led. Every other aggregate in the codebase -- the rollups,
    /// the sessions table, the recent-share figure, the usage samples -- uses
    /// the combined figure, and subagent share on this machine ranges from 0%
    /// to 82% by project, so the error was not a constant factor but a
    /// different one on every row.
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
                usage += session.combinedUsage
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

    /// How many sessions were active at any point today, or nil when the store
    /// could not answer.
    ///
    /// This is the denominator the dashboard's Active-sessions tile prints as
    /// `2 / 4 today`, and it is deliberately not a count of sessions that
    /// *started* today: a session opened last night and still running is part of
    /// today, and bucketing it by start date would print a denominator smaller
    /// than the live count sitting next to it. `allSessions(since:)` filters on
    /// last activity, which is the definition that makes the pair legible.
    ///
    /// Nil rather than zero when the store failed: an empty answer from a
    /// working store is "no sessions", and the tile prints the numerator with no
    /// denominator rather than claiming a day with none.
    public func sessionsActiveToday() -> Int? {
        let before = store.health
        let sessions = store.allSessions(since: calendar.startOfDay(for: now()))
        guard Self.answered(before: before, after: store.health) else { return nil }
        return sessions.count
    }

    /// Sessions that did something at or after `since`, newest activity first,
    /// or nil when the store could not answer.
    ///
    /// The session history table is built from this rather than from the live
    /// set. Live sessions alone made the table's Today / 7 days / 30 days filter
    /// inert: every range held the same handful of rows, because a session that
    /// ended left the registry and therefore left the table.
    public func recentSessions(since: Date) -> [AISession]? {
        let before = store.health
        let sessions = store.allSessions(since: since)
        guard Self.answered(before: before, after: store.health) else { return nil }
        return sessions
    }

    // MARK: Day over day

    /// Today's tokens against yesterday's, or nil when the store could not
    /// answer.
    ///
    /// Nil and a zero delta are different claims and the caller must render them
    /// differently. Nil means "no comparison available"; a delta whose
    /// `fractionalChange` is nil means "yesterday recorded nothing, so there is
    /// nothing to compare against"; a delta of 0 means the two days genuinely
    /// matched.
    ///
    /// Reads `dailyTotals(days: 2)`, whose window the store measures from the
    /// real clock. As with `dailySeries`, an injected `now` far from the real
    /// clock puts the two windows out of alignment and the day keys stop
    /// matching; tests pin `now` to `Date()` for that reason.
    public func dayOverDay() -> DayOverDayDelta? {
        let today = calendar.startOfDay(for: now())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }

        let todayKey = ClaudenceStore.dayString(for: today, calendar: calendar)
        let yesterdayKey = ClaudenceStore.dayString(for: yesterday, calendar: calendar)

        let before = store.health
        let totals = store.dailyTotals(days: 2)
        guard Self.answered(before: before, after: store.health) else { return nil }

        var byDay: [String: TokenUsage] = [:]
        for row in totals { byDay[row.day, default: .zero] += row.usage }

        return DayOverDayDelta(
            today: byDay[todayKey] ?? .zero,
            yesterday: byDay[yesterdayKey] ?? .zero
        )
    }

    // MARK: Share of recent activity

    /// The window `shareOfRecentTokens` uses unless told otherwise: five hours,
    /// matching the cadence of the provider's shortest usage window purely so
    /// the two sit on the same time scale on screen. It is not a share of that
    /// window and cannot be converted into one. See `RecentTokenShares`.
    public static let recentActivityWindow: TimeInterval = 5 * 60 * 60

    /// How the sessions active in the last `window` divide up the tokens
    /// Claudence measured in that period, or nil when the store could not
    /// answer.
    ///
    /// The denominator is local and measured, never the provider's window
    /// capacity, which is not a number this application is given. The reasoning
    /// is written out on `RecentTokenShares`, and the name of every member here
    /// says "recent tokens" rather than "window" so the two cannot be confused
    /// at a call site.
    ///
    /// Sessions come from `allSessions(since:)`, which filters on last activity,
    /// so "active in the window" means the session did something in it. A
    /// long-running session that has been quiet for six hours is correctly
    /// absent, and its earlier tokens are not in the denominator either.
    public func shareOfRecentTokens(
        window: TimeInterval = AnalyticsService.recentActivityWindow
    ) -> RecentTokenShares? {
        let until = now()
        let since = until.addingTimeInterval(-max(0, window))

        let before = store.health
        let sessions = store.allSessions(since: since)
        guard Self.answered(before: before, after: store.health) else { return nil }

        var measured = TokenUsage.zero
        for session in sessions { measured += session.combinedUsage }
        let denominator = measured.total

        let shares = sessions.map { session in
            SessionTokenShare(
                sessionID: session.id,
                projectName: session.projectName,
                usage: session.combinedUsage,
                share: denominator > 0
                    ? Double(session.combinedUsage.total) / Double(denominator)
                    : nil
            )
        }.sorted {
            $0.usage.total == $1.usage.total
                ? $0.sessionID < $1.sessionID
                : $0.usage.total > $1.usage.total
        }

        return RecentTokenShares(
            window: window,
            since: since,
            until: until,
            measuredTotal: measured,
            sessions: shares
        )
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
