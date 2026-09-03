import Foundation
import ClaudenceCore

// MARK: - Dashboard input values
//
// The dashboard renders these types and nothing else. They are plain data:
// no service, no store, no client, no closure that could reach one. Whatever
// the analytics layer settles on, the adapter that maps it to these values is
// written once, at the composition seam, and the views never learn about it.
//
// Every optional here means exactly one thing: the value could not be derived.
// A nil renders `UnavailableView`, never a zero, a dash in a bar, or a
// placeholder fill. See spec section 9.4.

/// One sample in the usage-over-time series.
///
/// `isMissing` is deliberately separate from `value`. A day on which nothing
/// ran is a measured zero and is drawn on the floor of the chart; a day the
/// store could not answer for is a gap and breaks the line. Collapsing the two
/// would turn an absence of knowledge into a claim about behaviour.
struct ChartPoint: Identifiable, Sendable, Equatable {
    /// Stable identity for the point, e.g. a day key. Defaults to the label.
    let id: String
    /// Short axis text for this point, e.g. a day. The chart decides which
    /// labels it has room to draw; the point only supplies its own.
    let label: String
    /// The measured value. Meaningless, and never read, when `isMissing`.
    let value: Double
    /// True when the store could not answer for this bucket.
    let isMissing: Bool

    init(id: String? = nil, label: String, value: Double, isMissing: Bool = false) {
        self.id = id ?? label
        self.label = label
        self.value = value
        self.isMissing = isMissing
    }

    /// A bucket with no answer. Carries no value at all, so nothing downstream
    /// can accidentally read one.
    static func missing(id: String? = nil, label: String) -> ChartPoint {
        ChartPoint(id: id, label: label, value: 0, isMissing: true)
    }
}

/// One project's roll-up.
struct ProjectRow: Identifiable, Sendable, Equatable {
    /// Project name or path. Used as identity, so it must be unique in a table.
    let project: String
    let usage: TokenUsage
    let sessionCount: Int
    /// Estimated only, and labelled as such wherever it is shown. Nil when a
    /// model in this project has no price, per spec section 9.2.
    let estimatedCost: Double?
    let lastActivity: Date?
    let averageDuration: TimeInterval?

    var id: String { project }

    init(
        project: String,
        usage: TokenUsage,
        sessionCount: Int,
        estimatedCost: Double? = nil,
        lastActivity: Date? = nil,
        averageDuration: TimeInterval? = nil
    ) {
        self.project = project
        self.usage = usage
        self.sessionCount = sessionCount
        self.estimatedCost = estimatedCost
        self.lastActivity = lastActivity
        self.averageDuration = averageDuration
    }
}

/// One finished session in the history table.
struct HistoryRow: Identifiable, Sendable, Equatable {
    /// Session identifier. Two sessions of the same project must not collide.
    let id: String
    let project: String
    let startedAt: Date
    /// When this session last did anything. **This is the field the Today,
    /// 7 days and 30 days ranges filter on**, and not `startedAt`: a session
    /// belongs to the day the work happened, which is the definition
    /// `AnalyticsService.sessionsToday()` and the daily rollup already use.
    /// Filtering on the start date put "0 sessions" under a table whose own
    /// window had counted one.
    let lastActivityAt: Date
    let duration: TimeInterval
    let usage: TokenUsage
    /// Nil when the transcript never recorded a model for this session.
    let model: String?

    /// - Parameter lastActivityAt: nil derives it from `startedAt + duration`,
    ///   which is the identity the adapter builds `duration` from in the first
    ///   place. Only the previews and tests leave it out.
    init(
        id: String,
        project: String,
        startedAt: Date,
        duration: TimeInterval,
        usage: TokenUsage,
        model: String? = nil,
        lastActivityAt: Date? = nil
    ) {
        self.id = id
        self.project = project
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt.addingTimeInterval(max(0, duration))
        self.duration = duration
        self.usage = usage
        self.model = model
    }
}

/// Burn rate for one session, as `SessionRow` wants it.
struct BurnSample: Sendable, Equatable {
    /// Nil is an ordinary state: too few samples to state a rate.
    let tokensPerMinute: Double?
    /// Recent samples for the sparkline. Fewer than two draws nothing.
    let samples: [Double]

