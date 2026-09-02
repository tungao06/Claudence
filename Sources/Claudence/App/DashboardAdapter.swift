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
    func refreshDashboard(days: Int = 14, now: Date = Date()) {
        guard let analytics else {
            dashboard = DashboardData(
                windows: usageState.windows,
                usageUnavailableReason: usageUnavailableReason,
                sessions: sessions,
                tokenScaleMaximum: tokenScaleMaximum,
                burnRates: burnSamples(),
                seriesUnavailableReason: "History is not being recorded",
                todayUsage: nil
            )
            return
        }

        let points = analytics.dailySeries(days: days)
        let summaries = analytics.projectBreakdown()
        let todayCost = analytics.todayCost()

        dashboard = DashboardData(
            windows: usageState.windows,
            usageUnavailableReason: usageUnavailableReason,
            sessions: sessions,
            tokenScaleMaximum: tokenScaleMaximum,
            burnRates: burnSamples(),
            series: points.map(Self.chartPoint),
            seriesOutput: Self.seriesOutput(points),
            seriesUnavailableReason: points.isEmpty ? "No history recorded yet" : nil,
            projects: summaries.map(Self.projectRow),
            history: Self.history(from: sessions, now: now),
            todayUsage: analytics.todayTotal(),
            todayCost: todayCost.estimatedDollars,
            unpricedSessionCount: todayCost.unpricedSessions
        )
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

    /// History for the sessions currently known. Persisted history arrives with
    /// the store; until then this is honest about showing only the live set.
    private static func history(from sessions: [AISession], now: Date) -> [HistoryRow] {
        sessions
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
                    model: session.model
                )
            }
    }
}
