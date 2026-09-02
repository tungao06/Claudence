import Foundation

// MARK: - Day over day

/// Today's tokens against yesterday's, for the dashboard's "vs yesterday" line.
///
/// Both sides are carried whole rather than pre-reduced to a percentage, so a
/// caller can show the two figures alongside the change without asking the
/// store twice.
///
/// Absence is handled one level up. `AnalyticsService.dayOverDay()` returns nil
/// when the store could not answer, so a store failure never arrives here
/// disguised as a zero day. A `DayOverDayDelta` that exists is measured: its
/// zeros are real zeros.
public struct DayOverDayDelta: Sendable, Equatable {
    /// Tokens recorded for the current local day.
    public let today: TokenUsage
    /// Tokens recorded for the local day before it.
    public let yesterday: TokenUsage

    public init(today: TokenUsage, yesterday: TokenUsage) {
        self.today = today
        self.yesterday = yesterday
    }

    /// `(today - yesterday) / yesterday` on `TokenUsage.total`, signed.
    ///
    /// Nil when yesterday is zero, because the ratio is undefined and not
    /// infinite: "5,000 tokens today, none yesterday" is a first day of work,
    /// not an infinite increase. The caller renders "no comparison" rather than
    /// inventing a denominator of one.
    public var fractionalChange: Double? {
        let base = yesterday.total
        guard base > 0 else { return nil }
        return Double(today.total - base) / Double(base)
    }

    /// The same figure as a percentage, for a view that formats percentages.
    public var percentChange: Double? { fractionalChange.map { $0 * 100 } }

    /// Whether a comparison can be drawn at all.
    public var hasComparison: Bool { yesterday.total > 0 }
}

// MARK: - Share of recent activity

/// One session's slice of the tokens Claudence measured across a recent window.
///
/// `share` is deliberately optional. When nothing was measured in the window the
/// denominator is zero and every share is undefined, which is not the same as
/// every share being 0%.
public struct SessionTokenShare: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let projectName: String
    /// The session's own tokens as stored, subagents included where known.
    public let usage: TokenUsage
    /// Fraction of `RecentTokenShares.measuredTotal.total`, or nil when that
    /// total is zero.
    public let share: Double?

    public var id: String { sessionID }

    public init(sessionID: String, projectName: String, usage: TokenUsage, share: Double?) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.usage = usage
        self.share = share
    }
}

/// How recently-active sessions divide up the tokens Claudence itself measured.
///
/// ## This is not a share of the provider's 5 hour window
///
/// `PLAN-UI.md` section C lists "share of the 5-hour window", and the obvious
/// reading of that is wrong. `GET /api/oauth/usage` reports a **percentage
/// consumed** and never an absolute capacity, so the window's token size is not
/// a number this application has. Recovering it as
/// `measuredTokens / percentUsed` would manufacture a denominator out of our own
/// incomplete measurement and then divide by it, which is fabricating a number
/// twice over. `CLAUDE.md` forbids exactly that.
///
/// So the denominator here is local and stated: the sum of `combinedUsage` over
/// every session the store shows as active in the window. It says "this session
/// is 40% of what Claudence saw in the last five hours". It says nothing about
/// how much of the billing window is left; `UsageWindow.usedPercent` is the only
/// source for that, and it is unrelated to this figure.
///
/// The denominator is `combinedUsage`, which includes what each session's
/// subagents spent. That is the honest figure: subagents have no process of
/// their own and their tokens are billed to the parent.
///
/// An earlier version of this comment warned that sessions rehydrated from the
/// store carried no subagent split, so `combinedUsage` collapsed to the parent
/// transcript's tokens for stored rows. That is no longer true. Schema version
/// 2 added `subagent_*` columns to `sessions`, and `allSessions(since:)` reads
/// them back into `subagentUsage`, so a stored session's combined total matches
/// what it had when it was written.
public struct RecentTokenShares: Sendable, Equatable {
    /// The window's length, as asked for.
    public let window: TimeInterval
    /// Start of the window.
    public let since: Date
    /// End of the window, the `now` the service was asked at.
    public let until: Date
    /// Sum over the listed sessions. The denominator of every share, and a
    /// figure Claudence measured rather than one a provider reported.
    public let measuredTotal: TokenUsage
    /// Sessions active in the window, heaviest first, ties broken by session id
    /// so the order is stable between refreshes.
    public let sessions: [SessionTokenShare]

    public init(
        window: TimeInterval,
        since: Date,
        until: Date,
        measuredTotal: TokenUsage,
        sessions: [SessionTokenShare]
    ) {
        self.window = window
        self.since = since
        self.until = until
        self.measuredTotal = measuredTotal
        self.sessions = sessions
    }

    /// One session's share, or nil when it was not active in the window or the
    /// window measured nothing at all.
    public func share(ofSession sessionID: String) -> Double? {
        sessions.first { $0.sessionID == sessionID }?.share
    }
}

// MARK: - Daily chart bands

/// The two bands the daily chart stacks.
///
/// No stored field is added to `DailyPoint`: it already carries the whole
/// `TokenUsage`, and `billableInput + output == total` is the contract's own
/// identity from `TokenUsage`, not an arithmetic step re-derived here. Storing
/// the split would create a second place for the numbers to disagree.
///
/// Each accessor is nil exactly when `usage` is nil, so a day the store could
/// not answer for draws as a gap in both bands rather than as two zero-height
/// bars.
extension DailyPoint {
    /// Lower band: fresh input plus cache creation plus cache read.
    public var billableInput: Int? { usage?.billableInput }

    /// Upper band: output tokens.
    public var output: Int? { usage?.output }

    /// The stacked height, equal to `billableInput + output` by definition.
    public var total: Int? { usage?.total }
}