    init(tokensPerMinute: Double? = nil, samples: [Double] = []) {
        self.tokensPerMinute = tokensPerMinute
        self.samples = samples
    }

    static let unavailable = BurnSample()
}

/// The session responsible for the largest share of the current burn (9.11).
/// Nil in `DashboardData` is the ordinary "nothing is burning" state, not an
/// absence of data: a share of zero has no largest member.
struct BurnLeaderInfo: Sendable, Equatable {
    /// Identifies the session for the caller that wants to act on it; not
    /// itself shown.
    let sessionID: String
    /// What the sessions list and the history table already call this
    /// session, so the leader line names it the same way the rest of the
    /// window does.
    let displayName: String
    /// This session's share of the summed burn rate, 0 to 1.
    let share: Double
}

/// Everything the dashboard window draws, in one value.
struct DashboardData: Sendable, Equatable {
    /// Usage windows exactly as the source reported them.
    let windows: [UsageWindow]
    /// Set when usage could not be read at all. The whole hero section then
    /// says so rather than drawing empty meters.
    let usageUnavailableReason: String?

    let sessions: [AISession]
    /// Denominator for the per-session token bars. Nil draws no bar, because a
    /// fill without a denominator is a made-up ratio.
    let tokenScaleMaximum: Int?
    /// Burn rates keyed by session id. A missing key is an ordinary state.
    let burnRates: [String: BurnSample]

    let series: [ChartPoint]
    /// Output tokens per series id, so the chart can draw the input and output
    /// bands separately. Held beside the series rather than inside `ChartPoint`
    /// because a point with no split is honest and a point with a defaulted
    /// zero would claim the day produced no output.
    let seriesOutput: [String: Double]
    /// Why the series is empty, when a reason is actually known.
    let seriesUnavailableReason: String?

    /// The five-hour window's own series, one point per hour.
    ///
    /// Held beside the daily series rather than replacing it because the header
    /// picker switches between them and both are wanted without a round trip to
    /// the database. The five-hour window is shorter than one column of the
    /// daily chart, so before this existed selecting `5h` could not change what
    /// the chart drew: the entire window lived inside today's bar.
    let hourlySeries: [ChartPoint]
    /// Output tokens per hourly point id, same split and same reason as
    /// `seriesOutput`.
    let hourlySeriesOutput: [String: Double]
    /// Why the hourly series is empty, when a reason is known.
    let hourlySeriesUnavailableReason: String?

    let projects: [ProjectRow]
    let history: [HistoryRow]

    /// Nil when today's totals could not be read. Zero is a real answer and is
    /// not the same thing.
    let todayUsage: TokenUsage?
    /// Estimated only, and over today's sessions: the range the tile names.
    /// Nil when any model involved has no price.
    ///
    /// Not the same range as `projects`, which is every session ever stored.
    /// Both were drawn unlabelled on one window, a $3.42 tile beside project
    /// rows summing to $5.43, and the two now name their ranges on screen: the
    /// tile is titled `Est. cost today` and the projects card is subtitled
    /// `all time`.
    let todayCost: Double?
    /// How many of today's sessions had no price table entry. Shown in words
    /// beside the estimate so it can never read as a billing amount.
    let unpricedSessionCount: Int

    /// Today's tokens against yesterday's, as a fraction: 0.18 is 18% more than
    /// yesterday. Nil covers both honest absences, and the tile renders neither
    /// as a number: the store could not answer, or yesterday recorded nothing
    /// and there is no base to compare against.
    ///
    /// Computed by `AnalyticsService.dayOverDay()` rather than here. The tile
    /// used to divide the last two points of `series` itself, which is a second
    /// definition of a figure the core already owns and tests.
    let todayVersusYesterday: Double?

    /// How many days old the price table is, but only once it is past its own
    /// staleness horizon. Nil means the rates are current, so nothing is said.
    ///
    /// `PriceTableProvenance` exists so a stale table is visible instead of
    /// quietly producing confident wrong money, and until this was wired
    /// nothing read it: the estimate would have gone on being drawn with the
    /// same caption whatever the age of the rates behind it.
    let priceTableStaleDays: Int?

