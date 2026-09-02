import Foundation

/// Composes the adapters into snapshots. Owns no I/O of its own: every source
/// arrives through a protocol so the engine is testable with fakes and so a
/// second provider costs a file rather than a refactor.
public actor MonitorEngine {
    private let discovery: any SessionDiscovering
    private let transcripts: any TranscriptReading
    private let usageProvider: (any UsageProviding)?
    private let store: (any ClaudenceStoring)?
    /// Optional because the engine is testable with fakes that have no
    /// filesystem behind them. Absent, subagent tokens are simply not counted
    /// and `subagentCount` stays zero — never silently folded into the parent.
    private let subagents: SubagentTracker?

    private var snapshot = MonitorSnapshot.empty
    private var burnTrackers: [String: BurnRateTracker] = [:]
    private var accumulated: [String: TokenUsage] = [:]
    private var subagentsBySession: [String: [AISubagent]] = [:]
    private var accumulatedTools: [String: [String: Int]] = [:]
    private var accumulatedPaths: [String: [String]] = [:]
    private var accumulatedTrail: [String: [TimedActivity]] = [:]
    private var accumulatedRecords: [String: Int] = [:]
    /// Sessions whose accumulators have been seeded from the store this
    /// process. Read cursors are persisted but the totals they correspond to
    /// were not, so without seeding a session resumed after a relaunch counts
    /// only the records written since the last run and reports a total far
    /// below what it actually spent.
    private var seeded: Set<String> = []
    /// The newest per-request usage block seen for each session, kept because a
    /// delta with no new records carries none and the context meter should hold
    /// its last real reading rather than flicker to unavailable.
    private var lastRequestUsage: [String: TokenUsage] = [:]
    /// Guards `refreshSessions` against overlapping passes. See its doc comment.
    private var isRefreshing = false
    private var hasPendingRefresh = false
    private var lastUsageFetch: Date?
    private var observers: [UUID: @Sendable (MonitorSnapshot) -> Void] = [:]
    private var lastUpserted: [String: AISession] = [:]
    private var todayCache: (usage: TokenUsage, at: Date)?
    /// When the rollups were last rebuilt, and for which local day.
    private var lastRollupRepair: (day: String, at: Date)?

    /// How long a `dailyTotals` result is reused when no session produced new
    /// tokens. Bounded so a rollover past midnight cannot pin the figure to
    /// yesterday, short enough that the number is never visibly wrong.
    static let todayTotalTTL: TimeInterval = 60

    /// The shortest gap between two rollup repairs. A repair reads every
    /// session and every sample, so it is far too expensive to run per
    /// filesystem event, and far too cheap to be worth skipping once a minute
    /// while a session that started yesterday is still spending.
    static let rollupRepairInterval: TimeInterval = 60

    public init(
        discovery: any SessionDiscovering,
        transcripts: any TranscriptReading,
        usageProvider: (any UsageProviding)? = nil,
        store: (any ClaudenceStoring)? = nil,
        subagents: SubagentTracker? = nil
    ) {
        self.discovery = discovery
        self.transcripts = transcripts
        self.usageProvider = usageProvider
        self.store = store
        self.subagents = subagents
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
    /// Single flight. Two passes cannot overlap, and a request that arrives
    /// while one is running is coalesced into it rather than queued.
    ///
    /// This became necessary when the subagent read was added: `await
    /// subagents.refresh` is the first suspension point ever placed inside the
    /// session loop, and actor isolation does not survive a suspension. The
    /// watcher fires a detached task per debounced burst, so two passes could
    /// interleave. The failure is not a data race, it is worse to reason about:
    /// pass A computes a total, suspends, pass B computes a larger total and
    /// upserts it, then pass A resumes and upserts its smaller one, so
    /// `applyRollup` subtracts the larger and adds the smaller and the day's
    /// figure walks backwards. It self-heals on the next pass, which is exactly
    /// what makes it hard to notice.
    ///
    /// Coalescing rather than queuing is right here because a refresh is a full
    /// re-read of current state, not an increment: running it twice in a row
    /// produces the same answer as running it once.
    public func refreshSessions() async {
        if isRefreshing {
            hasPendingRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if hasPendingRefresh {
                hasPendingRefresh = false
                Task { await self.refreshSessions() }
            }
        }
        await performRefresh()
    }

    private func performRefresh() async {
        EngineCounters.shared.countSessionRefresh()
        let discovered = discovery.discover()
        let now = Date()
        var live: [AISession] = []
        live.reserveCapacity(discovered.count)
        var producedTokens = false

        for var session in discovered {
            // A seed that did not answer means the stored total is unknown,
            // and the transcript read below is what would advance the cursor
            // past records the accumulator has no baseline for. The cursor and
            // the total only stay correct together, so the whole session is
            // skipped and retried on the next pass rather than being read,
            // undercounted, and written back over a good row.
            //
            // The last published view is carried forward so the session keeps
            // its place: dropping it here would show a disappearing row and
            // would make `reapVanished` treat a store hiccup as a session that
            // ended, discarding the very accumulator being protected.
            guard seedIfNeeded(session) else {
                EngineCounters.shared.countSkippedUnseededSession()
                if let previous = snapshot.sessions.first(where: { $0.id == session.id }) {
                    live.append(previous)
                }
                continue
            }

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

            // Accumulated across the session, not just this delta.
            var counts = accumulatedTools[session.id] ?? [:]
            for (name, count) in delta.toolCounts { counts[name, default: 0] += count }
            accumulatedTools[session.id] = counts
            session.toolCounts = counts

            var paths = accumulatedPaths[session.id] ?? []
            for path in delta.filePaths {
                paths.removeAll { $0 == path }
                paths.append(path)
            }
            if paths.count > 12 { paths.removeFirst(paths.count - 12) }
            accumulatedPaths[session.id] = paths
            session.filePaths = paths

            var trail = accumulatedTrail[session.id] ?? []
            trail.append(contentsOf: delta.activityTrail)
            if trail.count > 24 { trail.removeFirst(trail.count - 24) }
            accumulatedTrail[session.id] = trail
            session.activityTrail = trail

            var records = accumulatedRecords[session.id] ?? 0
            records += delta.recordsParsed
            accumulatedRecords[session.id] = records
            session.recordsParsed = records

            // Subagents are a separate source: the parent transcript contains
            // none of their records. Read before the burn tracker samples, so
            // the rate reflects what the session actually spent.
            if let subagents {
                let spawned = await subagents.refresh(
                    sessionID: session.id,
                    workingDirectory: session.workingDirectory
                )
                subagentsBySession[session.id] = spawned
                session.subagentUsage = spawned.reduce(TokenUsage.zero) { $0 + $1.usage }
                session.subagentCount = spawned.count
            }

            if let tier = delta.serviceTier { session.serviceTier = tier }
            if let branch = delta.gitBranch { session.gitBranch = branch }
            // Carried forward across passes with no new records, so the meter
            // does not blank out whenever the session is briefly quiet.
            if let request = delta.lastRequestUsage {
                lastRequestUsage[session.id] = request
            }
            session.lastRequestUsage = lastRequestUsage[session.id]
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
            //
            // The sample is the combined total. A session that delegates most
            // of its work to subagents spends real tokens the whole time, and a
            // rate computed from the parent transcript alone reads as idle
            // while the bill keeps moving.
            let combinedTotal = session.combinedUsage.total
            let previousCombinedTotal = burnTrackers[session.id]?.lastCumulativeTokens
            var tracker = burnTrackers[session.id] ?? BurnRateTracker()
            if tracker.lastCumulativeTokens != combinedTotal {
                tracker.record(tokens: combinedTotal, at: now)
                burnTrackers[session.id] = tracker
            }

            // An unchanged session is already in the store. Writing it again
            // on every filesystem event buys nothing and costs a statement.
            if lastUpserted[session.id] != session {
                store?.upsert(session: session)
                lastUpserted[session.id] = session
            }
            // Keyed on the combined total rather than on the parent delta, so a
            // pass in which only a subagent spent anything still records a
            // sample and still invalidates the cached daily figure.
            if previousCombinedTotal != combinedTotal {
                store?.recordUsageSample(sessionID: session.id, usage: session.combinedUsage, at: now)
                producedTokens = true
            }
            live.append(session)
        }

        await reapVanished(liveIDs: Set(live.map(\.id)), at: now)

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
    ///
    /// - Parameter minimumInterval: the floor between two requests. It defaults
    ///   to the cache TTL, but the caller can lower it, because the user can
    ///   choose a refresh interval shorter than the TTL and a rate limit the
    ///   caller cannot lower would silently ignore that choice.
    public func refreshUsage(
        force: Bool = false,
        minimumInterval: TimeInterval = Constants.Usage.cacheTTL
    ) async {
        guard let usageProvider else { return }
        if !force, let last = lastUsageFetch,
           Date().timeIntervalSince(last) < minimumInterval {
            return
        }
        lastUsageFetch = Date()
        EngineCounters.shared.countUsageFetch()
        // The floor travels with the request: the engine's own rate limit and
        // the provider's cache have to agree, or the tighter of the two wins
        // silently.
        let state = await usageProvider.fetch(minimumInterval: force ? 0 : minimumInterval)
        publishIfChanged(
            MonitorSnapshot(
                sessions: snapshot.sessions,
                usage: state,
                todayUsage: snapshot.todayUsage,
                updatedAt: Date()
            )
        )
    }

    /// Subagents of a session, newest activity first. Empty is ordinary.
    public func subagents(forSession id: String) -> [AISubagent] {
        subagentsBySession[id] ?? []
    }

    public func burnRate(forSession id: String) -> BurnRate {
        burnTrackers[id]?.rate() ?? .zero
    }

    // MARK: - Internals

    /// Adopts a session's persisted total before its first delta of this run.
    ///
    /// The read cursor and the total have to move together. The cursor survives
    /// a relaunch in SQLite; the total lived only in this dictionary, so a
    /// resumed session used to start again from zero while its reader carried
    /// on from byte N. The visible effect was a live total that collapsed after
    /// every restart, and then a rollup rewritten downward to match, because
    /// `upsert` replaces a session's stored figures rather than adding to them.
    ///
    /// Seeding once per process is enough: after the first pass the in-memory
    /// accumulator is the authority and the store is downstream of it.
    ///
    /// - Returns: whether the session may be processed this pass. False means
    ///   the store did not answer, so nothing is known about the stored total
    ///   and the caller must leave the session alone until the next pass.
    private func seedIfNeeded(_ session: AISession) -> Bool {
        guard !seeded.contains(session.id) else { return true }
        guard let store else {
            seeded.insert(session.id)
            return true
        }
        // An unavailable store has no database behind it at all: it never
        // answers and never persists, and that is permanent for the life of
        // the process. There is therefore no stored total to lose and no
        // rollup to rewrite, so it is treated as no store rather than as a
        // read to retry, which would otherwise skip every session forever and
        // show an empty popover on a machine whose only fault is that it
        // cannot open a database file.
        if case .unavailable = store.health {
            seeded.insert(session.id)
            return true
        }
        // Marked seeded only once the store is known to have answered. A failed
        // read and an absent row both return nil, and treating a failure as
        // "nothing stored" would pin the accumulator at zero for the life of
        // the process while the cursor is already at byte N: a permanent
        // undercount that then propagates into the rollup on the next upsert.
        //
        // The signal is the store's own count of queries that did not answer,
        // the same one `AnalyticsService` reads. This compared `health` either
        // side of the read until 2026-09-03, which is a transition and not an
        // outcome: health latched at `.degraded` on the first failure, so every
        // failure after it produced nothing to observe and the read was taken
        // as "nothing stored". Latching is fixed in the store, but a transition
        // stays the wrong question even when health is free to move.
        let before = store.unansweredQueries
        let stored = store.session(id: session.id)
        guard store.unansweredQueries == before else { return false }
        seeded.insert(session.id)
        guard let stored else { return true }
        accumulated[session.id] = stored.usage
        // A session read back from the store carries no per-record detail: the
        // schema keeps tokens, not tool names or paths. Those accumulators stay
        // empty and rebuild from the records read after the resume point, which
        // is honest about what this process has actually observed.
        return true
    }

    /// A session that disappeared from discovery has ended. Its accumulator is
    /// dropped so a recycled id cannot inherit a stale total.
    private func reapVanished(liveIDs: Set<String>, at date: Date) async {
        let vanished = Set(snapshot.sessions.map(\.id)).subtracting(liveIDs)
        for id in vanished {
            store?.markEnded(sessionID: id, at: date)
            burnTrackers[id] = nil
            accumulated[id] = nil
            lastUpserted[id] = nil
            // Every per-session accumulator, not only the token one. Leaving
            // any of these behind lets a recycled session id inherit another
            // session's tool counts, paths, or timeline.
            accumulatedTools[id] = nil
            accumulatedPaths[id] = nil
            accumulatedTrail[id] = nil
            accumulatedRecords[id] = nil
            lastRequestUsage[id] = nil
            subagentsBySession[id] = nil
            seeded.remove(id)
            await subagents?.forget(sessionID: id)
        }
    }

    /// Today's total prefers the store, which survives restarts. With no store
    /// it falls back to the live sessions, which is honest but resets on launch.
    ///
    /// Nil when the store did not answer. A failed aggregate and a day with
    /// nothing on it both come back empty, and only the store's own count of
    /// unanswered queries separates them; publishing the empty case as zero
    /// printed `Tokens today 0` as a measurement.
    ///
    /// The query only runs when something could have moved the number, or when
    /// the cached figure is older than `todayTotalTTL`. Running an aggregate on
    /// every filesystem event is the kind of cost that has no visible effect.
    /// Only an answered read is cached: caching a failure would hold the gap
    /// open for a minute after the store recovered.
    private func todayTotal(live: [AISession], producedTokens: Bool, now: Date) -> TokenUsage? {
        guard let store else {
            return live.reduce(TokenUsage.zero) { $0 + $1.combinedUsage }
        }
        if !producedTokens, let cached = todayCache,
           now.timeIntervalSince(cached.at) < MonitorEngine.todayTotalTTL {
            return cached.usage
        }

        repairRollupsIfStale(store: store, live: live, now: now)

        let before = store.unansweredQueries
        let total = store.dailyTotals(days: 1).first?.usage ?? .zero
        guard store.unansweredQueries == before else { return nil }
        todayCache = (total, now)
        return total
    }

    /// Rebuilds the day-keyed rollups when the incremental attribution could be
    /// stale, and not otherwise.
    ///
    /// `upsert(session:)` keys a session's whole spend on the day it started,
    /// so a session that began yesterday and is still running has everything it
    /// spends today filed under yesterday, and today's row reads nothing at
    /// all. Only the store can put that right, from the samples; this decides
    /// when to ask.
    ///
    /// Three reasons to ask, and no others:
    ///
    /// - the first pass of the process, which heals whatever drifted while the
    ///   app was not running;
    /// - the local day changing under a running app, which is the midnight this
    ///   defect is named after and is not allowed to wait for the interval;
    /// - a live session that started before today, which is the only shape that
    ///   keeps misfiling tokens while the app watches. Throttled to
    ///   `rollupRepairInterval`, because that misfiling is corrected within a
    ///   minute and a rebuild per filesystem event is not a cost worth paying
    ///   for a fresher one.
    ///
    /// The repair moves tokens between days and never changes their sum, so the
    /// incremental writes that land between two repairs are wrong about the day
    /// and right about the total. See `ClaudenceStore.recomputeRollups`.
    private func repairRollupsIfStale(store: any ClaudenceStoring, live: [AISession], now: Date) {
        let today = ClaudenceStore.dayString(for: now)
        guard let last = lastRollupRepair else {
            store.recomputeRollups()
            lastRollupRepair = (today, now)
            return
        }
        if last.day != today {
            store.recomputeRollups()
            lastRollupRepair = (today, now)
            return
        }
        guard now.timeIntervalSince(last.at) >= MonitorEngine.rollupRepairInterval else { return }
        guard live.contains(where: { ClaudenceStore.dayString(for: $0.startedAt) != today }) else { return }
        store.recomputeRollups()
        lastRollupRepair = (today, now)
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

/// What every persistence seam has to say about its own outcomes.
///
/// Declared once and refined by both store protocols rather than spelled out in
/// each, because the two seams have already drifted once: the parent side
/// learned to tell a failed read from an absent row while the subagent side
/// still could not, and a subagent seed that read `[]` from a failed query
/// pinned an accumulator at zero against a cursor already at byte N. A third
/// seam should not be able to repeat that by forgetting to declare these.
public protocol StoreOutcomeReporting {
    /// The store's condition. Read only to recognise `.unavailable`, which is
    /// permanent and means there is no database at all, so there is nothing to
    /// resume from and nothing to corrupt.
    var health: StoreHealth { get }
    /// Monotonic count of queries that failed or never ran. A caller that reads
    /// it either side of its own query learns whether that query answered,
    /// which health cannot say once it has settled and has nowhere left to
    /// move. A failed read and an empty result are indistinguishable in the
    /// return value, and no caller may mistake one for the other when seeding
    /// an accumulated total.
    var unansweredQueries: UInt64 { get }
}

/// The engine's view of persistence. The store module implements this; keeping
/// it here means the engine compiles without knowing which database is behind it.
public protocol ClaudenceStoring: CursorStoring, StoreOutcomeReporting {
    /// The last persisted view of a session, used to seed the engine's
    /// accumulators so a resumed read cursor does not restart its total.
    func session(id: String) -> AISession?
    func upsert(session: AISession)
    func markEnded(sessionID: String, at: Date)
    func recordUsageSample(sessionID: String, usage: TokenUsage, at: Date)
    /// Rebuilds the day-keyed rollups from the sessions and samples on disk.
    ///
    /// Declared here because the incremental write path keys a session's whole
    /// spend on the day it started, so an overnight session's tokens sit under
    /// yesterday until this is run. The store owns what the correct answer is;
    /// the engine owns when to ask. See `ClaudenceStore.recomputeRollups`.
    func recomputeRollups()
    func dailyTotals(days: Int) -> [(day: String, usage: TokenUsage)]
    func projectTotals(since: Date?) -> [(project: String, usage: TokenUsage, sessionCount: Int)]
}
