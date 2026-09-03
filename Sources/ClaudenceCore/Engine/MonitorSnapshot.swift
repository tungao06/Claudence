import Foundation

/// One immutable view of the whole system at a moment in time.
/// The UI renders snapshots and nothing else; it never reaches back into a
/// file, a process, or the network. See spec section 4.
public struct MonitorSnapshot: Sendable, Equatable {
    public var sessions: [AISession]
    public var usage: UsageState
    /// Tokens recorded for the current local day, or nil when the store could
    /// not answer.
    ///
    /// Optional because the engine reads an aggregate, and an aggregate that
    /// failed returns the same empty result as a day with nothing on it. This
    /// was a plain `TokenUsage` until 2026-09-03 and published `Tokens today 0`
    /// off a failed query, as a measurement, which is the one thing this
    /// project does not do. Nothing durable was wrong; the header simply had no
    /// figure and said it had one.
    public var todayUsage: TokenUsage?
    public var updatedAt: Date
    /// When the usage provider will next try the network, when it is inside
    /// its own backoff after a failure. Nil when nothing is being held back.
    ///
    /// It rides on the snapshot rather than being asked for separately because
    /// it is only meaningful beside the usage state it explains: `unavailable`
    /// with nothing more said reads as broken, and the two together read as
    /// "the endpoint refused, and it will be asked again at this time."
    public var usageRetryAt: Date?

    /// The state a snapshot is in before the first usage fetch returns. Not
    /// an error: it is the ordinary opening condition of every launch.
    public static let notYetFetched = Phrase(en: "Not yet fetched", th: "ยังไม่ได้ดึงข้อมูล")

    public init(
        sessions: [AISession] = [],
        usage: UsageState = .unavailable(reason: MonitorSnapshot.notYetFetched),
        todayUsage: TokenUsage? = nil,
        updatedAt: Date = Date(),
        usageRetryAt: Date? = nil
    ) {
        self.sessions = sessions
        self.usage = usage
        self.todayUsage = todayUsage
        self.updatedAt = updatedAt
        self.usageRetryAt = usageRetryAt
    }

    public static let empty = MonitorSnapshot()

    /// **The one definition of "active".** A session is active when it is doing
    /// work now, which is `status == .running`.
    ///
    /// A session with a live process that is waiting on its user is *live*, not
    /// active, and `liveCount` below is the count of those. The distinction is
    /// the honest reading of the word, and it is the whole of defect 9.7's first
    /// case: three surfaces printed a count under the word "active" and only
    /// this one meant it, so with one busy session and one idle one VoiceOver
    /// said one and two other places said two. Every surface that prints the
    /// word now prints this number, and every surface that counts the whole live
    /// set says "live".
    ///
    /// `.running` itself is derived in `SessionRegistryAdapter`: a live process
    /// whose transcript moved recently. It is not a claim about what the model
    /// is doing this instant, and nothing here pretends otherwise.
    public var activeCount: Int {
        MonitorSnapshot.activeCount(of: sessions)
    }

    /// The same count over a bare list, for the surfaces that hold sessions
    /// without a snapshot around them. One implementation, so a second filter
    /// spelled `.running` cannot appear somewhere and drift.
    public static func activeCount(of sessions: [AISession]) -> Int {
        sessions.filter { $0.status == .running }.count
    }

    /// Every session with a live process, busy or waiting.
    ///
    /// This is what the popover lists and what the dashboard's sessions card
    /// draws, so it is the denominator the Active-sessions tile divides into:
    /// active is a subset of live by construction, which is the only way a tile
    /// rendering the two as a fraction can be prevented from printing a
    /// numerator larger than its denominator.
    public var liveCount: Int {
        sessions.count
    }

    /// The window the menu bar summarizes. Five hours is the one that runs out.
    public var primaryWindow: UsageWindow? {
        usage.window(named: "five_hour")
    }

    /// Severity for the menu bar glyph, from the primary window.
    public var severity: Severity? {
        guard let percent = primaryWindow?.usedPercent else { return nil }
        return Constants.UsageThreshold.severity(forPercent: percent)
    }

