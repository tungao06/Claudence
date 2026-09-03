import Foundation
import ClaudenceCore

/// Maps the analytics core onto the dashboard's own value types.
///
/// The dashboard deliberately does not import the analytics types: it renders
/// plain data, so a change to how a figure is computed cannot reach into a view.
/// This file is the seam, and it is the only place the two vocabularies meet.
@MainActor
extension MonitorViewModel {
    /// Rebuilds the dashboard aggregates. Reads the database, so it is called
    /// when the dashboard opens and on an explicit refresh, never on a snapshot.
    /// Seven days, because that is the window the design's chart draws and the
    /// one its title names. Fourteen was carried over from before the chart had
    /// a title: on a machine with a week of history it drew seven empty columns
    /// beside the real ones, which reads as seven days of zero rather than as
    /// seven days of nothing recorded.
    func refreshDashboard(
        days: Int = 7,
        now: Date = Date(),
        // Read fresh on every call rather than cached, the same reasoning
        // `usageRefreshInterval`'s own doc block gives for reading its
        // preference on every pass: a price typed into Settings should reach
        // the tile at the next refresh, not at the next launch.
        //
        // Read directly from `UserDefaults` rather than threaded through
        // `MonitorViewModel`, unlike `usageRefreshInterval` and `isLiveOnly`:
        // this value never reaches the engine or a file, so there is no seam
        // for it to cross, and `MonitorViewModel` holds no reference to
        // `Preferences` to read it from. `Preferences.subscriptionMonthlyPriceKey`
        // names the one key this shares with it, so the string is defined
        // once even though it is read from two places.
        subscriptionMonthlyPrice: Double? = UserDefaults.standard
            .object(forKey: Preferences.subscriptionMonthlyPriceKey) as? Double
    ) {
        guard let analytics else {
            dashboard = DashboardData(
                windows: usageState.windows,
                usageUnavailableReason: usageUnavailableReason,
                sessions: sessions,
                tokenScaleMaximum: tokenScaleMaximum,
                burnRates: burnSamples(),
                seriesUnavailableReason: "History is not being recorded",
                todayUsage: nil,
                // The projection, the binding window and the burn leader all
                // come from the usage endpoint and the in-process burn
                // trackers, neither of which needs a database. A store this
                // application cannot open is a reason to withhold history, not
                // a reason to withhold these. The account plan and the
                // subscription price are the same: neither reads the store.
                projections: usageProjections(now: now),
                bindingWindowName: bindingWindow(now: now)?.window.name,
                burnLeader: burnLeaderInfo(),
                accountPlanDisplayName: accountPlan?.displayName,
                subscriptionMonthlyPrice: subscriptionMonthlyPrice
            )
            return
        }

        // Live-only mode keeps the store in memory, so `today` figures below
        // this line still answer honestly for the life of the process. What
        // the four calls guarded here have in common is that every one of them
        // feeds a surface `DashboardView` hides outright in that mode -- the
        // daily and hourly charts, the project totals card, the history table,
        // and the stat strip's day-over-day delta -- so none of them are asked
        // for. See `EnvironmentValues.liveOnlyMode`.
        let points = isLiveOnly ? [] : analytics.dailySeries(days: days)
        let summaries = isLiveOnly ? [] : analytics.projectBreakdown()
        let todayCost = isLiveOnly ? nil : analytics.todayCost()
        // The history table offers Today, 7 days and 30 days, so it is given
        // thirty days of stored sessions and filters within them. Passing only
        // the live set, which is what this did until the ranges were audited,
        // left all three ranges holding the same handful of rows: a session
        // that ends leaves the registry, and the table is about the ones that
        // ended.
        let stored: [AISession] = isLiveOnly
            ? []
            : (analytics.recentSessions(since: now.addingTimeInterval(-Self.historyWindow)) ?? [])

        // The five-hour window's own range, so the hourly chart covers the
        // block the meter is measuring rather than an arbitrary five hours
        // ending now. `resetsAt` is where that block ends; without it the
        // trailing five hours is the honest approximation and the only one
        // available.
        let fiveHour = usageState.windows.first { $0.name == DashboardData.WindowKey.fiveHour }
        let hourly: [HourPoint] = isLiveOnly
            ? []
            : analytics.hourlySeries(in: AnalyticsService.fiveHourRange(resetsAt: fiveHour?.resetsAt, now: now))

        dashboard = DashboardData(
            windows: usageState.windows,
            usageUnavailableReason: usageUnavailableReason,
            sessions: sessions,
            tokenScaleMaximum: tokenScaleMaximum,
            burnRates: burnSamples(),
            series: points.map(Self.chartPoint),
            seriesOutput: Self.seriesOutput(points),
            seriesUnavailableReason: isLiveOnly ? nil : (points.isEmpty ? "No history recorded yet" : nil),
            hourlySeries: hourly.map(Self.hourlyPoint),
            hourlySeriesOutput: Self.hourlyOutput(hourly),
            hourlySeriesUnavailableReason: isLiveOnly
                ? nil
                : (hourly.contains(where: \.isAvailable) ? nil : "No usage sampled in this window"),
            projects: summaries.map(Self.projectRow),
            history: isLiveOnly ? [] : Self.history(live: sessions, stored: stored),
            // Nil when the store could not answer, so the tile renders
            // `Usage unavailable`. This passed a non-nil value on every path
            // until 2026-09-03, which made `todayUsage`'s optionality
            // unreachable and printed a failed read as a zero.
            //
            // Nil in live-only mode, and the two surfaces that read it, the
            // token breakdown card and the popover's Today strip, are hidden
            // rather than shown as unavailable. The figure comes from
            // `daily_rollups`, so in that mode it would cover the rows written
            // since launch and print them under the word Today: a real number
            // under a false label, which is the shape of fabrication this
            // codebase refuses even when every digit is arithmetically sound.
            todayUsage: isLiveOnly ? nil : analytics.todayTotal(),
            todayCost: todayCost?.estimatedDollars,
            unpricedSessionCount: todayCost?.unpricedSessions ?? 0,
            // `sessionsActiveToday()` was passed here and printed as the
            // Active-sessions tile's denominator, against a numerator counted
            // off the live registry. Two different sets, so the tile could and
            // did print `2 / 1 today`. The tile divides the live set by itself
            // now; the sessions-that-ran-today count is the history table's
            // Today range, which reads the same rows.
            todayVersusYesterday: isLiveOnly ? nil : analytics.dayOverDay()?.fractionalChange,
            priceTableStaleDays: Self.priceTableStaleDays(analytics.priceProvenance, now: now),
            projections: usageProjections(now: now),
            bindingWindowName: bindingWindow(now: now)?.window.name,
            burnLeader: burnLeaderInfo(),
            accountPlanDisplayName: accountPlan?.displayName,
            subscriptionMonthlyPrice: subscriptionMonthlyPrice
        )
    }

