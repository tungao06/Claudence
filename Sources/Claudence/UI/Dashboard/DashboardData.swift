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
    let duration: TimeInterval
    let usage: TokenUsage
    /// Nil when the transcript never recorded a model for this session.
    let model: String?

    init(
        id: String,
        project: String,
        startedAt: Date,
        duration: TimeInterval,
        usage: TokenUsage,
        model: String? = nil
    ) {
        self.id = id
        self.project = project
        self.startedAt = startedAt
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
    /// Why the series is empty, when a reason is actually known.
    let seriesUnavailableReason: String?

    let projects: [ProjectRow]
    let history: [HistoryRow]

    /// Nil when today's totals could not be read. Zero is a real answer and is
    /// not the same thing.
    let todayUsage: TokenUsage?
    /// Estimated only. Nil when any model involved has no price.
    let todayCost: Double?
    /// How many of today's sessions had no price table entry. Shown in words
    /// beside the estimate so it can never read as a billing amount.
    let unpricedSessionCount: Int

    init(
        windows: [UsageWindow] = [],
        usageUnavailableReason: String? = nil,
        sessions: [AISession] = [],
        tokenScaleMaximum: Int? = nil,
        burnRates: [String: BurnSample] = [:],
        series: [ChartPoint] = [],
        seriesUnavailableReason: String? = nil,
        projects: [ProjectRow] = [],
        history: [HistoryRow] = [],
        todayUsage: TokenUsage? = nil,
        todayCost: Double? = nil,
        unpricedSessionCount: Int = 0
    ) {
        self.windows = windows
        self.usageUnavailableReason = usageUnavailableReason
        self.sessions = sessions
        self.tokenScaleMaximum = tokenScaleMaximum
        self.burnRates = burnRates
        self.series = series
        self.seriesUnavailableReason = seriesUnavailableReason
        self.projects = projects
        self.history = history
        self.todayUsage = todayUsage
        self.todayCost = todayCost
        self.unpricedSessionCount = unpricedSessionCount
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

    /// Nothing measured at all. Used to pick the honest opening state.
    var isEmpty: Bool {
        windows.isEmpty && sessions.isEmpty && series.isEmpty
            && projects.isEmpty && history.isEmpty && todayUsage == nil
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

    /// Design size of the window. Sections are laid out against this width.
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 560
    /// Below this the tables truncate rather than reflow, which is the
    /// intended behaviour: column meaning must not change with window size.
    static let minimumWidth: CGFloat = 640
    static let minimumHeight: CGFloat = 420

    static let padding: CGFloat = Theme.Space.xl
    /// 720 - 16 - 16.
    static var contentWidth: CGFloat { windowWidth - padding * 2 }

    // MARK: Hero

    /// Larger than the popover ring: this window has the room, and the ring is
    /// the first thing read. Centre label clears at 132 - 12 * 3 = 96 pt.
    static let heroRingSize: CGFloat = 132
    static let heroRingStroke: CGFloat = 12
    /// Two columns of session rows at (688 - 16) / 2 = 336 pt, comfortably
    /// wider than the 300 pt the rows were designed against.
    static let sessionColumnSpacing: CGFloat = Theme.Space.xl

    // MARK: Chart

    static let chartHeight: CGFloat = 168
    /// Room for a y-axis label such as "18.6M".
    static let chartGutter: CGFloat = 46
    static let chartAxisHeight: CGFloat = 18
    static let chartTopInset: CGFloat = Theme.Space.m
    static let chartRightInset: CGFloat = Theme.Space.m
    static let chartLineStroke: CGFloat = Theme.Bar.sparklineStroke * 1.5
    static let chartGridStroke: CGFloat = 1
    /// An isolated real sample between two gaps still has to be visible.
    static let chartPointRadius: CGFloat = Theme.Bar.statusGlyph / 2
    static let chartAreaOpacity: Double = 0.12
    /// At most four horizontal gridlines: zero plus three steps.
    static let chartTickIntervals: Int = 3
    /// Sparse by design. Labelling every point is unreadable at 30 days.
    static let chartMaximumXLabels: Int = 5
    static let chartMissingDash: [CGFloat] = [2, 3]
    static let focusRingWidth: CGFloat = 2

    // MARK: Table columns
    //
    // Fixed trailing columns, one flexible leading column that truncates.
    // Projects: 60 + 84 + 84 + 84 + 100 + 5 gaps of 12 = 472, leaving 216.
    // History:  132 + 148 + 80 + 84 + 4 gaps of 12 = 492, leaving 196.

    static let columnSpacing: CGFloat = Theme.Space.l

    static let projectSessionsColumn: CGFloat = 60
    static let projectTokensColumn: CGFloat = 84
    static let projectCostColumn: CGFloat = 84
    static let projectDurationColumn: CGFloat = 84
    static let projectLastActiveColumn: CGFloat = 100

    static let historyStartedColumn: CGFloat = 132
    static let historyModelColumn: CGFloat = 148
    static let historyDurationColumn: CGFloat = 80
    static let historyTokensColumn: CGFloat = 84
}
