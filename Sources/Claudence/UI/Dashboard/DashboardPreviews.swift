import SwiftUI
import ClaudenceCore

// MARK: - Dashboard fixtures
//
// Every mock value the dashboard uses lives here and nowhere else. No other
// dashboard file contains an invented number, name, path or date. Each fixture
// is named for the condition it exercises, so a reviewer can see what a preview
// is actually testing without reading the numbers.
//
// `#Preview` does not compile without Xcode on this machine, so these are
// `PreviewProvider` structs, matching `UI/Components/Previews.swift`.

private enum DashboardClock {
    static let minute: TimeInterval = 60
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400

    /// Fixed reference time for every preview, so relative labels such as
    /// "2h 14m ago" do not drift between renders.
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func ago(_ interval: TimeInterval) -> Date { now.addingTimeInterval(-interval) }
    static func ahead(_ interval: TimeInterval) -> Date { now.addingTimeInterval(interval) }
}

private enum DashboardPercent {
    static let healthy = 21.0
    static let attention = 66.0
    static let warning = 84.0
    static let critical = 96.0
}

private enum DashboardUsage {
    static let none = TokenUsage.zero

    static let small = TokenUsage(
        freshInput: 3_100,
        cacheCreation: 26_400,
        cacheRead: 31_900,
        output: 9_700,
        thinking: 820
    )

    static let medium = TokenUsage(
        freshInput: 12_800,
        cacheCreation: 164_000,
        cacheRead: 402_300,
        output: 53_100,
        thinking: 6_400
    )

    /// Past the million mark, so "M" formatting and column widths are both
    /// exercised in every table.
    static let enormous = TokenUsage(
        freshInput: 1_240_000,
        cacheCreation: 6_800_000,
        cacheRead: 24_310_000,
        output: 3_120_000,
        thinking: 470_000
    )

    static let smallScale = 200_000
    static let mediumScale = 1_000_000
    static let enormousScale = 40_000_000
}

private enum DashboardWindows {
    static let healthy: [UsageWindow] = [
        UsageWindow(
            name: DashboardData.WindowKey.fiveHour,
            usedPercent: DashboardPercent.healthy,
            resetsAt: DashboardClock.ahead(2 * DashboardClock.hour + 14 * DashboardClock.minute)
        ),
        UsageWindow(
            name: DashboardData.WindowKey.sevenDay,
            usedPercent: DashboardPercent.attention,
            resetsAt: DashboardClock.ahead(4 * DashboardClock.day)
        ),
        UsageWindow(
            name: DashboardData.WindowKey.modelScopedPrefix + "claude_opus_4_5",
            usedPercent: DashboardPercent.healthy,
            resetsAt: DashboardClock.ahead(4 * DashboardClock.day)
        ),
    ]

    static let critical: [UsageWindow] = [
        UsageWindow(
            name: DashboardData.WindowKey.fiveHour,
            usedPercent: DashboardPercent.critical,
            resetsAt: DashboardClock.ahead(11 * DashboardClock.minute)
        ),
        UsageWindow(
            name: DashboardData.WindowKey.sevenDay,
            usedPercent: DashboardPercent.warning,
            resetsAt: DashboardClock.ahead(2 * DashboardClock.day)
        ),
        UsageWindow(
            name: DashboardData.WindowKey.modelScopedPrefix + "claude_opus_4_5",
            usedPercent: DashboardPercent.critical,
            resetsAt: DashboardClock.ahead(2 * DashboardClock.day)
        ),
        UsageWindow(
            name: DashboardData.WindowKey.modelScopedPrefix + "claude_sonnet_5",
            usedPercent: DashboardPercent.attention,
            resetsAt: DashboardClock.ahead(2 * DashboardClock.day)
        ),
    ]

    /// The seven-day window is absent from the payload entirely. The bar must
    /// say so rather than assume zero.
    static let partial: [UsageWindow] = [
        UsageWindow(
            name: DashboardData.WindowKey.fiveHour,
            usedPercent: DashboardPercent.attention,
            resetsAt: DashboardClock.ahead(DashboardClock.hour)
        )
    ]
}

private enum DashboardPaths {
    static let short = "/Users/preview/code/claudence"
    /// Long enough to force head truncation in a 216 pt table column.
    static let veryLong =
        "/Users/preview/Development/clients/northwind/platform/services/"
        + "billing/apps/reconciliation-worker/packages/core-domain"
}