    /// One projection per currently reported usage window (9.11), read
    /// through `projection(for:now:)` rather than computed here: the arithmetic
    /// lives in `UsageProjector` and this file only maps it onto the window
    /// keys `DashboardData` renders by.
    private func usageProjections(now: Date) -> [String: UsageProjection] {
        var result: [String: UsageProjection] = [:]
        for window in usageState.windows {
            result[window.name] = projection(for: window, now: now)
        }
        return result
    }

    /// The burn leader as the dashboard wants it: the session's own display
    /// name attached, the same name the sessions list and history table use.
    /// A session that has since left the live set (finished, or the process
    /// exited) still has a share until its rate decays out of the tracker; the
    /// name then falls back to the session id rather than disappearing, since
    /// the id is at least honest about which session it was.
    private func burnLeaderInfo() -> BurnLeaderInfo? {
        guard let leader = burnLeader else { return nil }
        let name = sessions.first { $0.id == leader.sessionID }?.projectName ?? leader.sessionID
        return BurnLeaderInfo(sessionID: leader.sessionID, displayName: name, share: leader.share)
    }

    private func burnSamples() -> [String: BurnSample] {
        var result: [String: BurnSample] = [:]
        for session in sessions {
            let rate = burnRate(for: session)
            result[session.id] = BurnSample(
                tokensPerMinute: rate.tokensPerMinute > 0 ? rate.tokensPerMinute : nil,
                samples: rate.samples
            )
        }
        return result
    }

