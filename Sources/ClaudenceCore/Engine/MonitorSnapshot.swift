import Foundation

/// One immutable view of the whole system at a moment in time.
/// The UI renders snapshots and nothing else; it never reaches back into a
/// file, a process, or the network. See spec section 4.
public struct MonitorSnapshot: Sendable, Equatable {
    public var sessions: [AISession]
    public var usage: UsageState
    public var todayUsage: TokenUsage
    public var updatedAt: Date

    public init(
        sessions: [AISession] = [],
        usage: UsageState = .unavailable(reason: "Not yet fetched"),
        todayUsage: TokenUsage = .zero,
        updatedAt: Date = Date()
    ) {
        self.sessions = sessions
        self.usage = usage
        self.todayUsage = todayUsage
        self.updatedAt = updatedAt
    }

    public static let empty = MonitorSnapshot()

    public var activeCount: Int {
        sessions.filter { $0.status == .running }.count
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

    public init(window: TimeInterval = 300, capacity: Int = 60) {
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

    public func rate(now: Date = Date()) -> BurnRate {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            return .zero
        }
        let elapsed = last.at.timeIntervalSince(first.at)
        guard elapsed > 1 else { return .zero }
        let delta = max(0, last.cumulativeTokens - first.cumulativeTokens)
        let perMinute = Double(delta) / (elapsed / 60)

        // Successive deltas make the sparkline show change, not a rising total.
        var series: [Double] = []
        series.reserveCapacity(max(0, samples.count - 1))
        for index in 1..<samples.count {
            series.append(Double(max(0, samples[index].cumulativeTokens - samples[index - 1].cumulativeTokens)))
        }
        return BurnRate(tokensPerMinute: perMinute, samples: series)
    }
}
