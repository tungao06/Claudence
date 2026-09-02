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

// MARK: - Share of the window

/// One session's slice of the tokens Claudence measured *inside* a window.
///
/// Both optionals mean "not derivable" and neither means zero.
///
/// `windowUsage` is nil when the session's samples cannot be differenced over
/// the window: a running total on its own says nothing about a period, so a
/// session with a single sample and no history before the window has no
/// in-window figure at all. Its lifetime total is not a stand-in, and neither
/// is 0.
///
/// `share` is nil for that same session, and also when nothing at all was
/// measured in the window, because then the denominator is zero and every share
/// is undefined rather than 0%.
public struct SessionWindowShare: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let projectName: String
    /// What this session spent between `WindowTokenShares.since` and `until`,
    /// or nil when that is not derivable from the samples on hand.
    public let windowUsage: TokenUsage?
    /// Fraction of `WindowTokenShares.windowTotal.total`, or nil when that
    /// total is zero or this session's own in-window figure is not derivable.
    public let share: Double?

    public var id: String { sessionID }

    public init(sessionID: String, projectName: String, windowUsage: TokenUsage?, share: Double?) {
        self.sessionID = sessionID
        self.projectName = projectName
        self.windowUsage = windowUsage
        self.share = share
    }
}

/// How the sessions active in a window divide up the tokens spent *in* it.
///
/// ## Still not a share of the provider's 5 hour allowance
///
/// `PLAN-UI.md` section C lists "share of the 5-hour window", and one reading of
/// that is unavailable to this application. `GET /api/oauth/usage` reports a
/// **percentage consumed** and never an absolute capacity, so the window's token
/// size is not a number Claudence has. Recovering it as
/// `measuredTokens / percentUsed` would manufacture a denominator out of our own
/// incomplete measurement and then divide by it, which is fabricating a number
/// twice over. `CLAUDE.md` forbids exactly that.
///
/// The denominator is therefore local and stated: the tokens Claudence measured
/// across every session active in the window. The figure says "this session is
/// 40% of the work done in the last five hours". It still says nothing about how
/// much of the billing window is left; `UsageWindow.usedPercent` is the only
/// source for that, and it is unrelated to this figure.
///
/// ## What changed on 2026-09-03, and why the members were renamed
///
/// Until then both sides of the division were each session's **lifetime**
/// `combinedUsage`, merely filtered to sessions active in the window, and the
/// comment here argued that every member should say "recent tokens" rather than
/// "window" so a call site could not confuse the two. The single call site said
/// window anyway, and the figure was wrong in the way that matters: measured on
/// the live database for 20:25 to 01:25, session `6ff2ff43` rendered 59% having
/// spent about 1% of the tokens actually spent in that window, while the session
/// that spent 61% of them rendered 25%. A long-lived session that had been idle
/// for four hours out-ranked the one doing all the work.
///
/// Both numerator and denominator are now differences of `usage_samples` over
/// the window, so the members genuinely are window figures and are named for it.
/// Renaming instead of correcting was the other option and was rejected: Stage 3
/// projects a rate limit from the same in-window quantity, so the honest number
/// has to exist regardless.
///
/// Sampling is what the figure rests on, and it is not free of gaps. A session
/// with fewer than two points to difference across the window is reported as
/// undrawable rather than as zero, and contributes to neither side; see
/// `SessionWindowShare`.
///
/// The samples carry `combinedUsage`, which includes what each session's
/// subagents spent. That is the honest figure: subagents have no process of
/// their own and their tokens are billed to the parent.
public struct WindowTokenShares: Sendable, Equatable {
    /// The window's length, as asked for.
    public let window: TimeInterval
    /// Start of the window.
    public let since: Date
    /// End of the window, the `now` the service was asked at.
    public let until: Date
    /// Tokens spent inside the window, summed over the sessions whose in-window
    /// figure is derivable. The denominator of every share, and a figure
    /// Claudence measured rather than one a provider reported.
    public let windowTotal: TokenUsage
    /// Sessions active in the window, heaviest inside it first, ties broken by
    /// session id so the order is stable between refreshes. Sessions with no
    /// derivable in-window figure sort last.
    public let sessions: [SessionWindowShare]

    public init(
        window: TimeInterval,
        since: Date,
        until: Date,
        windowTotal: TokenUsage,
        sessions: [SessionWindowShare]
    ) {
        self.window = window
        self.since = since
        self.until = until
        self.windowTotal = windowTotal
        self.sessions = sessions
    }

    /// One session's share, or nil when it was not active in the window, its
    /// in-window figure is not derivable, or the window measured nothing at all.
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