    /// Each usage window's projected exhaustion, keyed by `UsageWindow.name`
    /// (9.11). A window absent from this map gets no tube caption beyond the
    /// reset; the meter never invents `rateUnavailable` for one the adapter
    /// never asked about.
    let projections: [String: UsageProjection]
    /// The name of the window projected to run out first, among those that
    /// run out at all before they reset. Nil when none does, which the meter
    /// leaves unmarked rather than picking one arbitrarily.
    let bindingWindowName: String?
    /// The session responsible for the largest share of the current burn.
    /// Nil is the ordinary "nothing burning" state.
    let burnLeader: BurnLeaderInfo?

    init(
        windows: [UsageWindow] = [],
        usageUnavailableReason: String? = nil,
        sessions: [AISession] = [],
        tokenScaleMaximum: Int? = nil,
        burnRates: [String: BurnSample] = [:],
        series: [ChartPoint] = [],
        seriesOutput: [String: Double] = [:],
        seriesUnavailableReason: String? = nil,
        hourlySeries: [ChartPoint] = [],
        hourlySeriesOutput: [String: Double] = [:],
        hourlySeriesUnavailableReason: String? = nil,
        projects: [ProjectRow] = [],
        history: [HistoryRow] = [],
        todayUsage: TokenUsage? = nil,
        todayCost: Double? = nil,
        unpricedSessionCount: Int = 0,
        todayVersusYesterday: Double? = nil,
        priceTableStaleDays: Int? = nil,
        projections: [String: UsageProjection] = [:],
        bindingWindowName: String? = nil,
        burnLeader: BurnLeaderInfo? = nil
    ) {
        self.windows = windows
        self.usageUnavailableReason = usageUnavailableReason
        self.sessions = sessions
        self.tokenScaleMaximum = tokenScaleMaximum
        self.burnRates = burnRates
        self.series = series
        self.seriesOutput = seriesOutput
        self.seriesUnavailableReason = seriesUnavailableReason
        self.hourlySeries = hourlySeries
        self.hourlySeriesOutput = hourlySeriesOutput
        self.hourlySeriesUnavailableReason = hourlySeriesUnavailableReason
        self.projects = projects
        self.history = history
        self.todayUsage = todayUsage
        self.todayCost = todayCost
        self.unpricedSessionCount = unpricedSessionCount
        self.todayVersusYesterday = todayVersusYesterday
        self.priceTableStaleDays = priceTableStaleDays
        self.projections = projections
        self.bindingWindowName = bindingWindowName
        self.burnLeader = burnLeader
    }

    /// Window keys as the usage API names them. These are the same keys
    /// `UsageWindow.displayName` already switches on; they are a data contract,
    /// not a value invented for display.
    enum WindowKey {
        static let fiveHour = "five_hour"
        static let sevenDay = "seven_day"
        static let modelScopedPrefix = "seven_day_"
    }

    /// The five-hour window, or a window of the same name carrying no value.
    /// Synthesising the *name* is safe; the percentage stays nil, so the meter
    /// renders `UnavailableView` rather than a fill.
    var fiveHourWindow: UsageWindow {
        windows.first { $0.name == WindowKey.fiveHour } ?? UsageWindow(name: WindowKey.fiveHour)
    }

    var sevenDayWindow: UsageWindow {
        windows.first { $0.name == WindowKey.sevenDay } ?? UsageWindow(name: WindowKey.sevenDay)
    }

    /// Model-scoped weekly caps, in the order the source returned them.
    var scopedWindows: [UsageWindow] {
        windows.filter { $0.name.hasPrefix(WindowKey.modelScopedPrefix) }
    }

    func burn(for session: AISession) -> BurnSample {
        burnRates[session.id] ?? .unavailable
    }

    /// A window's projected exhaustion, or `.rateUnavailable(.windowIncomplete)`
    /// when the adapter never recorded one for it (e.g. a window the payload
    /// did not report). Never a fabricated case: the fallback names the same
    /// reason `UsageProjector` gives a window with no percentage or reset.
    func projection(for window: UsageWindow) -> UsageProjection {
        projections[window.name] ?? .rateUnavailable(.windowIncomplete)
    }

    /// Whether `window` is the one projected to run out first among those that
    /// run out at all before they reset (9.11).
    func isBindingWindow(_ window: UsageWindow) -> Bool {
        bindingWindowName == window.name
    }