private enum DashboardSessions {
    private static func make(
        id: String,
        projectName: String,
        workingDirectory: String,
        status: SessionStatus,
        activity: Activity?,
        usage: TokenUsage,
        age: TimeInterval
    ) -> AISession {
        AISession(
            id: id,
            pid: 42_541,
            procStart: "Tue Sep  1 19:27:02 2026",
            projectName: projectName,
            workingDirectory: workingDirectory,
            status: status,
            currentActivity: activity,
            startedAt: DashboardClock.ago(age),
            lastActivityAt: DashboardClock.now,
            usage: usage,
            model: "claude-sonnet-5",
            claudeCodeVersion: "2.1.257"
        )
    }

    static let working = make(
        id: "dash-working",
        projectName: "claudence-06",
        workingDirectory: DashboardPaths.short,
        status: .running,
        activity: Activity(verb: "Editing", subject: "DashboardView.swift"),
        usage: DashboardUsage.small,
        age: 37 * DashboardClock.minute
    )

    static let idle = make(
        id: "dash-idle",
        projectName: "hr-leave-management-14",
        workingDirectory: DashboardPaths.short,
        status: .idle,
        activity: Activity(verb: "Running tests"),
        usage: DashboardUsage.medium,
        age: 6 * DashboardClock.hour
    )

    static let longPath = make(
        id: "dash-long-path",
        projectName: "reconciliation-worker-integration-suite",
        workingDirectory: DashboardPaths.veryLong,
        status: .running,
        activity: Activity(
            verb: "Editing",
            subject: "ReconciliationWorkerConfigurationBuilder+Defaults.swift"
        ),
        usage: DashboardUsage.medium,
        age: 2 * DashboardClock.hour
    )

    static let enormous = make(
        id: "dash-enormous",
        projectName: "monorepo-migration",
        workingDirectory: DashboardPaths.short,
        status: .running,
        activity: Activity(verb: "Searching codebase"),
        usage: DashboardUsage.enormous,
        age: 4 * DashboardClock.day
    )

    static let all: [AISession] = [working, idle, longPath, enormous]
    static let none: [AISession] = []

    static let burnRates: [String: BurnSample] = [
        working.id: BurnSample(
            tokensPerMinute: 12_400,
            samples: [1_200, 1_800, 1_500, 2_400, 3_100, 2_900, 4_200, 5_600]
        ),
        idle.id: BurnSample(
            tokensPerMinute: 240,
            samples: [8_100, 2_300, 9_400, 1_100, 7_700, 3_200, 9_900]
        ),
        longPath.id: BurnSample(tokensPerMinute: 3_050, samples: [3_000, 3_000, 3_000, 3_000]),
        // No key for `enormous`: an unmeasured burn rate is an ordinary state
        // and the row must say "Rate unavailable" rather than show a zero.
    ]
}

private enum DashboardSeries {
    /// Builds a series ending today. A nil entry is a bucket the store could
    /// not answer for, which must render as a gap and never as a zero.
    static func build(_ values: [Double?]) -> [ChartPoint] {
        let count = values.count
        return values.enumerated().map { offset, value in
            let date = DashboardClock.ago(Double(count - 1 - offset) * DashboardClock.day)
            let label = date.formatted(.dateTime.month(.abbreviated).day())
            let id = date.formatted(.iso8601.year().month().day())
            guard let value else { return ChartPoint.missing(id: id, label: label) }
            return ChartPoint(id: id, label: label, value: value, isMissing: false)
        }
    }

    /// Fourteen ordinary days, including two genuine zeroes (a weekend) that
    /// must sit on the floor of the chart, not break the line.
    static let healthy = build([
        420_000, 610_000, 580_000, 745_000, 690_000, 0, 0,
        820_000, 1_140_000, 960_000, 1_320_000, 1_080_000, 1_460_000, 1_210_000,
    ])

    /// The same fortnight with a three-day outage in the middle and a single
    /// isolated measured day between two gaps.
    static let withGap = build([
        420_000, 610_000, 580_000, nil, nil, nil, 690_000,
        nil, 1_140_000, 960_000, 0, 1_080_000, nil, 1_210_000,
    ])

    /// Millions per day: exercises "M" axis labels in a 46 pt gutter.
    static let enormous = build([
        18_400_000, 21_900_000, 24_310_000, 19_700_000, 26_800_000,
        22_150_000, 28_400_000,
    ])

    /// Measured, and every day is zero. A real answer, drawn on the floor.
    static let allZero = build([0, 0, 0, 0, 0, 0, 0])

