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
            .object(forKey: Preferences.subscriptionMonthlyPriceKey) as? Double,
        // The chart's axis labels name months, and a month is a word. Read the
        // same way and for the same reason as the price above: this adapter is
        // not a view, so it has no environment to take `\.appLanguage` from,
        // and it holds no `Preferences`. `.system` resolves fresh, so changing
        // the machine's language while the app runs reaches the next refresh.
        language: AppLanguage = LanguagePreference.stored().resolved()
    ) {
        guard let analytics else {
            dashboard = DashboardData(
                windows: usageState.windows,
                usageUnavailableReason: usageUnavailableReason,
                sessions: sessions,
                tokenScaleMaximum: tokenScaleMaximum,
                burnRates: burnSamples(),
                seriesUnavailableReason: Self.historyNotRecordedReason,
                // No store at all, so the monthly table has nothing to read
                // either -- the same reasoning one line above, stated for the
                // table instead of the chart.
                monthlyUsageUnavailableReason: Self.historyNotRecordedReason,
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

        // The monthly table (9.13) is history end to end, so live-only mode
        // skips asking for it, the same reasoning `projectsCard` and
        // `historyCard` already get above `stored` and `points`. Nil rather
        // than an empty report distinguishes "did not ask" and "asked and the
        // store did not answer" from "asked and there is nothing recorded",
        // which only the last of the three renders as a true empty table.
        let monthly = isLiveOnly ? nil : monthlyUsage(now: now)

        dashboard = DashboardData(
            windows: usageState.windows,
            usageUnavailableReason: usageUnavailableReason,
            sessions: sessions,
            tokenScaleMaximum: tokenScaleMaximum,
            burnRates: burnSamples(),
            series: points.map { Self.chartPoint($0, in: language) },
            seriesOutput: Self.seriesOutput(points),
            seriesUnavailableReason: isLiveOnly
                ? nil
                : (points.isEmpty ? Self.noHistoryRecordedReason : nil),
            hourlySeries: hourly.map(Self.hourlyPoint),
            hourlySeriesOutput: Self.hourlyOutput(hourly),
            hourlySeriesUnavailableReason: isLiveOnly
                ? nil
                : (hourly.contains(where: \.isAvailable) ? nil : Self.noUsageSampledReason),
            projects: summaries.map(Self.projectRow),
            history: isLiveOnly ? [] : Self.history(live: sessions, stored: stored),
            monthlyUsage: monthly?.rows ?? [],
            monthlyUsageIncludesSubagentTokens: monthly?.includesSubagentTokens ?? true,
            monthlyUsageUnavailableReason: isLiveOnly
                ? nil
                : (monthly == nil ? Self.storeDidNotAnswerReason : nil),
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

    /// Live-only mode keeps no store, so the daily chart and the monthly table
    /// have nothing to read; both name the same reason.
    private static let historyNotRecordedReason = Phrase(
        en: "History is not being recorded",
        th: "ไม่ได้บันทึกประวัติการใช้งาน"
    )

    /// A store exists, but the daily series came back empty.
    private static let noHistoryRecordedReason = Phrase(
        en: "No history recorded yet",
        th: "ยังไม่มีประวัติการใช้งานที่บันทึกไว้"
    )

    /// The five-hour window's own hourly series has no sample in it.
    private static let noUsageSampledReason = Phrase(
        en: "No usage sampled in this window",
        th: "ยังไม่มีข้อมูลการใช้งานที่สุ่มตัวอย่างในหน้าต่างนี้"
    )

    /// `unansweredQueriesReader` said the monthly read did not complete.
    private static let storeDidNotAnswerReason = Phrase(
        en: "The store could not answer for this range",
        th: "ฐานข้อมูลไม่สามารถตอบคำถามสำหรับช่วงเวลานี้ได้"
    )

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
    ///
    /// The clock convention stays the machine's, not the chosen language's: a
    /// 24-hour label on a machine set to 12-hour reads as a different time of
    /// day, not as a style choice. This is the same split `Format.resetStamp`
    /// makes -- the month name is a word and follows the language, the clock
    /// is a convention and follows the system.
    private static let hourLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter
    }()

    private static func hourLabel(_ date: Date) -> String {
        hourLabelFormatter.string(from: date)
    }

    /// A day the store could not answer for becomes a gap, never a zero. A day
    /// with no work is a real zero and is drawn on the baseline.
    private static func chartPoint(_ point: DailyPoint, in language: AppLanguage) -> ChartPoint {
        guard let usage = point.usage else {
            return ChartPoint.missing(id: point.day, label: Self.chartLabel(point.date, in: language))
        }
        return ChartPoint(
            id: point.day,
            label: Self.chartLabel(point.date, in: language),
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

    /// One formatter per language, each built once. A `DateFormatter` per
    /// point allocated one per day of the series and re-ran locale lookup each
    /// time, for a label that never varies.
    ///
    /// A month is a word, so it follows the chosen language rather than the
    /// machine's. The calendar is pinned to `AppLanguage.calendar`, which is
    /// Gregorian in both: `th_TH` otherwise supplies the Buddhist calendar and
    /// a chart's axis would date this year 2569.
    private static let chartLabelFormatters: [AppLanguage: DateFormatter] = {
        var built: [AppLanguage: DateFormatter] = [:]
        for language in AppLanguage.allCases {
            let formatter = DateFormatter()
            formatter.locale = language.locale
            formatter.calendar = language.calendar
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
            built[language] = formatter
        }
        return built
    }()

    private static func chartLabel(_ date: Date, in language: AppLanguage) -> String {
        chartLabelFormatters[language]?.string(from: date) ?? ""
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

    // MARK: Monthly table (9.13)

    /// The monthly table's own range. "A month" is approximated as the
    /// trailing 30 days, the same lookback `historyWindow` already uses for
    /// the widest history filter, rather than the calendar month: a calendar
    /// month boundary would make the table's row count jump on the 1st for a
    /// reason that has nothing to do with usage.
    private static let monthlyLookback: TimeInterval = 30 * 24 * 60 * 60

    /// Prices a project's per-model split. `AnalyticsService`'s own estimator
    /// is private to it, and this reads no session list to ask
    /// `CostEstimator.estimate(sessions:)` for one, so this constructs its
    /// own against the same default table (`ModelPricing.current`)
    /// `Composition.makeServices()` hands `AnalyticsService`, rather than
    /// duplicating the pricing arithmetic itself: `CostEstimator` still owns
    /// every dollar figure this file prints.
    private static let monthlyCostEstimator = CostEstimator()

    /// Which of the table's three buckets a model string belongs in. Matches
    /// on substring rather than the price table's snapshot-exact key, because
    /// the table's job is a family comparison ("Opus versus Sonnet"), not a
    /// priced lookup -- a project that ran three different Sonnet snapshots
    /// in a month is one Sonnet bar, not three slivers too thin to read.
    private enum ModelFamily {
        case opus, sonnet, other

        static func of(_ model: String) -> ModelFamily {
            let lowered = model.lowercased()
            if lowered.contains("opus") { return .opus }
            if lowered.contains("sonnet") { return .sonnet }
            return .other
        }
    }

    /// Reads the store's monthly per-project totals, bracketed by
    /// `unansweredQueriesReader` exactly the way every method inside
    /// `AnalyticsService` already brackets its own store reads (see
    /// `AnalyticsService.dailySeries`, for one): a count taken before and
    /// after the read that does not match means the store did not actually
    /// answer, so this returns nil and the table renders `Usage unavailable`
    /// rather than whatever partial rows came back.
    ///
    /// Nil also whenever the composition root wired no reader at all --
    /// previews and tests that construct `MonitorViewModel` with none.
    private func monthlyUsage(now: Date) -> (rows: [MonthlyProjectRow], includesSubagentTokens: Bool)? {
        guard let monthlyTotalsReader, let unansweredQueriesReader else { return nil }
        let before = unansweredQueriesReader()
        let report = monthlyTotalsReader(now.addingTimeInterval(-Self.monthlyLookback))
        guard unansweredQueriesReader() == before else { return nil }
        // "Twelve rows" (spec 9.13): `MonthlyUsageReport.rows` documents that
        // this truncation is the caller's job, and this is the caller.
        return (report.rows.prefix(12).map(Self.monthlyRow), report.includesSubagentTokens)
    }

    /// One store row remapped to the dashboard's own vocabulary: the three
    /// model shares summed directly from `usageByModel` rather than derived
    /// by subtraction, and the API-equivalent dollar figure summed model by
    /// model so a model missing from the price table does not zero out the
    /// ones that are in it.
    private static func monthlyRow(_ project: ClaudenceStore.MonthlyProjectUsage) -> MonthlyProjectRow {
        let total = Double(project.usage.total)
        var opusTokens = 0
        var sonnetTokens = 0
        var otherTokens = 0
        var dollars = 0.0
        var pricedAnyModel = false

        for (model, usage) in project.usageByModel {
            switch ModelFamily.of(model) {
            case .opus: opusTokens += usage.total
            case .sonnet: sonnetTokens += usage.total
            case .other: otherTokens += usage.total
            }
            if let priced = monthlyCostEstimator.estimate(usage: usage, model: model) {
                dollars += priced
                pricedAnyModel = true
            }
        }

        return MonthlyProjectRow(
            project: project.projectName,
            sessionCount: project.sessionCount,
            usage: project.usage,
            opusShare: total > 0 ? Double(opusTokens) / total : 0,
            sonnetShare: total > 0 ? Double(sonnetTokens) / total : 0,
            otherShare: total > 0 ? Double(otherTokens) / total : 0,
            // Nil only when nothing at all could be priced, the same rule
            // `CostEstimate.estimatedDollars` follows: a project with one
            // unpriced model among three priced ones still gets a figure,
            // and it is a lower bound rather than a lie about being unknown.
            apiEquivalent: pricedAnyModel ? dollars : nil
        )
    }

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
