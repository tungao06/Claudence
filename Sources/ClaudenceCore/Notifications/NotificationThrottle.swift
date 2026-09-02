import Foundation

/// The last gate before anything reaches Notification Center.
///
/// `EventDeriver` already refuses to emit an event twice for the same cause.
/// This type defends against the cases the deriver cannot see: a source that
/// flaps, a machine waking from sleep and retiring a dozen stale registry files
/// in one pass, a future event type with looser edges. Spec section 10:
/// "a monitoring tool that spams is uninstalled".
///
/// Every decision is taken against an injected clock, so the tests cover the
/// cooling period and the ceiling without sleeping.
///
/// Thread safe. The engine publishes snapshots from inside its actor and the
/// bridge forwards them straight through, so `admit` is called from whatever
/// thread ran the refresh.
public final class NotificationThrottle: @unchecked Sendable {

    // MARK: - Policy

    /// Minimum gap between two notifications sharing a key.
    ///
    /// 30 minutes. The fastest thing Claudence notifies about is the five-hour
    /// window, and the last 10% of a five-hour window is roughly half an hour
    /// of budget at a steady burn. A repeat sooner than that could not carry a
    /// materially different number, so it would be noise; a repeat at 30
    /// minutes tells the user something moved.
    public static let defaultCoolingPeriod: TimeInterval = 30 * 60

    /// Ceiling on total notifications inside `defaultGlobalWindow`.
    ///
    /// Five per ten minutes. A burst larger than this is pathological by
    /// definition: the registry directory being recreated, a wake from sleep
    /// reaping stale files, a source flapping. Past about five, notifications
    /// stop informing and become a wall to dismiss, which is the failure mode
    /// that gets the app uninstalled. Dropping the excess is safe because every
    /// suppressed event is, by construction, also visible in the popover.
    public static let defaultGlobalLimit = 5
    public static let defaultGlobalWindow: TimeInterval = 10 * 60

    // MARK: - State

    private let coolingPeriod: TimeInterval
    private let globalLimit: Int
    private let globalWindow: TimeInterval
    private let clock: @Sendable () -> Date

    private let lock = NSLock()
    private var lastFired: [String: Date] = [:]
    private var recent: [Date] = []
    private var suppressed = 0

    public init(
        coolingPeriod: TimeInterval = NotificationThrottle.defaultCoolingPeriod,
        globalLimit: Int = NotificationThrottle.defaultGlobalLimit,
        globalWindow: TimeInterval = NotificationThrottle.defaultGlobalWindow,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.coolingPeriod = coolingPeriod
        self.globalLimit = globalLimit
        self.globalWindow = globalWindow
        self.clock = clock
    }

    // MARK: - Admission

    /// Whether this event may be delivered now.
    ///
    /// Consuming: a `true` result records the delivery and starts the cooling
    /// period for its key. Call it once per event, at the point of delivery.
    ///
    /// Deduplication by `(kind, subject)` and the per-key rate limit are the
    /// same mechanism: the key is the identity, and two events sharing a key
    /// inside the cooling period are the same notification as far as a human is
    /// concerned. Keying on the pair rather than on the session id alone means a
    /// chatty usage window can never mute a session completion.
    public func admit(_ event: NotificationEvent) -> Bool {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }

        let key = event.throttleKey
        if let last = lastFired[key], now.timeIntervalSince(last) < coolingPeriod {
            suppressed += 1
            return false
        }

        // Pruned before counting so the ceiling is a rolling window rather than
        // a bucket that has to be reset by something.
        let cutoff = now.addingTimeInterval(-globalWindow)
        recent.removeAll { $0 < cutoff }
        guard recent.count < globalLimit else {
            // Deliberately does not start a cooling period: the event lost to a
            // burst, not to its own key, and should be admitted normally once
            // the burst drains.
            suppressed += 1
            return false
        }

        lastFired[key] = now
        recent.append(now)
        return true
    }

    /// Convenience for a whole derivation pass. Preserves order.
    public func admit(_ events: [NotificationEvent]) -> [NotificationEvent] {
        events.filter { admit($0) }
    }

    // MARK: - Diagnostics

    /// Events refused since this throttle was made. Surfaced for diagnostics so
    /// silent suppression stays observable rather than invisible.
    public var suppressedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return suppressed
    }

    /// Notifications admitted inside the current global window.
    public var admittedInWindow: Int {
        let cutoff = clock().addingTimeInterval(-globalWindow)
        lock.lock(); defer { lock.unlock() }
        return recent.filter { $0 >= cutoff }.count
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        lastFired.removeAll()
        recent.removeAll()
        suppressed = 0
    }
}