    /// The store answered for nothing. Must render `UnavailableView`, not axes.
    static let allMissing = build([nil, nil, nil, nil, nil])

    static let empty: [ChartPoint] = []

    /// One measured day. Too little for a line; must still be visible.
    static let single = build([740_000])
}

private enum DashboardProjects {
    static let healthy: [ProjectRow] = [
        ProjectRow(
            project: "claudence-06",
            usage: DashboardUsage.medium,
            sessionCount: 12,
            estimatedCost: 4.82,
            lastActivity: DashboardClock.ago(9 * DashboardClock.minute),
            averageDuration: 47 * DashboardClock.minute
        ),
        ProjectRow(
            project: "hr-leave-management-14",
            usage: DashboardUsage.small,
            sessionCount: 4,
            estimatedCost: 0.61,
            lastActivity: DashboardClock.ago(2 * DashboardClock.hour + 14 * DashboardClock.minute),
            averageDuration: 22 * DashboardClock.minute
        ),
        // A very long path, a very large token count, and a model with no
        // price: three separate cells that must degrade independently.
        ProjectRow(
            project: DashboardPaths.veryLong,
            usage: DashboardUsage.enormous,
            sessionCount: 31,
            estimatedCost: nil,
            lastActivity: DashboardClock.ago(3 * DashboardClock.day),
            averageDuration: nil
        ),
        // Nothing measured for this project yet: a real zero, no bar fill, and
        // no last-activity timestamp at all.
        ProjectRow(
            project: "fresh-project",
            usage: DashboardUsage.none,
            sessionCount: 1,
            estimatedCost: nil,
            lastActivity: nil,
            averageDuration: nil
        ),
    ]

    /// Every project measured zero. The footnote must change, not the bars.
    static let allZero: [ProjectRow] = [
        ProjectRow(
            project: "fresh-project",
            usage: DashboardUsage.none,
            sessionCount: 1,
            estimatedCost: nil,
            lastActivity: nil,
            averageDuration: nil
        )
    ]

    static let none: [ProjectRow] = []
}

private enum DashboardHistory {
    private static func make(
        id: String,
        project: String,
        startedAgo: TimeInterval,
        duration: TimeInterval,
        usage: TokenUsage,
        model: String?
    ) -> HistoryRow {
        HistoryRow(
            id: id,
            project: project,
            startedAt: DashboardClock.ago(startedAgo),
            duration: duration,
            usage: usage,
            model: model
        )
    }

    static let mixed: [HistoryRow] = [
        make(
            id: "hist-1",
            project: "claudence-06",
            startedAgo: 51 * DashboardClock.minute,
            duration: 38 * DashboardClock.minute,
            usage: DashboardUsage.small,
            model: "claude-sonnet-5"
        ),
        make(
            id: "hist-2",
            project: "claudence-06",
            startedAgo: 5 * DashboardClock.hour,
            duration: 2 * DashboardClock.hour + 9 * DashboardClock.minute,
            usage: DashboardUsage.medium,
            model: "claude-opus-4-5"
        ),
        // Same project, different session: identity must not collapse.
        make(
            id: "hist-3",
            project: "hr-leave-management-14",
            startedAgo: 2 * DashboardClock.day,
            duration: 14 * DashboardClock.minute,
            usage: DashboardUsage.small,
            model: nil
        ),
        make(
            id: "hist-4",
            project: DashboardPaths.veryLong,
            startedAgo: 9 * DashboardClock.day,
            duration: 3 * DashboardClock.day + 4 * DashboardClock.hour,
            usage: DashboardUsage.enormous,
            model: "claude-opus-4-5-extended-thinking-preview"
        ),
    ]

    static let none: [HistoryRow] = []
}

// MARK: - Composed dashboards

private enum DashboardFixture {
    static let healthy = DashboardData(
        windows: DashboardWindows.healthy,
        sessions: DashboardSessions.all,
        tokenScaleMaximum: DashboardUsage.mediumScale,
        burnRates: DashboardSessions.burnRates,
        series: DashboardSeries.healthy,
        projects: DashboardProjects.healthy,
        history: DashboardHistory.mixed,
        todayUsage: DashboardUsage.medium,
        todayCost: 4.82,
        unpricedSessionCount: 0
    )