    /// Same rule as the daily points: an hour with no measurement is a gap and
    /// is drawn as one, never as a zero column.
    private static func hourlyPoint(_ point: HourPoint) -> ChartPoint {
        guard let usage = point.usage else {
            return ChartPoint.missing(id: point.hour, label: Self.hourLabel(point.date))
        }
        return ChartPoint(
            id: point.hour,
            label: Self.hourLabel(point.date),
            value: Double(usage.total)
        )
    }

    private static func hourlyOutput(_ points: [HourPoint]) -> [String: Double] {
        var result: [String: Double] = [:]
        for point in points {
            guard let usage = point.usage else { continue }
            result[point.hour] = Double(usage.output)
        }
        return result
    }

    /// Built once, for the same reason `chartLabelFormatter` is.
    private static let hourLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        // The user's own clock convention. A 24-hour label on a machine set to
        // 12-hour reads as a different time of day, not as a style choice.
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter
    }()

    private static func hourLabel(_ date: Date) -> String {
        hourLabelFormatter.string(from: date)
    }

    /// A day the store could not answer for becomes a gap, never a zero. A day
    /// with no work is a real zero and is drawn on the baseline.
    private static func chartPoint(_ point: DailyPoint) -> ChartPoint {
        guard let usage = point.usage else {
            return ChartPoint.missing(id: point.day, label: Self.chartLabel(point.date))
        }
        return ChartPoint(
            id: point.day,
            label: Self.chartLabel(point.date),
            value: Double(usage.total)
        )
    }

    /// The output half of each day, keyed the same way the chart keys its
    /// points. A day the store could not answer for contributes no entry, which
    /// is what keeps a gap distinguishable from a day that produced no output.
    private static func seriesOutput(_ points: [DailyPoint]) -> [String: Double] {
        var result: [String: Double] = [:]
        for point in points {
            guard let usage = point.usage else { continue }
            result[point.day] = Double(usage.output)
        }
        return result
    }

    /// Built once. A `DateFormatter` per point allocated one per day of the
    /// series and re-ran locale lookup each time, for a label that never varies.
    private static let chartLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private static func chartLabel(_ date: Date) -> String {
        chartLabelFormatter.string(from: date)
    }

    private static func projectRow(_ summary: ProjectSummary) -> ProjectRow {
        ProjectRow(
            project: summary.projectName,
            usage: summary.usage,
            sessionCount: summary.sessionCount,
            estimatedCost: summary.cost.estimatedDollars,
            lastActivity: summary.lastActivity,
            averageDuration: summary.sessionCount > 0 ? summary.averageSessionDuration : nil
        )
    }

    /// How far back the history table is given rows for: its widest filter.
    private static let historyWindow: TimeInterval = 30 * 24 * 60 * 60

    /// The age of the price table, in whole days, and only once it is stale.
    ///
    /// Nil while the rates are current, so the cost caption says nothing rather
    /// than reporting a number that carries no warning.
    private static func priceTableStaleDays(
        _ provenance: PriceTableProvenance,
        now: Date
    ) -> Int? {
        guard provenance.isStale(asOf: now) else { return nil }
        return Int(provenance.age(asOf: now) / 86_400)
    }

    /// The history table's rows: every session seen in the window, live ones
    /// included.
    ///
    /// A session in both sets is taken from the live one. The two rows describe
    /// the same session, but the live one carries the tokens counted since the
    /// last write to the store, and showing the smaller figure beside the same
    /// session in the list above it would read as a bug in one of the two.
    private static func history(live: [AISession], stored: [AISession]) -> [HistoryRow] {
        var byID: [String: AISession] = [:]
        for session in stored { byID[session.id] = session }
        for session in live { byID[session.id] = session }

        return byID.values
            .sorted { $0.startedAt > $1.startedAt }
            .map { session in
                HistoryRow(
                    id: session.id,
                    project: session.projectName,
                    startedAt: session.startedAt,
                    duration: max(0, session.lastActivityAt.timeIntervalSince(session.startedAt)),
                    // The same definition the session list and the token scale
                    // use. Parent-only here put two different totals for one
                    // session on the same screen, differing by the subagent
                    // share, which is 41% on this repository.
                    usage: session.combinedUsage,
                    model: session.model,
                    // Carried rather than derived from the duration, because it
                    // is what the table's Today, 7 days and 30 days ranges
                    // filter on: a session belongs to the day it did work, not
                    // to the day it opened.
                    lastActivityAt: session.lastActivityAt
                )
            }
    }
}
