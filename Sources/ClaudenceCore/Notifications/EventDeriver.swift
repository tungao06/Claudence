import Foundation

/// Turns a pair of snapshots into the events worth interrupting a human for.
///
/// Nothing pushes events at this type. It diffs `(previous, next)` and consults
/// its own memory, so the whole notification decision is a value computation
/// that tests can drive without `UserNotifications`, without a clock, and
/// without a run loop. Its one outside fact, whether a vanished session's
/// process is still alive, is injected (`isProcessLive`) rather than reached
/// for, so a test drives that as a value too.
///
/// Not thread safe by itself: it is a value with mutating methods. Callers that
/// share one instance across threads own the serialization (`NotificationBridge`
/// holds it under a lock).
public struct EventDeriver: Sendable {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Upward crossing point. Same number the menu bar calls `critical`, so
        /// the glyph turning critical and the notification are the same event.
        public var fireAtPercent: Double

        /// Lower edge of the hysteresis band.
        ///
        /// 85% sits halfway between `UsageThreshold.warning` (80) and
        /// `UsageThreshold.critical` (90). Two reasons for that width:
        ///
        /// 1. The usage API reports a coarse percentage that moves in whole
        ///    points and is recomputed server-side, so a window resting at 90.4%
        ///    can read 90 then 91 then 90 across consecutive refreshes. A one-
        ///    or two-point band would let that jitter re-arm and re-fire. Five
        ///    points cannot be jitter; it is a real retreat.
        /// 2. The band stays inside a single severity level. Re-arming only
        ///    once the window is back in `warning` territory means the
        ///    notification and the menu bar never disagree about where the user
        ///    stands.
        public var rearmBelowPercent: Double

        /// Upper bound on the remembered-completed set, so a long-running app
        /// does not accumulate session ids forever.
        public var completionMemoryLimit: Int

        public init(
            fireAtPercent: Double = Constants.UsageThreshold.critical,
            rearmBelowPercent: Double = 85.0,
            completionMemoryLimit: Int = 256
        ) {
            self.fireAtPercent = fireAtPercent
            self.rearmBelowPercent = rearmBelowPercent
            self.completionMemoryLimit = completionMemoryLimit
        }

