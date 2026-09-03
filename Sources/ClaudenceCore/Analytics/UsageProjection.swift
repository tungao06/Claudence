import Foundation

/// When a usage window runs out, if the current rate holds.
///
/// The meter answers "how much is gone" and the question a user actually has at
/// 11:04, with the seven-day window at 66% and four hours of Opus work planned,
/// is whether the work fits. The gap between the projected exhaustion and the
/// reset is the whole decision, which is why the two are shown together.
///
/// Nothing new is read for this. `UsageWindow` already carries `usedPercent` and
/// `resetsAt`, and the usage refresh already runs on its own cadence; the
/// projector keeps the last few readings of each window and divides.
///
/// Percent per minute, not tokens per minute. The endpoint reports a share of a
/// window whose size it never states, so a token rate cannot be converted into
/// one without inventing the window's capacity. Measuring the share itself needs
/// no such invention, and it is the same quantity the bar draws.
public enum UsageProjection: Sendable, Equatable {
    /// The window empties at this moment, before it resets.
    case exhausts(at: Date)
    /// The current rate does not empty the window before it resets. The reset is
    /// then the binding moment, and it is already on screen.
    case holdsUntilReset
    /// Not derivable. Rendered as `Rate unavailable`, never as a time.
    case rateUnavailable(Reason)

    public enum Reason: Sendable, Equatable {
        /// Fewer than two readings, or too little time between them. A
        /// projection from one sample is a fabricated number, and this feature
        /// is the one most able to produce one.
        case notEnoughSamples
        /// The share has not moved over the measured span, so there is no rate
        /// to project from. Distinct from "it holds": nothing is being spent at
        /// all, which is not the same as spending slowly enough.
        case notMoving
        /// The window itself did not report a percentage or a reset.
        case windowIncomplete
    }

    public var date: Date? {
        if case .exhausts(let at) = self { return at }
        return nil
    }
}

/// Keeps the recent readings of each usage window and projects from them.
///
/// A value type with an explicit `now` on every call, for the same reason
/// `BurnRateTracker` has one: a rate measured to the newest sample rather than
/// to the present reports a burst as though it were still happening. Readings
/// older than `window` are dropped on both write and read, because the usage
/// refresh only records when the figure moves.
public struct UsageProjector: Sendable, Equatable {
    public struct Reading: Sendable, Equatable {
        public let at: Date
        public let usedPercent: Double

        public init(at: Date, usedPercent: Double) {
            self.at = at
            self.usedPercent = usedPercent
        }
    }

    /// How far back a rate is measured. Forty minutes covers several usage
    /// refreshes at the default cadence and is short enough that a burst which
    /// has stopped decays out of it within the hour.
    public static let measurementWindow: TimeInterval = 40 * 60

    /// The shortest span a rate may be measured over. Below this, two readings
    /// a minute apart with a rounding step between them produce a rate an order
    /// of magnitude out.
    public static let minimumSpan: TimeInterval = 5 * 60

    private var readings: [String: [Reading]] = [:]
    private let window: TimeInterval
    private let capacity: Int

    public init(
        window: TimeInterval = UsageProjector.measurementWindow,
        capacity: Int = 60
    ) {
        self.window = window
        self.capacity = capacity
    }

    /// Records what a window reported, ignoring a repeat of the last figure so
    /// a quiet hour does not fill the ring with the same number.
    public mutating func record(_ usageWindow: UsageWindow, at date: Date) {
        guard let percent = usageWindow.usedPercent else { return }
        var series = readings[usageWindow.name] ?? []
        // A repeated figure is kept twice and no more: once where it first
        // appeared and once at the newest moment it was still true. That pair is
        // what makes "not moving" measurable, and dropping the repeats entirely
        // would leave a quiet window looking like one nobody has read yet.
        if series.count >= 2,
           series[series.count - 1].usedPercent == percent,
           series[series.count - 2].usedPercent == percent {
            series[series.count - 1] = Reading(at: date, usedPercent: percent)
        } else {
            series.append(Reading(at: date, usedPercent: percent))
        }
        let cutoff = date.addingTimeInterval(-window)
        series.removeAll { $0.at < cutoff }
        if series.count > capacity { series.removeFirst(series.count - capacity) }
        readings[usageWindow.name] = series
    }

    /// Percent consumed per minute over the measured span, or nil when there is
    /// no honest figure.
    public func percentPerMinute(for name: String, now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-window)
        let live = (readings[name] ?? []).filter { $0.at >= cutoff }
        guard let first = live.first, let last = live.last, live.count >= 2 else { return nil }
        let elapsed = max(now, last.at).timeIntervalSince(first.at)
        guard elapsed >= UsageProjector.minimumSpan else { return nil }
        let rise = last.usedPercent - first.usedPercent
        // A fall means the window reset between readings. That is not a
        // negative rate, it is a new window, and the honest answer is that this
        // one has nothing measured yet.
        guard rise > 0 else { return rise == 0 ? 0 : nil }
        return rise / (elapsed / 60)
    }

    public func projection(for usageWindow: UsageWindow, now: Date) -> UsageProjection {
        guard let remaining = usageWindow.remainingPercent, let resetsAt = usageWindow.resetsAt else {
            return .rateUnavailable(.windowIncomplete)
        }
        guard let rate = percentPerMinute(for: usageWindow.name, now: now) else {
            return .rateUnavailable(.notEnoughSamples)
        }
        guard rate > 0 else { return .rateUnavailable(.notMoving) }

        let minutesLeft = remaining / rate
        let exhaustsAt = now.addingTimeInterval(minutesLeft * 60)
        return exhaustsAt < resetsAt ? .exhausts(at: exhaustsAt) : .holdsUntilReset
    }

    /// Which window runs out first, among those that run out at all.
    ///
    /// The tile gives 21% on five hours and 66% on seven days equal weight
    /// today, and it is the seven-day one that ends the day. Naming the binding
    /// window is the cheapest way to say which number to read first.
    public func bindingWindow(among windows: [UsageWindow], now: Date) -> (window: UsageWindow, at: Date)? {
        windows
            .compactMap { candidate -> (window: UsageWindow, at: Date)? in
                guard let at = projection(for: candidate, now: now).date else { return nil }
                return (candidate, at)
            }
            .min { $0.at < $1.at }
    }
}

/// Who is spending it, for the tile that names the session responsible.
public enum BurnAttribution {
    /// The session with the largest share of the current burn, and that share.
    ///
    /// Nil when nothing is burning, which is an ordinary state and not an
    /// absence of data: a share of zero has no largest member. Ties are broken
    /// by session id so the display does not flicker between two equal rates.
    public static func leader(
        rates: [String: Double]
    ) -> (sessionID: String, share: Double)? {
        let total = rates.values.reduce(0, +)
        guard total > 0 else { return nil }
        let best = rates
            .filter { $0.value > 0 }
            .max { left, right in
                left.value == right.value ? left.key > right.key : left.value < right.value
            }
        guard let best else { return nil }
        return (best.key, best.value / total)
    }
}
