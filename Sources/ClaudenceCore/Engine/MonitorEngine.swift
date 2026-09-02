import Foundation

/// Composes the adapters into snapshots. Owns no I/O of its own: every source
/// arrives through a protocol so the engine is testable with fakes and so a
/// second provider costs a file rather than a refactor.
public actor MonitorEngine {
    private let discovery: any SessionDiscovering
    private let transcripts: any TranscriptReading
    private let usageProvider: (any UsageProviding)?
    private let store: (any ClaudenceStoring)?

    private var snapshot = MonitorSnapshot.empty
    private var burnTrackers: [String: BurnRateTracker] = [:]
    private var accumulated: [String: TokenUsage] = [:]
    private var lastUsageFetch: Date?
    private var observers: [UUID: @Sendable (MonitorSnapshot) -> Void] = [:]
    private var lastUpserted: [String: AISession] = [:]
    private var todayCache: (usage: TokenUsage, at: Date)?

    /// How long a `dailyTotals` result is reused when no session produced new
    /// tokens. Bounded so a rollover past midnight cannot pin the figure to
    /// yesterday, short enough that the number is never visibly wrong.
    static let todayTotalTTL: TimeInterval = 60

    public init(
        discovery: any SessionDiscovering,
        transcripts: any TranscriptReading,
        usageProvider: (any UsageProviding)? = nil,
        store: (any ClaudenceStoring)? = nil
    ) {
        self.discovery = discovery
        self.transcripts = transcripts
        self.usageProvider = usageProvider
        self.store = store
    }

    // MARK: - Observation

    @discardableResult
    public func observe(_ handler: @escaping @Sendable (MonitorSnapshot) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        handler(snapshot)
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    public func current() -> MonitorSnapshot { snapshot }

    // MARK: - Refresh

    /// Cheap pass: discovery plus incremental transcript reads. Safe to call on
    /// every filesystem event because both sources are event-sized, not full scans.
    public func refreshSessions() {
        EngineCounters.shared.countSessionRefresh()
        let discovered = discovery.discover()
        let now = Date()
        var live: [AISession] = []
        live.reserveCapacity(discovered.count)
        var producedTokens = false

        for var session in discovered {
            let delta = transcripts.readIncremental(
                sessionID: session.id,
                workingDirectory: session.workingDirectory
            )
            EngineCounters.shared.countTranscriptRead(
                withData: delta.recordsParsed > 0 || delta.recordsSkipped > 0
            )

            var running = accumulated[session.id] ?? .zero
            running += delta.usage
            accumulated[session.id] = running
            session.usage = running

            if let activity = delta.latestActivity {
                session.currentActivity = activity
            }
            if let model = delta.latestModel {
                session.model = model
            }
            if let stamp = delta.latestTimestamp, stamp > session.lastActivityAt {
                session.lastActivityAt = stamp
            }

            // A sample is only worth recording when the total moved, or when
            // the tracker is empty. Recording an identical total on every
            // filesystem event grows the ring, changes the sparkline series,
            // and republishes a burn rate that did not change.
            var tracker = burnTrackers[session.id] ?? BurnRateTracker()
            if tracker.lastCumulativeTokens != running.total {
                tracker.record(tokens: running.total, at: now)
                burnTrackers[session.id] = tracker
            }

            // An unchanged session is already in the store. Writing it again
            // on every filesystem event buys nothing and costs a statement.
            if lastUpserted[session.id] != session {
                store?.upsert(session: session)
                lastUpserted[session.id] = session
            }
            if delta.usage.total > 0 {
                store?.recordUsageSample(sessionID: session.id, usage: running, at: now)
                producedTokens = true
            }
            live.append(session)
        }

        reapVanished(liveIDs: Set(live.map(\.id)), at: now)

        let next = MonitorSnapshot(
            sessions: live.sorted { $0.lastActivityAt > $1.lastActivityAt },
            usage: snapshot.usage,
            todayUsage: todayTotal(live: live, producedTokens: producedTokens, now: now),
            updatedAt: now
        )
        publishIfChanged(next)
    }

    /// Network pass, rate limited by the cache TTL. Kept separate from
    /// `refreshSessions` so filesystem churn never triggers a request.
    public func refreshUsage(force: Bool = false) async {
        guard let usageProvider else { return }
        if !force, let last = lastUsageFetch,
           Date().timeIntervalSince(last) < Constants.Usage.cacheTTL {
            return
        }
        lastUsageFetch = Date()
        EngineCounters.shared.countUsageFetch()
        let state = await usageProvider.fetch()
        publishIfChanged(
            MonitorSnapshot(
                sessions: snapshot.sessions,
                usage: state,
                todayUsage: snapshot.todayUsage,
                updatedAt: Date()
            )
        )
    }

    public func burnRate(forSession id: String) -> BurnRate {
        burnTrackers[id]?.rate() ?? .zero
    }

    // MARK: - Internals

    /// A session that disappeared from discovery has ended. Its accumulator is
    /// dropped so a recycled id cannot inherit a stale total.
    private func reapVanished(liveIDs: Set<String>, at date: Date) {
        let vanished = Set(snapshot.sessions.map(\.id)).subtracting(liveIDs)
        for id in vanished {
            store?.markEnded(sessionID: id, at: date)
            burnTrackers[id] = nil
            accumulated[id] = nil
            lastUpserted[id] = nil
        }
    }

    /// Today's total prefers the store, which survives restarts. With no store
    /// it falls back to the live sessions, which is honest but resets on launch.
    ///
    /// The query only runs when something could have moved the number, or when
    /// the cached figure is older than `todayTotalTTL`. Running an aggregate on
    /// every filesystem event is the kind of cost that has no visible effect.
    private func todayTotal(live: [AISession], producedTokens: Bool, now: Date) -> TokenUsage {
        guard let store else {
            return live.reduce(TokenUsage.zero) { $0 + $1.usage }
        }
        if !producedTokens, let cached = todayCache,
           now.timeIntervalSince(cached.at) < MonitorEngine.todayTotalTTL {
            return cached.usage
        }
        let total = store.dailyTotals(days: 1).first?.usage ?? .zero
        todayCache = (total, now)
        return total
    }

    /// The single write path for `snapshot`.
    ///
    /// A snapshot whose visible content matches the one already published is
    /// dropped: the old value is kept, no observer is called, and no view is
    /// invalidated. `@Observable` fires on assignment rather than on change, so
    /// this suppression has to happen here — the view model cannot undo a
    /// mutation it has already been handed. Keeping the *old* snapshot rather
    /// than storing the new one with a fresh `updatedAt` keeps the engine's own
    /// state and every observer's state identical.
    private func publishIfChanged(_ next: MonitorSnapshot) {
        guard !next.hasSameContent(as: snapshot) else {
            EngineCounters.shared.countSuppressedPublish()
            return
        }
        snapshot = next
        EngineCounters.shared.countSnapshotPublish()
        for handler in observers.values {
            handler(next)
        }
    }
}

/// The engine's view of persistence. The store module implements this; keeping
/// it here means the engine compiles without knowing which database is behind it.
public protocol ClaudenceStoring: CursorStoring {
    func upsert(session: AISession)
    func markEnded(sessionID: String, at: Date)
    func recordUsageSample(sessionID: String, usage: TokenUsage, at: Date)
    func dailyTotals(days: Int) -> [(day: String, usage: TokenUsage)]
    func projectTotals(since: Date?) -> [(project: String, usage: TokenUsage, sessionCount: Int)]
}