    static let critical = DashboardData(
        windows: DashboardWindows.critical,
        sessions: DashboardSessions.all,
        tokenScaleMaximum: DashboardUsage.mediumScale,
        burnRates: DashboardSessions.burnRates,
        series: DashboardSeries.healthy,
        projects: DashboardProjects.healthy,
        history: DashboardHistory.mixed,
        todayUsage: DashboardUsage.medium,
        todayCost: 11.40,
        unpricedSessionCount: 0
    )

    /// Two sessions could not be priced. The estimate stays, the caption says
    /// how incomplete it is, and it never reads as a billing amount.
    static let unpriced = DashboardData(
        windows: DashboardWindows.healthy,
        sessions: DashboardSessions.all,
        tokenScaleMaximum: DashboardUsage.mediumScale,
        burnRates: DashboardSessions.burnRates,
        series: DashboardSeries.withGap,
        projects: DashboardProjects.healthy,
        history: DashboardHistory.mixed,
        todayUsage: DashboardUsage.medium,
        todayCost: 2.15,
        unpricedSessionCount: 2
    )

    /// No price at all for today's models: the tile refuses to show a number.
    static let noPrice = DashboardData(
        windows: DashboardWindows.healthy,
        sessions: DashboardSessions.all,
        tokenScaleMaximum: DashboardUsage.mediumScale,
        burnRates: DashboardSessions.burnRates,
        series: DashboardSeries.healthy,
        projects: DashboardProjects.healthy,
        history: DashboardHistory.mixed,
        todayUsage: DashboardUsage.medium,
        todayCost: nil,
        unpricedSessionCount: 3
    )

    /// Nothing running, nothing recorded, and no usage payload. Every section
    /// must say what is missing without a single fabricated value.
    static let empty = DashboardData(
        windows: [],
        usageUnavailableReason: "Keychain access was denied",
        sessions: DashboardSessions.none,
        tokenScaleMaximum: nil,
        burnRates: [:],
        series: DashboardSeries.empty,
        seriesUnavailableReason: "No usage has been recorded yet",
        projects: DashboardProjects.none,
        history: DashboardHistory.none,
        todayUsage: nil,
        todayCost: nil,
        unpricedSessionCount: 0
    )

    /// Sources answered, but there is genuinely nothing to report today.
    static let quiet = DashboardData(
        windows: DashboardWindows.partial,
        sessions: DashboardSessions.none,
        tokenScaleMaximum: DashboardUsage.smallScale,
        burnRates: [:],
        series: DashboardSeries.allZero,
        projects: DashboardProjects.allZero,
        history: DashboardHistory.none,
        todayUsage: DashboardUsage.none,
        todayCost: 0,
        unpricedSessionCount: 0
    )

    /// Millions everywhere: axis labels, table columns and the hero number all
    /// have to survive it.
    static let enormous = DashboardData(
        windows: DashboardWindows.critical,
        sessions: [DashboardSessions.enormous, DashboardSessions.longPath],
        tokenScaleMaximum: DashboardUsage.enormousScale,
        burnRates: DashboardSessions.burnRates,
        series: DashboardSeries.enormous,
        projects: DashboardProjects.healthy,
        history: DashboardHistory.mixed,
        todayUsage: DashboardUsage.enormous,
        todayCost: 812.47,
        unpricedSessionCount: 1
    )
}

/// Renders a dashboard at its design size so layout problems appear here rather
/// than in the shipped window.
private struct DashboardPreviewFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(
                width: DashboardMetrics.windowWidth,
                height: DashboardMetrics.windowHeight
            )
    }
}

/// A narrow strip for previewing one component on its own.
private struct DashboardSectionFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title.uppercased())
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textTertiary)
            content
        }
        .padding(DashboardMetrics.padding)
        .frame(width: DashboardMetrics.windowWidth, alignment: .leading)
        .background(Theme.surface)
    }
}

// MARK: - Whole window

struct DashboardHealthyPreview: PreviewProvider {
    static var previews: some View {
        DashboardPreviewFrame {
            DashboardView(data: DashboardFixture.healthy, now: DashboardClock.now)
        }
        .previewDisplayName("Dashboard / healthy")
    }
}

struct DashboardCriticalPreview: PreviewProvider {
    static var previews: some View {
        DashboardPreviewFrame {
            DashboardView(data: DashboardFixture.critical, now: DashboardClock.now)
        }
        .previewDisplayName("Dashboard / critical")
    }
}

struct DashboardEmptyPreview: PreviewProvider {
    static var previews: some View {
        DashboardPreviewFrame {
            DashboardView(data: DashboardFixture.empty, now: DashboardClock.now)
        }
        .previewDisplayName("Dashboard / everything unavailable")
    }
}