    /// Nothing measured at all. Used to pick the honest opening state.
    var isEmpty: Bool {
        windows.isEmpty && sessions.isEmpty && series.isEmpty
            && projects.isEmpty && history.isEmpty && todayUsage == nil
    }
}

// MARK: - Values the dashboard reads off the data
//
// Derivations, not measurements: every one of these is arithmetic over figures
// already in `DashboardData`, so a view never has to compute its own and two
// views can never disagree. Each returns nil rather than a stand-in when the
// inputs do not support an answer.

extension DashboardData {

    /// The windows the power meter draws, in reading order.
    ///
    /// The two primary windows are always present as tubes even when the
    /// payload omitted one, because a missing window is a fact worth showing:
    /// the tube renders with no fill and says `unavailable` rather than
    /// disappearing, which would read as "there is no such limit".
    var meterWindows: [UsageWindow] {
        [fiveHourWindow, sevenDayWindow] + scopedWindows
    }

    /// The worst window that actually reported a number, and its severity.
    /// Nil when no window reported one at all, which the banner says in words.
    var meterState: (window: UsageWindow, percent: Double, severity: Severity)? {
        let readable = meterWindows.compactMap { window -> (UsageWindow, Double)? in
            guard let percent = window.usedPercent else { return nil }
            return (window, min(100, max(0, percent)))
        }
        guard let worst = readable.max(by: { $0.1 < $1.1 }) else { return nil }
        return (worst.0, worst.1, Constants.UsageThreshold.severity(forPercent: worst.1))
    }

    /// True only when every window reported, and every one of them is healthy.
    /// The design's "plenty of power in every window" is a claim about all of
    /// them, so a single unreadable window is enough to withdraw it.
    var everyWindowIsHealthy: Bool {
        guard !meterWindows.isEmpty else { return false }
        return meterWindows.allSatisfy { window in
            guard let percent = window.usedPercent else { return false }
            return Constants.UsageThreshold.severity(forPercent: percent) == .healthy
        }
    }

    /// Sessions doing work now. `MonitorSnapshot.activeCount(of:)` is the one
    /// definition of the word and nothing here re-states it: this window and
    /// the menu bar both counted "active" for themselves and disagreed.
    var activeSessionCount: Int {
        MonitorSnapshot.activeCount(of: sessions)
    }

    /// Every session with a live process, busy or waiting. This is what the
    /// sessions card lists and what the Active-sessions tile divides into, so
    /// the tile's numerator is a subset of its denominator by construction.
    var liveSessionCount: Int {
        sessions.count
    }

    /// Distinct projects among the live sessions. Two sessions in one checkout
    /// are one project, which is the number the tile is claiming.
    var liveProjectCount: Int {
        Set(sessions.map(\.projectName)).count
    }

    /// Tokens per minute across every session that could state a rate.
    ///
    /// Nil when no session could: a rate of zero would say the machine is idle,
    /// where the truth is that too few samples have arrived to divide by.
    var burnRatePerMinute: Double? {
        let rates = sessions.compactMap { burn(for: $0).tokensPerMinute }
        guard !rates.isEmpty else { return nil }
        return rates.reduce(0, +)
    }

    /// How many sessions the burn rate is summed over, so the tile can name its
    /// own denominator instead of implying it covers every session on screen.
    var sessionsReportingBurn: Int {
        sessions.filter { burn(for: $0).tokensPerMinute != nil }.count
    }

}

// MARK: - Dashboard metrics
//
// The dashboard's own geometry. `Theme` owns the shared scale and this enum
// never redefines a token that exists there: it derives from `Theme` wherever
// a token applies and only names the values a 720 pt window needs that a
// 300 pt popover never did. No colour is defined here, ever.
enum DashboardMetrics {

    // MARK: Window

    /// Design size of the window. Sections are laid out against this width, and
    /// the two-column rows below only resolve at it: 372 + 18 + chart on one
    /// row, sessions + 18 + 340 on the next.
    static let windowWidth: CGFloat = Theme.Layout.dashboardWidth
    static let windowHeight: CGFloat = 780
    /// Below this the tables truncate rather than reflow, which is the
    /// intended behaviour: column meaning must not change with window size.
    /// The floor is set by the two fixed columns plus a chart narrow enough to
    /// still be a chart: 372 + 18 + 340 + 28 * 2 of shell padding.
    static let minimumWidth: CGFloat = 840
    static let minimumHeight: CGFloat = 520

