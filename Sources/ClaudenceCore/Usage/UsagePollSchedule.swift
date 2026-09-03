import Foundation

/// When the usage loop should wake next, and why.
///
/// ## The problem this solves
///
/// The loop slept for the user's chosen refresh interval and nothing else. A
/// failed request puts the client into its own backoff -- five seconds
/// doubling to a five minute cap -- and those two clocks knew nothing about
/// each other. With the interval set to five minutes and a request rate
/// limited, the reading came back the moment the backoff expired but the
/// screen did not learn about it until the next tick, up to five minutes
/// later. From the outside that is an application that has to be poked before
/// it will tell the truth, which is exactly what a monitor must not be.
///
/// So the loop wakes at whichever comes first. The reason travels with the
/// delay because the two wakes are not the same call: an ordinary tick honours
/// the engine's own rate limit, and a retry has to bypass it, or the loop
/// would wake on time and then decline to ask.
public enum UsagePollWake: Sendable, Equatable {
    /// The ordinary tick. Honour the engine's rate limit.
    case interval(TimeInterval)
    /// The provider's backoff has expired, or is about to. Ask anyway.
    case retry(TimeInterval)

    public var delay: TimeInterval {
        switch self {
        case .interval(let seconds), .retry(let seconds): return seconds
        }
    }

    /// Whether the next request should bypass the engine's own rate limit.
    public var isRetry: Bool {
        if case .retry = self { return true }
        return false
    }
}

public enum UsagePollSchedule {

    /// Never zero. A deadline already in the past still costs one short sleep,
    /// so a loop cannot spin on it, and one second is short enough that the
    /// delay is invisible next to a backoff measured in tens of seconds.
    public static let minimumDelay: TimeInterval = 1

    /// - Parameters:
    ///   - interval: the user's chosen refresh interval.
    ///   - retryAt: the provider's backoff deadline, or nil when it has none.
    ///   - now: the reference time, injected so this is testable.
    public static func next(
        interval: TimeInterval,
        retryAt: Date?,
        now: Date = Date()
    ) -> UsagePollWake {
        let interval = max(minimumDelay, interval)
        guard let retryAt else { return .interval(interval) }

        let untilRetry = retryAt.timeIntervalSince(now)
        // A deadline further out than the next ordinary tick is not worth
        // waking for: the tick will happen first and the client will decline
        // the request itself, which costs nothing and keeps one clock in
        // charge of the common case.
        guard untilRetry < interval else { return .interval(interval) }

        return .retry(max(minimumDelay, untilRetry))
    }
}