struct DashboardQuietPreview: PreviewProvider {
    static var previews: some View {
        DashboardPreviewFrame {
            DashboardView(data: DashboardFixture.quiet, now: DashboardClock.now)
        }
        .previewDisplayName("Dashboard / measured zeroes, no sessions")
    }
}

struct DashboardUnpricedPreview: PreviewProvider {
    static var previews: some View {
        DashboardPreviewFrame {
            DashboardView(data: DashboardFixture.unpriced, now: DashboardClock.now)
        }
        .previewDisplayName("Dashboard / unpriced sessions and a gapped series")
    }
}

struct DashboardNoPricePreview: PreviewProvider {
    static var previews: some View {
        DashboardPreviewFrame {
            DashboardView(data: DashboardFixture.noPrice, now: DashboardClock.now)
        }
        .previewDisplayName("Dashboard / cost unavailable")
    }
}

struct DashboardEnormousPreview: PreviewProvider {
    static var previews: some View {
        DashboardPreviewFrame {
            DashboardView(data: DashboardFixture.enormous, now: DashboardClock.now)
        }
        .previewDisplayName("Dashboard / millions of tokens")
    }
}

/// The narrowest supported window. Tables truncate; no column changes meaning.
struct DashboardMinimumWidthPreview: PreviewProvider {
    static var previews: some View {
        DashboardView(data: DashboardFixture.healthy, now: DashboardClock.now)
            .frame(
                width: DashboardMetrics.minimumWidth,
                height: DashboardMetrics.minimumHeight
            )
            .previewDisplayName("Dashboard / minimum size")
    }
}

// MARK: - UsageChart

struct UsageChartShapesPreview: PreviewProvider {
    static var previews: some View {
        DashboardSectionFrame(title: "Usage chart") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                // Ordinary fortnight, including two measured zeroes.
                UsageChart(points: DashboardSeries.healthy)
                // Three-day outage plus an isolated measured day: the line
                // breaks and the missing columns are dashed.
                UsageChart(points: DashboardSeries.withGap)
                // Millions: "M" labels inside the 46 pt gutter.
                UsageChart(points: DashboardSeries.enormous)
            }
        }
        .previewDisplayName("UsageChart / shapes")
    }
}

struct UsageChartEdgeCasesPreview: PreviewProvider {
    static var previews: some View {
        DashboardSectionFrame(title: "Usage chart edges") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                // Measured, and every day zero: a flat line on the floor with a
                // single gridline, not three duplicate zero labels.
                UsageChart(points: DashboardSeries.allZero)
                // One measured day: a dot, because a one-point line is nothing.
                UsageChart(points: DashboardSeries.single)
                // Nothing measured at all: no axes, an honest message.
                UsageChart(
                    points: DashboardSeries.allMissing,
                    unavailableReason: "The store could not answer for any day in this range"
                )
                UsageChart(
                    points: DashboardSeries.empty,
                    unavailableReason: "No usage has been recorded yet"
                )
            }
        }
        .previewDisplayName("UsageChart / edge cases")
    }
}

// MARK: - ProjectBreakdownView

struct ProjectBreakdownPreview: PreviewProvider {
    static var previews: some View {
        DashboardSectionFrame(title: "Projects") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                ProjectBreakdownView(
                    rows: DashboardProjects.healthy,
                    now: DashboardClock.now
                )
                ProjectBreakdownView(
                    rows: DashboardProjects.allZero,
                    now: DashboardClock.now
                )
                ProjectBreakdownView(
                    rows: DashboardProjects.none,
                    emptyReason: "No transcript has been read yet",
                    now: DashboardClock.now
                )
            }
        }
        .previewDisplayName("ProjectBreakdownView / states")
    }
}

// MARK: - SessionHistoryView

struct SessionHistoryPreview: PreviewProvider {
    static var previews: some View {
        DashboardSectionFrame(title: "History") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SessionHistoryView(
                    rows: DashboardHistory.mixed,
                    now: DashboardClock.now,
                    initialRange: .thirtyDays
                )
                // Same rows, narrowest range: most rows filter out, which is a
                // different message from having no history at all.
                SessionHistoryView(
                    rows: DashboardHistory.mixed,
                    now: DashboardClock.now,
                    initialRange: .today
                )
                SessionHistoryView(rows: DashboardHistory.none, now: DashboardClock.now)
            }
        }
        .previewDisplayName("SessionHistoryView / ranges")
    }
}