    /// Shell header and body padding, from the design's 22 / 28.
    static let shellPaddingVertical: CGFloat = Theme.Dashboard.headerVertical
    static let shellPaddingHorizontal: CGFloat = Theme.Dashboard.horizontal
    static let bodyBottomPadding: CGFloat = Theme.Dashboard.bodyBottom
    /// Gap between the body's rows, and between the two cards inside a row.
    static let rowGap: CGFloat = Theme.Dashboard.sectionGap

    // MARK: Shell header
    //
    // The design's header is a mark and a three-line identity block on the
    // left, a segmented window picker and a refresh button on the right, over a
    // hairline. Measured off `Design/Claudence-UI.dc.html` section 1a.

    static let headerMarkSize: CGFloat = Theme.Dashboard.headerMark
    static let headerMarkGap: CGFloat = Theme.Space.l - 2
    static let headerControlGap: CGFloat = Theme.Space.m + 1
    /// `padding: 3px` on the segmented trough, `gap: 2px` between segments.
    static let segmentedTroughPadding: CGFloat = 3
    static let segmentedInnerGap: CGFloat = 2
    static let segmentPaddingVertical: CGFloat = Theme.Space.s
    static let segmentPaddingHorizontal: CGFloat = Theme.Space.l
    /// `width: 34px; height: 34px; border-radius: 10px` on the refresh control.
    static let refreshButtonSize: CGFloat = 34

    // MARK: Cards

    static let cardPadding: CGFloat = Theme.Dashboard.subCardPadding
    /// The chart card is the one the design pads wider, so its plot clears the
    /// y-axis labels on the left without crowding the legend on the right.
    static let chartCardPaddingHorizontal: CGFloat = Theme.Space.xxl
    static let cardContentGap: CGFloat = Theme.Dashboard.subCardGap
    /// The chart and breakdown cards are the two the design sets at 16, between
    /// `Theme.Space.l` and `.xl`. Named here rather than rounded to a token,
    /// because both cards sit beside a card that really is at 18 and the step
    /// between them is visible.
    static let cardContentGapTight: CGFloat = 16
    /// `gap: 3px` on the design's stacked card headers.
    static let cardHeaderGap: CGFloat = Theme.Space.xxs + 1
    /// Fixed columns of the two-card rows. Everything else takes the remainder.
    static let powerMeterColumnWidth: CGFloat = Theme.Dashboard.tubeColumnWidth
    static let breakdownColumnWidth: CGFloat = 340

    // MARK: Stat tiles

    static let statTileGap: CGFloat = Theme.Dashboard.statTileGap
    static let statTilePaddingVertical: CGFloat = Theme.Dashboard.statTilePaddingVertical
    static let statTilePaddingHorizontal: CGFloat = Theme.Dashboard.statTilePaddingHorizontal
    static let statTileContentGap: CGFloat = 7
    /// Four across at the design width; the grid reflows below that rather than
    /// letting a 26 pt value truncate.
    static let statTileMinimumWidth: CGFloat = 168
    /// `letter-spacing: .04em` at 11 px. The tile labels are *not* the popover's
    /// section headings, which the design tracks four times as wide, and using
    /// `Theme.sectionTracking` here was the transcription error that made them
    /// read as headings.
    static let statTileLabelTracking: CGFloat = 0.44
    /// `font-size: 14px` on the unit that trails a 26 pt figure: the `/min` of
    /// the burn tile and the ` / 4 today` of the sessions tile.
    static let statTileUnitSize: CGFloat = 14

    // MARK: Power meter tubes

    /// The design's three gaps, which an earlier transcription transposed:
    /// `gap: 10px` between two tube columns, `gap: 11px` between the reading,
    /// the tube and the caption block inside one column, and `gap: 3px` inside
    /// the caption between the window name and its reset time.
    static let tubeColumnGap: CGFloat = Theme.Dashboard.tubeGap
    static let tubeStackGap: CGFloat = Theme.Dashboard.tubeCaptionGap
    static let tubeCaptionGap: CGFloat = 3
    static let bannerPaddingVertical: CGFloat = Theme.Dashboard.bannerPaddingVertical
    static let bannerPaddingHorizontal: CGFloat = Theme.Dashboard.bannerPaddingHorizontal
    /// How far the severity tint is taken down before it sits behind text.
    static let bannerTintOpacity: Double = 0.14
    /// Outline on the tube the header's window picker has selected. Same
    /// language as the chart's ring on the most recent column.
    static let tubeSelectionStroke: CGFloat = 1.5
    static let tubeSelectionInset: CGFloat = -3