    /// Equality on everything a viewer could see, ignoring the two fields that
    /// move on their own.
    ///
    /// `updatedAt` is set to `Date()` by every refresh, and
    /// `UsageState.available` carries its own `fetchedAt`. Comparing whole
    /// snapshots therefore always reports "changed", which is what made an idle
    /// app republish and re-render on every filesystem event. Both fields are
    /// timestamps *about* the reading rather than part of it, so both are
    /// excluded here. Nothing else in a snapshot is time-derived: `duration` is
    /// computed from `Date()` at read time and is not stored.
    public func hasSameContent(as other: MonitorSnapshot) -> Bool {
        sessions == other.sessions
            && todayUsage == other.todayUsage
            && MonitorSnapshot.sameContent(usage, other.usage)
    }

    private static func sameContent(_ lhs: UsageState, _ rhs: UsageState) -> Bool {
        switch (lhs, rhs) {
        case let (.unavailable(a), .unavailable(b)):
            return a == b
        case let (.available(windowsA, _), .available(windowsB, _)):
            return windowsA == windowsB
        default:
            return false
        }
    }
}

// MARK: - Burn rate

/// Rolling token rate. Computed over a window rather than since session start,
/// so a long-idle session does not read as busy.
public struct BurnRate: Sendable, Equatable {
    public let tokensPerMinute: Double
    public let samples: [Double]

    public init(tokensPerMinute: Double, samples: [Double] = []) {
        self.tokensPerMinute = tokensPerMinute
        self.samples = samples
    }

    public static let zero = BurnRate(tokensPerMinute: 0)
}

/// Fixed-size ring of (time, cumulative tokens) observations per session.
/// Rate comes from the span between the oldest and newest sample inside the
/// window, which is why an idle gap drives the rate toward zero instead of
/// preserving a stale average.
public struct BurnRateTracker: Sendable {
    public struct Sample: Sendable, Equatable {
        public let at: Date
        public let cumulativeTokens: Int
    }

    private var samples: [Sample] = []
    private let window: TimeInterval
    private let capacity: Int

    public init(window: TimeInterval = Constants.BurnRate.window, capacity: Int = 60) {
        self.window = window
        self.capacity = capacity
    }

    /// The newest cumulative total held, or nil when empty. Lets a caller skip
    /// recording a sample that would repeat the previous total.
    public var lastCumulativeTokens: Int? { samples.last?.cumulativeTokens }

    public mutating func record(tokens: Int, at date: Date = Date()) {
        samples.append(Sample(at: date, cumulativeTokens: tokens))
        let cutoff = date.addingTimeInterval(-window)
        samples.removeAll { $0.at < cutoff }
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    /// - Parameter now: the moment the rate is read at. It is not decoration:
    ///   the window is measured backward from it, so a session that stopped
    ///   spending decays instead of reporting its last busy average forever.
    ///
    /// Eviction has to happen here as well as in `record`, because `record` is
    /// only called when the combined total actually moves. A quiet session
    /// records nothing at all, so a tracker that only expired samples on write
    /// never expired any.
    public func rate(now: Date = Date()) -> BurnRate {
        let cutoff = now.addingTimeInterval(-window)
        let live = samples.filter { $0.at >= cutoff }
        guard let first = live.first, let last = live.last, live.count >= 2 else {
            return .zero
        }
        // Measured to `now`, not to the newest sample. The idle tail is part of
        // the span the tokens were spent over, and leaving it out is what let a
        // five-minute burst still read as a burst four hours later. A `now`
        // behind the newest sample would shorten the span instead, so the
        // newest sample floors it.
        let elapsed = max(now, last.at).timeIntervalSince(first.at)
        guard elapsed > 1 else { return .zero }
        let delta = max(0, last.cumulativeTokens - first.cumulativeTokens)
        let perMinute = Double(delta) / (elapsed / 60)

        // Successive deltas make the sparkline show change, not a rising total.
        var series: [Double] = []
        series.reserveCapacity(max(0, live.count - 1))
        for index in 1..<live.count {
            series.append(Double(max(0, live[index].cumulativeTokens - live[index - 1].cumulativeTokens)))
        }
        return BurnRate(tokensPerMinute: perMinute, samples: series)
    }
}

/// A session's subagent total as one value, so the engine can carry the last
/// figure it established without carrying the subagents themselves.
///
/// It exists because an empty list of subagents and a total of zero are the
/// same value and not the same fact: a pass that could not read the subagent
/// directory knows nothing, and writing zero for it collapses a stored row.
struct SubagentFigure: Sendable, Equatable {
    var usage: TokenUsage
    var count: Int
    var usageByModel: [String: TokenUsage] = [:]
}