        public static let `default` = Configuration()
    }

    // MARK: - Memory

    private struct WindowState {
        /// True when a further upward crossing is allowed to fire.
        var armed: Bool
        /// Reset point as last reported, used to notice a new period.
        var resetsAt: Date?
    }

    private let config: Configuration
    private let isProcessLive: @Sendable (AISession) -> Bool
    private var windows: [String: WindowState] = [:]
    /// Last known value of every session eligible for a completion event.
    private var known: [String: AISession] = [:]
    /// Absent from discovery but not yet believed gone.
    private var absent: [String: AISession] = [:]
    private var completed: Set<String> = []
    private var completedOrder: [String] = []

    /// The health check that separates "this session finished" from "discovery
    /// hiccupped": the same liveness test the registry adapter uses, which is
    /// also the spec's own definition of COMPLETED (section 6: "registry file
    /// removed, process gone").
    ///
    /// This is the only impure thing in the type, and it is injected so every
    /// test drives it as a value.
    public static let defaultLivenessProbe: @Sendable (AISession) -> Bool = { session in
        SessionRegistryAdapter.isAlive(pid: session.pid, procStart: session.procStart)
    }

    public init(
        configuration: Configuration = .default,
        isProcessLive: @escaping @Sendable (AISession) -> Bool = EventDeriver.defaultLivenessProbe
    ) {
        self.config = configuration
        self.isProcessLive = isProcessLive
    }

    // MARK: - Derivation

    /// Events implied by moving from `previous` to `next`.
    ///
    /// Deterministic: the same call on the same deriver state always produces
    /// the same list, in the same order.
    public mutating func events(
        from previous: MonitorSnapshot,
        to next: MonitorSnapshot
    ) -> [NotificationEvent] {
        var result = usageEvents(in: next)
        // Before idle and before completion: this is the only event whose
        // subject is blocked until the reader acts, so when a snapshot carries
        // several it is the one that should arrive first.
        result.append(contentsOf: needsInputEvents(from: previous, to: next))
        result.append(contentsOf: idleEvents(from: previous, to: next))
        result.append(contentsOf: completionEvents(from: previous, to: next))
        return result
    }

    // MARK: - Usage windows

    private mutating func usageEvents(in next: MonitorSnapshot) -> [NotificationEvent] {
        // `unavailable` is an ordinary state, not a reason to reset anything.
        // The armed flags are kept untouched so a network outage cannot cause a
        // repeat notification when the connection comes back. See spec 9.4.
        guard case .available(let reported, _) = next.usage else { return [] }

        var events: [NotificationEvent] = []
        for window in reported {
            // A window with no measured percentage says nothing. It is not 0%.
            guard let percent = window.usedPercent else { continue }

            // First sighting starts armed: a window already over the line when
            // the app launches is news to the user, even though this process
            // never watched it cross.
            var state = windows[window.name] ?? WindowState(armed: true, resetsAt: window.resetsAt)

            if state.armed == false {
                // Hysteresis: a real retreat re-arms.
                if percent < config.rearmBelowPercent {
                    state.armed = true
                } else if isNewPeriod(stored: state.resetsAt, reported: window.resetsAt, now: next.updatedAt),
                          percent < config.fireAtPercent {
                    // A new period re-arms even though the percentage never
                    // dropped through the band, which is the case a heavy user
                    // hits: 91% rolls over into a fresh window already at 88%.
                    //
                    // The `percent < fireAtPercent` guard matters. A reset point
                    // that has passed while the percentage is still above the
                    // line means the usage API has not refreshed yet, not that a
                    // new window began; re-arming there would fire a second
                    // notification about the period that just ended.
                    state.armed = true
                }
            }

            state.resetsAt = window.resetsAt

            if state.armed, percent >= config.fireAtPercent {
                events.append(.usageThreshold(window: window))
                state.armed = false
            }

            windows[window.name] = state
        }
        return events
    }

    /// A period is new when its reset point has arrived, or when the API starts
    /// reporting a later one.
    private func isNewPeriod(stored: Date?, reported: Date?, now: Date) -> Bool {
        guard let stored else { return false }
        if now >= stored { return true }
        if let reported, reported > stored { return true }
        return false
    }

    // MARK: - Session went idle

    /// A session that was working now reports itself idle, and reported it
    /// rather than merely aged into it.
    ///
    /// The rule, in full:
    ///
    /// 1. The session is present in both snapshots. A session first seen while
    ///    already idle is history, not a transition, and the app has no
    ///    business announcing history: the same reasoning that makes
    ///    `NotificationBridge` treat its first snapshot as a baseline.
    /// 2. Both statuses are derivable. A state no source can produce must not
    ///    drive a notification, on either end of the arrow; see spec section 6.
    /// 3. `lastActivityAt` strictly advanced. This is the load-bearing clause
    ///    and the reason the event can exist at all.
    ///
    ///    `SessionRegistryAdapter.mapStatus` reaches `.idle` by two routes. One
    ///    is a direct read of a `status` string the registry wrote, which is an
    ///    observed transition: Claude Code 2.1.258 rewrites
    ///    `~/.claude/sessions/<pid>.json` when a session stops working, FSEvents
    ///    delivers it, and the write moves `updatedAt`, which is what
    ///    `lastActivityAt` carries. The other is the recency fallback for an
    ///    unknown or missing status, which flips
    ///    to `.idle` once the record is older than `Constants.Watch.idleThreshold`
    ///    with no file written at all, so `lastActivityAt` sits still.
    ///
    ///    An advanced `lastActivityAt` therefore means the registry said so,
    ///    and an unchanged one means the clock did. The two can never be
    ///    confused, because a record that was just rewritten is by definition
    ///    recent and the recency branch returns `.running` for it. Without this
    ///    clause the event would fire from the passage of time, on whatever
    ///    snapshot some unrelated source happened to trigger next, which is a
    ///    notification about nothing having happened.
    /// 4. A fresh snapshot (`updatedAt` strictly advanced), for the same reason
    ///    completions need one: a replayed value is not evidence.
    ///
    /// No memory is kept, unlike completions. Idle is not terminal, so
    /// busy -> idle -> busy -> idle is two real transitions rather than one
    /// repeated; suppressing a session that flaps is the throttle's job, and
    /// its per-key cooling period already keys on `sessionIdle:<id>`.
    private func idleEvents(
        from previous: MonitorSnapshot,
        to next: MonitorSnapshot
    ) -> [NotificationEvent] {
        guard next.updatedAt > previous.updatedAt else { return [] }

        var before: [String: AISession] = [:]
        for session in previous.sessions { before[session.id] = session }

        var events: [NotificationEvent] = []
        for session in next.sessions.sorted(by: { $0.id < $1.id }) {
            guard session.status == .idle, session.status.isDerivable else { continue }
            guard let earlier = before[session.id] else { continue }
            guard earlier.status != .idle, earlier.status.isDerivable else { continue }
            guard session.lastActivityAt > earlier.lastActivityAt else { continue }
            events.append(.sessionIdle(session: session))
        }
        return events
    }

    // MARK: - Waiting on the person

    /// A session moved into `.waiting`, which means it has asked something and
    /// is doing nothing until it is answered.
    ///
    /// The rule:
    ///
    /// 1. A fresh snapshot (`updatedAt` strictly advanced). A replayed value is
    ///    not evidence, the same as for idle and completion.
    /// 2. The session is `.waiting` now and was some other derivable status
    ///    before. A first sighting is not a transition: a session already
    ///    waiting when Claudence launched has been waiting for an unknown
    ///    length of time, and announcing it as news would fire on every start.
    ///
    /// **`lastActivityAt` is deliberately not required to advance here, and
    /// that is the one place this differs from `idleEvents`.** That clause
    /// exists for idle because `mapStatus` reaches `.idle` by two routes, one
    /// of them a staleness threshold, and the advance is what tells a registry
    /// write apart from the passage of time. `.waiting` has no second route: it
    /// is produced only by a direct read of the literal string `waiting`, never
    /// by the recency fallback, so there is nothing to disambiguate. Copying
    /// the clause anyway would risk suppressing a real notification for the one
    /// event where a missed notification costs the user the most, in exchange
    /// for a check with no question left to answer.
    private func needsInputEvents(
        from previous: MonitorSnapshot,
        to next: MonitorSnapshot
    ) -> [NotificationEvent] {
        guard next.updatedAt > previous.updatedAt else { return [] }

        var before: [String: AISession] = [:]
        for session in previous.sessions { before[session.id] = session }

        var events: [NotificationEvent] = []
        for session in next.sessions.sorted(by: { $0.id < $1.id }) {
            guard session.status == .waiting, session.status.isDerivable else { continue }
            guard let earlier = before[session.id] else { continue }
            guard earlier.status != .waiting, earlier.status.isDerivable else { continue }
            events.append(.sessionNeedsInput(session: session))
        }
        return events
    }

    // MARK: - Session completion

    /// A session is completed when it is gone from discovery **and** its
    /// process is gone.
    ///
    /// The rule, in full:
    ///
    /// 1. Only sessions whose last observed `status.isDerivable` are eligible.
    ///    A state no data source can produce must not drive a notification;
    ///    see spec section 6.
    /// 2. Absence alone proves nothing. `SessionDiscovering.discover()` reports
    ///    an unreadable or missing registry directory as an empty array, so a
    ///    permission blip, a directory read racing a write, or a `procStart`
    ///    parse failure all look exactly like every session finishing at once.
    /// 3. The health check is the liveness test the registry adapter already
    ///    trusts: `kill(pid, 0)` plus a matching `procStart`. If the process is
    ///    gone, the disappearance is real and the event fires immediately. If
    ///    the process is still alive, the registry entry vanished while its
    ///    session did not, which is a discovery hiccup by definition; the
    ///    session is held pending and re-checked on every later snapshot, and a
    ///    reappearance clears it silently.
    ///
    ///    This is deliberately not a "wait for N consecutive absences" rule.
    ///    `MonitorEngine` drops a republish whose content matches the last one,
    ///    so a session that ends on an otherwise quiet machine produces exactly
    ///    one snapshot. A rule that needed a second one would never fire for the
    ///    most common completion there is.
    /// 4. A snapshot must be fresh (`updatedAt` strictly advanced) to be
    ///    evidence at all, so replaying a stale value decides nothing.
    /// 5. A fired id is remembered, so a session that is re-discovered and
    ///    vanishes again cannot announce itself twice.
    private mutating func completionEvents(
        from previous: MonitorSnapshot,
        to next: MonitorSnapshot
    ) -> [NotificationEvent] {
        record(previous.sessions)
        record(next.sessions)

        let liveIDs = Set(next.sessions.map(\.id))
        for id in liveIDs {
            absent[id] = nil
        }

        guard next.updatedAt > previous.updatedAt else { return [] }

        var events: [NotificationEvent] = []
        for id in known.keys.sorted() where !liveIDs.contains(id) {
            guard let session = known[id] else { continue }

            guard !isProcessLive(session) else {
                // The record went away but the process did not. Hold it.
                absent[id] = session
                continue
            }

            absent[id] = nil
            known[id] = nil
            guard !completed.contains(id) else { continue }
            rememberCompleted(id)
            events.append(.sessionCompleted(session: session))
        }
        return events
    }

    /// Keeps the newest value of every eligible session. Non-derivable states
    /// are never recorded, which is what makes them structurally unable to
    /// produce an event rather than merely filtered at the end.
    ///
    /// `status` is read here only to decide eligibility for a completion. The
    /// transition into `.idle` is a separate question with a separate rule,
    /// deliberately not folded in here: see `idleEvents`, which needs the two
    /// snapshots side by side and cannot work from this map, since it holds one
    /// value per session rather than a before and an after.
    private mutating func record(_ sessions: [AISession]) {
        for session in sessions where session.status.isDerivable {
            known[session.id] = session
        }
    }

    private mutating func rememberCompleted(_ id: String) {
        guard completed.insert(id).inserted else { return }
        completedOrder.append(id)
        while completedOrder.count > config.completionMemoryLimit {
            completed.remove(completedOrder.removeFirst())
        }
    }

    // MARK: - Introspection

    /// Whether a further upward crossing of this window would fire. Exposed for
    /// tests and diagnostics; the app never branches on it.
    public func isArmed(window name: String) -> Bool {
        windows[name]?.armed ?? true
    }

    /// Sessions absent from discovery whose process is still alive, so their
    /// completion is not believed yet.
    public var pendingCompletionIDs: Set<String> { Set(absent.keys) }
}