    // MARK: Chart

    static let chartHeight: CGFloat = Theme.Dashboard.chartPlotHeight
    /// Room for a y-axis label such as "18.6M".
    static let chartGutter: CGFloat = 46
    static let chartAxisHeight: CGFloat = 18
    static let chartTopInset: CGFloat = Theme.Space.m
    static let chartRightInset: CGFloat = Theme.Space.m
    static let chartGridStroke: CGFloat = 1
    /// At most four horizontal gridlines: zero plus three steps.
    static let chartTickIntervals: Int = 3
    /// Sparse by design. Labelling every point is unreadable at 30 days.
    static let chartMaximumXLabels: Int = 5
    static let chartMissingDash: [CGFloat] = [2, 3]
    static let focusRingWidth: CGFloat = 2

    // MARK: Session table rows
    //
    // The design's `1fr 132px 96px 84px`. The leading column is the one that
    // truncates, because a project name loses less by being cut than a number
    // does by being scaled.

    static let sessionRowGap: CGFloat = Theme.Dashboard.tableRowGap
    static let sessionRowColumnGap: CGFloat = Theme.Dashboard.tableColumnGap
    static let sessionRowPaddingVertical: CGFloat = Theme.Dashboard.tableRowPaddingVertical
    static let sessionRowPaddingHorizontal: CGFloat = Theme.Dashboard.tableRowPaddingHorizontal
    static let sessionEnergyColumn: CGFloat = Theme.Dashboard.tableTokensColumn
    static let sessionTotalColumn: CGFloat = Theme.Dashboard.tableRateColumn
    static let sessionBurnColumn: CGFloat = Theme.Dashboard.tableTrendColumn
    /// The design dims a finished row instead of dropping it: the session is
    /// still part of the reading, it just no longer moves.
    static let completedRowOpacity: Double = 0.78
    /// `width: 8px; height: 8px; border-radius: 999px` on the row's leading
    /// identity dot. Static in every state; the design pulses it on a live row
    /// and that is one of the nine repeats `CLAUDE.md` forbids.
    static let sessionDotSize: CGFloat = 8

    // MARK: Token breakdown

    static let stackedBarHeight: CGFloat = 12
    static let stackedBarSegmentGap: CGFloat = Theme.Space.xxs
    static let legendSwatch: CGFloat = 9
    /// `gap: 11px` between the breakdown's labelled rows.
    static let breakdownRowGap: CGFloat = 11

    // MARK: Burn rate
    //
    /// Length of the window `BurnRateTracker` averages over, in minutes.
    ///
    /// Read from the same constant the tracker defaults to, so the caption and
    /// the measurement cannot drift. The design's caption says ten minutes and
    /// the tracker measures five; ours states what the code measures.
    static let burnWindowMinutes: Int = Constants.BurnRate.windowMinutes

    // MARK: Table columns
    //
    // Fixed trailing columns, one flexible leading column that truncates.
    // Projects: 76 + 84 + 84 + 84 + 100 + 5 gaps of 12 = 488, leaving 200.
    // History:  132 + 148 + 80 + 84 + 4 gaps of 12 = 492, leaving 196.

    static let columnSpacing: CGFloat = Theme.Space.l

    /// Wide enough for the word in the header. At 60 the column held every
    /// count it will ever print and truncated its own title to `SESSI...`,
    /// which is the header row, not the data, deciding the width.
    static let projectSessionsColumn: CGFloat = 76
    static let projectTokensColumn: CGFloat = 84
    static let projectCostColumn: CGFloat = 84
    static let projectDurationColumn: CGFloat = 84
    static let projectLastActiveColumn: CGFloat = 100

    static let historyStartedColumn: CGFloat = 132
    static let historyModelColumn: CGFloat = 148
    static let historyDurationColumn: CGFloat = 80
    static let historyTokensColumn: CGFloat = 84
}
