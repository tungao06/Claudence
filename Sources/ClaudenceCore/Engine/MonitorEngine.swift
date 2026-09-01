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
        let discovered = discovery.discover()
        let now = Date()
        var live: [AISession] = []
        live.reserveCapacity(discovered.count)

        for var session in discovered {
            let delta = transcripts.readIncremental(
                sessionID: session.id,
                workingDirectory: session.workingDirectory
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

            var tracker = burnTrackers[session.id] ?? BurnRateTracker()
            tracker.record(tokens: running.total, at: now)
            burnTrackers[session.id] = tracker

            store?.upsert(session: session)
            if delta.usage.total > 0 {
                store?.recordUsageSample(sessionID: session.id, usage: running, at: now)
            }
            live.append(session)
        }

        reapVanished(liveIDs: Set(live.map(\.id)), at: now)

        snapshot = MonitorSnapshot(
            sessions: live.sorted { $0.lastActivityAt > $1.lastActivityAt },
            usage: snapshot.usage,
            todayUsage: todayTotal(live: live),
            updatedAt: now
        )
        publish()
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
        let state = await usageProvider.fetch()
        snapshot = MonitorSnapshot(
            sessions: snapshot.sessions,
            usage: state,
            todayUsage: snapshot.todayUsage,
            updatedAt: Date()
        )
        publish()
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
        }
    }

    /// Today's total prefers the store, which survives restarts. With no store
    /// it falls back to the live sessions, which is honest but resets on launch.
    private func todayTotal(live: [AISession]) -> TokenUsage {
        if let store, let today = store.dailyTotals(days: 1).first {
            return today.usage
        }
        return live.reduce(TokenUsage.zero) { $0 + $1.usage }
    }

    private func publish() {
        let current = snapshot
        for handler in observers.values {
            handler(current)
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
