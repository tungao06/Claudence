import Foundation

// MARK: - Health

/// Whether persistence is actually working.
///
/// Monitoring is best effort. A database that cannot be opened or migrated must
/// not take the app down: the store falls back to memory, records why, and the
/// UI keeps showing live sessions with history unavailable.
public enum StoreHealth: Sendable, Equatable {
    /// Persisting to the file it was asked for.
    case healthy
    /// Running in memory. History is lost on quit.
    case degraded(reason: String)
    /// No database at all. Every call is a no-op.
    case unavailable(reason: String)

    public var isPersistent: Bool {
        if case .healthy = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case .healthy: return nil
        case .degraded(let reason), .unavailable(let reason): return reason
        }
    }
}

// MARK: - Store

/// The domain-facing persistence API.
///
/// ## Concurrency
///
/// A `final class` marked `@unchecked Sendable`. All database work goes through
/// `SQLiteDatabase`, which serializes on its own recursive lock; the only other
/// mutable state here is `_health`, guarded by `healthLock`. There is no shared
/// mutable state outside those two.
///
/// The methods are synchronous and non-throwing because `CursorStoring` in the
/// locked contract declares them that way, and because the transcript reader
/// calls into the store on every FSEvents wake-up where an `await` would push
/// work onto a different executor for no benefit. Failures are swallowed into
/// `health` rather than propagated: a broken database degrades the dashboard,
/// never the menu bar.
///
/// ## Rollup strategy: incremental, on write
///
/// `daily_rollups` is maintained incrementally inside the same transaction as
/// the session write, not recomputed on read.
///
/// `upsert(session:)` reads the row's previous state, subtracts its full usage
/// and its session count from the `(day, project)` bucket it used to belong to,
/// then adds the new usage and count to the bucket it belongs to now. When
/// neither day nor project changed, the net effect is exactly the usage delta.
///
/// Cost: one extra `SELECT` by primary key plus one upsert into a two-column
/// primary key, so O(1) per session write, and `dailyTotals` is then an indexed
/// range scan over at most `days x projects` rows.
///
/// The alternative, recompute-on-read, is O(number of sessions ever recorded)
/// on every dashboard refresh: with a year of sessions that is a full table scan
/// several times a second while the popover is open. The price of the
/// incremental choice is that the rollups can drift if rows are ever mutated
/// outside `upsert(session:)`, so `recomputeRollups()` exists as a repair
/// operation. Nothing calls it on the hot path.
public final class ClaudenceStore: CursorStoring, @unchecked Sendable {

    // MARK: Location

    /// `~/Library/Application Support/Claudence/claudence.db`.
    public static var defaultDatabaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Claudence", isDirectory: true)
            .appendingPathComponent("claudence.db")
    }

    // MARK: State

    /// The connection in use, replaceable by `reopen(url:)`.
    ///
    /// Guarded by `connectionLock` rather than immutable, because the live-only
    /// preference points the same store at an in-memory database and back while
    /// the app runs, and every holder of this object keeps its reference across
    /// that. The lock is held only while the reference is read or replaced, not
    /// while a statement runs: `SQLiteDatabase` has its own recursive lock and
    /// is opened `SQLITE_OPEN_FULLMUTEX`, so a query already in flight finishes
    /// safely against the connection it started on.
    private var database: SQLiteDatabase?
    /// Held for the whole of every query and for the whole of a reopen, so a
    /// mode change cannot interleave with a write.
    ///
    /// Recursive because `reopen` carries the cursors across by calling the
    /// store's own reads and writes, which take the lock again. A plain `NSLock`
    /// deadlocked there.
    ///
    /// Holding it across the query rather than only across the reference read
    /// costs nothing measurable: `SQLiteDatabase` already serialises on its own
    /// recursive lock and is opened `SQLITE_OPEN_FULLMUTEX`, so two callers
    /// never ran a statement at the same time anyway. What it buys is that a
    /// write started before the switch cannot still be in flight against the
    /// file afterwards, which is the difference between "nothing is written
    /// once the mode is on" being true and being nearly true.
    private let connectionLock = NSRecursiveLock()
    private let healthLock = NSLock()
    private var _health: StoreHealth
    private var _unansweredQueries: UInt64 = 0
    /// What health means for this store when nothing is failing. A store that
    /// fell back to memory at launch is degraded for as long as it lives, so
    /// recovery returns here rather than to `.healthy`. Reset by `reopen`,
    /// which is a new baseline rather than a recovery: a deliberate in-memory
    /// store is healthy, and the degradation of the connection it replaced is
    /// not a fact about it.
    private var baselineHealth: StoreHealth
    private let calendar: Calendar

    public var health: StoreHealth {
        healthLock.lock()
        defer { healthLock.unlock() }
        return _health
    }

    /// How many calls have failed or never ran, since the store was opened.
    /// Monotonic, and the store's record of *outcome* rather than of state.
    ///
    /// `health` says what condition the store is in; this says whether a
    /// particular call produced an answer. A caller that reads it either side
    /// of its queries learns whether those queries answered, which comparing
    /// health cannot tell it once health has settled on `.degraded` or
    /// `.unavailable` and has nowhere left to move.
    public var unansweredQueries: UInt64 {
        healthLock.lock()
        defer { healthLock.unlock() }
        return _unansweredQueries
    }

    /// The same count, for the calling thread alone.
    ///
    /// `unansweredQueries` is one number for the whole store, and three callers
    /// bracket their own reads with it from different threads: the engine's
    /// actor, the subagent tracker's, and the analytics layer on the main one.
    /// A failing query anywhere between one caller's two reads makes that
    /// caller's answered read look unanswered, which costs a skipped pass in
    /// the engine and prints `Usage unavailable` over a figure the store
    /// actually returned.
    ///
    /// The per-thread count has no such crosstalk, because a bracket is
    /// synchronous: `let before = ...; let value = read(); guard after == before`
    /// contains no suspension point, so the two reads and the query between them
    /// run on one thread. The global count stays exactly as it was, for
    /// diagnostics, where the whole store's behaviour is the question.
    public var unansweredQueriesOnThisThread: UInt64 {
        (Thread.current.threadDictionary[ClaudenceStore.threadCountKey] as? UInt64) ?? 0
    }

    private static let threadCountKey = "com.tungao.claudence.store.unansweredQueries"

    private func noteUnansweredOnThisThread() {
        let dictionary = Thread.current.threadDictionary
        let current = (dictionary[ClaudenceStore.threadCountKey] as? UInt64) ?? 0
        dictionary[ClaudenceStore.threadCountKey] = current &+ 1
    }

    /// The connection, for tests and for diagnostics. `nil` when unavailable.
    public var connection: SQLiteDatabase? { currentDatabase() }

    private func currentDatabase() -> SQLiteDatabase? {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return database
    }

    // MARK: Init

    /// Opens the store at `url`, migrating as needed.
    ///
    /// Never throws and never traps. If the file cannot be opened or migrated
    /// (missing permission, a corrupt file, a schema from a newer build) the
    /// store falls back to an in-memory database and reports `.degraded`. If
    /// even that fails it reports `.unavailable` and every call becomes a no-op.
    ///
    /// - Parameters:
    ///   - url: the database file, or nil for an in-memory database. Injected so
    ///     tests never touch the real Application Support path.
    ///   - calendar: used only to bucket rollup days. Injected so a test can pin
    ///     a time zone.
    public init(url: URL? = ClaudenceStore.defaultDatabaseURL, calendar: Calendar = .current) {
        self.calendar = calendar
        let (opened, health) = ClaudenceStore.open(url: url)
        self.database = opened
        self._health = health
        self.baselineHealth = self._health
    }

    /// Opens a connection the way `init` does, so `reopen` cannot drift from
    /// launch. A file that will not open falls back to memory and reports
    /// `.degraded`; an explicitly requested in-memory database is a deliberate
    /// choice and reports `.healthy`.
    private static func open(url: URL?) -> (SQLiteDatabase?, StoreHealth) {
        func openInMemory(reason: String?) -> (SQLiteDatabase?, StoreHealth) {
            do {
                let memory = try SQLiteDatabase(url: nil)
                try Schema.migrate(memory)
                return (memory, reason.map { StoreHealth.degraded(reason: $0) } ?? .healthy)
            } catch {
                guard let reason else {
                    return (nil, .unavailable(reason: "cannot open in-memory database: \(error)"))
                }
                return (nil, .unavailable(reason: "\(reason); in-memory fallback also failed: \(error)"))
            }
        }

        guard let url else { return openInMemory(reason: nil) }
        do {
            let opened = try SQLiteDatabase(url: url)
            try Schema.migrate(opened)
            return (opened, .healthy)
        } catch {
            return openInMemory(reason: "cannot use \(url.path): \(error)")
        }
    }

    // MARK: - Changing where the store writes

    /// Points this store at a different database, carrying the read cursors
    /// across, and returns the health of what it opened.
    ///
    /// The live-only preference turns persistence off while the app runs, and
    /// every holder of this object -- the engine, the subagent tracker, the
    /// transcript reader, the analytics service -- keeps its reference across
    /// the change rather than being rebuilt.
    ///
    /// The cursors are why this is a reopen and not a swap. A cursor and its
    /// total are only correct together: a new database answers "no cursor",
    /// `TranscriptReader` then starts at byte 0, and the engine adds a whole
    /// transcript to an accumulator that already contains it. Carrying them
    /// makes the next pass incremental, which is the same invariant the reader
    /// and the seed already defend from their own ends. Session rows and
    /// subagent totals are not carried: they live in the engine's and the
    /// tracker's accumulators and are written to wherever the store now points
    /// on the next change.
    ///
    /// The old connection is released rather than torn out from under a
    /// statement. A query already running holds its own reference and finishes
    /// against the connection it started on, so a write in flight when the mode
    /// changes still lands on the old database. That is one write, and the
    /// alternative is a torn statement.
    @discardableResult
    public func reopen(url: URL?) -> StoreHealth {
        // One critical section from the first read of the old database to the
        // last write into the new one. Split into three, as it was until the
        // audit of 2026-09-03, a writer on another thread could save a fresh
        // cursor into the new database between the swap and the carry loop, and
        // the loop would then write the older offset over it. The engine's
        // accumulator does not move when the store does, so the next pass would
        // resume at the rolled-back offset and add records it already holds.
        connectionLock.lock()
        defer { connectionLock.unlock() }

        let carried = allCursors()
        let (opened, health) = ClaudenceStore.open(url: url)
        database = opened

        healthLock.lock()
        _health = health
        baselineHealth = health
        healthLock.unlock()

        for (sessionID, cursor) in carried {
            saveCursor(cursor, forSession: sessionID)
        }
        return health
    }

    /// Every read cursor the store holds, for the transfer in `reopen`.
    public func allCursors() -> [(sessionID: String, cursor: ReadCursor)] {
        perform("read every cursor", default: []) { database in
            try database.query(
                "SELECT session_id, path, inode, byte_offset FROM read_cursors",
                []
            ) { row in
                (
                    sessionID: row.string(0),
                    cursor: ReadCursor(
                        path: row.string(1),
                        inode: UInt64(row.int(2)),
                        byteOffset: UInt64(row.int(3))
                    )
                )
            }
        }
    }

    /// What the database holds right now, for a confirmation that names real
    /// numbers instead of warning vaguely about "your data".
    public struct StoredDataSummary: Sendable, Equatable {
        public var sessions: Int
        public var usageSamples: Int
        public var rollupDays: Int
        public var subagentTotals: Int
        /// The file on disk, or nil for an in-memory database.
        public var fileURL: URL?
        public var fileSizeBytes: UInt64?

        public init(
            sessions: Int = 0,
            usageSamples: Int = 0,
            rollupDays: Int = 0,
            subagentTotals: Int = 0,
            fileURL: URL? = nil,
            fileSizeBytes: UInt64? = nil
        ) {
            self.sessions = sessions
            self.usageSamples = usageSamples
            self.rollupDays = rollupDays
            self.subagentTotals = subagentTotals
            self.fileURL = fileURL
            self.fileSizeBytes = fileSizeBytes
        }

        /// True when there is nothing to delete, so a confirmation can be
        /// skipped rather than asking about an empty file.
        public var isEmpty: Bool {
            sessions == 0 && usageSamples == 0 && rollupDays == 0 && subagentTotals == 0
        }
    }

    public func storedDataSummary() -> StoredDataSummary {
        func count(_ table: String) -> Int {
            perform("count \(table)", default: 0) { database in
                try database.query("SELECT COUNT(*) FROM \(table)", []) { row in row.int(0) }.first ?? 0
            }
        }

        let url = currentDatabase()?.fileURL
        let size = url.flatMap { FileStatus(path: $0.path)?.size }
        return StoredDataSummary(
            sessions: count("sessions"),
            usageSamples: count("usage_samples"),
            rollupDays: count("daily_rollups"),
            subagentTotals: count("subagent_totals"),
            fileURL: url,
            fileSizeBytes: size
        )
    }

    /// Empties every table and reclaims the space.
    ///
    /// The cursors go with the rows deliberately. A session row and the offset
    /// its total was accumulated to are only correct together, so keeping the
    /// cursors while deleting the totals would leave a reader resuming at byte
    /// N against a total of zero: the undercount this codebase has already been
    /// bitten by, written down as a deletion feature.
    public func deleteStoredData() {
        perform("delete stored data") { database in
            try database.withTransaction {
                for table in ["usage_samples", "daily_rollups", "subagent_totals", "read_cursors", "sessions"] {
                    try database.execute("DELETE FROM \(table)", [])
                }
            }
        }
        // Outside the transaction: SQLite refuses to vacuum inside one.
        perform("vacuum") { database in
            try database.execute("VACUUM", [])
        }
    }

    /// Removes a database file and its write-ahead siblings.
    ///
    /// Static and file-scoped rather than an instance method, because it is
    /// only correct once nothing has the file open: call it after `reopen` has
    /// pointed the store somewhere else. Returns what it could not remove.
    @discardableResult
    public static func removeStoredFile(at url: URL = ClaudenceStore.defaultDatabaseURL) -> [URL] {
        var failed: [URL] = []
        for candidate in [url, URL(fileURLWithPath: url.path + "-wal"), URL(fileURLWithPath: url.path + "-shm")] {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            do {
                try FileManager.default.removeItem(at: candidate)
            } catch {
                failed.append(candidate)
            }
        }
        return failed
    }

    // MARK: - Sessions

    /// Inserts or updates a session and keeps `daily_rollups` in step.
    public func upsert(session: AISession) {
        perform("upsert session") { database in
            try database.withTransaction {
                let previous = try self.rollupKeyAndUsage(for: session.id, in: database)

                try database.execute(
                    """
                    INSERT INTO sessions (
                        id, project_name, working_directory, provider, pid, proc_start,
                        started_at, last_activity_at, ended_at, model, claude_code_version,
                        fresh_input, cache_creation, cache_read, output, thinking,
                        subagent_fresh_input, subagent_cache_creation, subagent_cache_read,
                        subagent_output, subagent_thinking, subagent_count
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        project_name = excluded.project_name,
                        working_directory = excluded.working_directory,
                        provider = excluded.provider,
                        pid = excluded.pid,
                        proc_start = excluded.proc_start,
                        started_at = excluded.started_at,
                        last_activity_at = excluded.last_activity_at,
                        model = COALESCE(excluded.model, sessions.model),
                        claude_code_version = COALESCE(excluded.claude_code_version, sessions.claude_code_version),
                        fresh_input = excluded.fresh_input,
                        cache_creation = excluded.cache_creation,
                        cache_read = excluded.cache_read,
                        output = excluded.output,
                        thinking = excluded.thinking,
                        subagent_fresh_input = excluded.subagent_fresh_input,
                        subagent_cache_creation = excluded.subagent_cache_creation,
                        subagent_cache_read = excluded.subagent_cache_read,
                        subagent_output = excluded.subagent_output,
                        subagent_thinking = excluded.subagent_thinking,
                        subagent_count = excluded.subagent_count
                    """,
                    [
                        .text(session.id),
                        .text(session.projectName),
                        .text(session.workingDirectory),
                        .text(session.provider.rawValue),
                        .integer(Int64(session.pid)),
                        .text(session.procStart),
                        .real(session.startedAt.timeIntervalSince1970),
                        .real(session.lastActivityAt.timeIntervalSince1970),
                        // `ended_at` is owned by `markEnded`. The upsert never
                        // clears it, so a live re-observation cannot resurrect a
                        // finished session.
                        session.status == .completed ? .real(session.lastActivityAt.timeIntervalSince1970) : .null,
                        SQLiteValue(session.model),
                        SQLiteValue(session.claudeCodeVersion),
                        .integer(Int64(session.usage.freshInput)),
                        .integer(Int64(session.usage.cacheCreation)),
                        .integer(Int64(session.usage.cacheRead)),
                        .integer(Int64(session.usage.output)),
                        .integer(Int64(session.usage.thinking)),
                        .integer(Int64(session.subagentUsage.freshInput)),
                        .integer(Int64(session.subagentUsage.cacheCreation)),
                        .integer(Int64(session.subagentUsage.cacheRead)),
                        .integer(Int64(session.subagentUsage.output)),
                        .integer(Int64(session.subagentUsage.thinking)),
                        .integer(Int64(session.subagentCount)),
                    ]
                )

                if let previous {
                    try self.applyRollup(
                        day: previous.day,
                        project: previous.project,
                        usage: previous.usage,
                        sign: -1,
                        sessionCountDelta: -1,
                        in: database
                    )
                }

                // Combined, not parent-only. `rollupKeyAndUsage` subtracts the
                // same definition, and the subtract-then-add pair is only self
                // correcting while both sides agree.
                try self.applyRollup(
                    day: self.dayString(for: session.startedAt),
                    project: session.projectName,
                    usage: session.combinedUsage,
                    sign: 1,
                    sessionCountDelta: 1,
                    in: database
                )
            }
        }
    }

    public func session(id: String) -> AISession? {
        perform("read session", default: nil) { database in
            try database.queryFirst(
                "\(Self.sessionColumns) WHERE id = ?",
                [.text(id)],
                transform: Self.makeSession
            )
        }
    }

    /// Every stored session, newest activity first.
    /// - Parameter since: keeps sessions whose last activity is at or after this
    ///   instant. Nil returns everything.
    public func allSessions(since: Date? = nil) -> [AISession] {
        perform("read sessions", default: []) { database in
            if let since {
                return try database.query(
                    "\(Self.sessionColumns) WHERE last_activity_at >= ? ORDER BY last_activity_at DESC",
                    [.real(since.timeIntervalSince1970)],
                    transform: Self.makeSession
                )
            }
            return try database.query(
                "\(Self.sessionColumns) ORDER BY last_activity_at DESC",
                transform: Self.makeSession
            )
        }
    }

    public func markEnded(sessionID: String, at date: Date) {
        perform("mark session ended") { database in
            try database.execute(
                """
                UPDATE sessions
                   SET ended_at = ?,
                       last_activity_at = MAX(last_activity_at, ?)
                 WHERE id = ?
                """,
                [
                    .real(date.timeIntervalSince1970),
                    .real(date.timeIntervalSince1970),
                    .text(sessionID),
                ]
            )
        }
    }

    // MARK: - Usage samples

    /// Records a snapshot of a session's cumulative usage.
    ///
    /// Samples are append-only and never feed the rollups: `daily_rollups` is
    /// driven by the session row, so a sample cannot double-count.
    public func recordUsageSample(sessionID: String, usage: TokenUsage, at date: Date) {
        perform("record usage sample") { database in
            try database.execute(
                """
                INSERT INTO usage_samples
                    (session_id, sampled_at, fresh_input, cache_creation, cache_read, output, thinking)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .text(sessionID),
                    .real(date.timeIntervalSince1970),
                    .integer(Int64(usage.freshInput)),
                    .integer(Int64(usage.cacheCreation)),
                    .integer(Int64(usage.cacheRead)),
                    .integer(Int64(usage.output)),
                    .integer(Int64(usage.thinking)),
                ]
            )
        }
    }

    /// Samples for one session, oldest first. That order is what the burn-rate
    /// window differentiates over.
    public func usageSamples(sessionID: String, since: Date? = nil) -> [(sampledAt: Date, usage: TokenUsage)] {
        perform("read usage samples", default: []) { database in
            let sql = """
                SELECT sampled_at, fresh_input, cache_creation, cache_read, output, thinking
                  FROM usage_samples
                 WHERE session_id = ?\(since == nil ? "" : " AND sampled_at >= ?")
                 ORDER BY sampled_at ASC, id ASC
                """
            var parameters: [SQLiteValue] = [.text(sessionID)]
            if let since { parameters.append(.real(since.timeIntervalSince1970)) }
            return try database.query(sql, parameters) { row in
                (
                    sampledAt: Date(timeIntervalSince1970: row.double(0)),
                    usage: TokenUsage(
                        freshInput: row.int(1),
                        cacheCreation: row.int(2),
                        cacheRead: row.int(3),
                        output: row.int(4),
                        thinking: row.int(5)
                    )
                )
            }
        }
    }

    /// Every session's samples inside `range`, plus, for each session, the last
    /// sample taken *before* it.
    ///
    /// The trailing baseline is the whole point. Samples hold a session's
    /// running total, so a bucket's consumption is the difference between
    /// consecutive samples; without the sample that precedes the range, the
    /// first sample inside it has nothing to subtract from and its bucket
    /// silently loses everything spent between the two. Fetching it here rather
    /// than widening the range keeps the extra work at one row per session
    /// instead of one row per sampling interval.
    ///
    /// Ordered by session and then by time, which is the order the caller
    /// differentiates in.
    public func usageSamples(in range: Range<Date>) -> [UsageSampleRow] {
        let lower = range.lowerBound.timeIntervalSince1970
        let upper = range.upperBound.timeIntervalSince1970

        return perform("read usage samples in range", default: []) { database in
            try database.query(
                """
                SELECT session_id, sampled_at,
                       fresh_input, cache_creation, cache_read, output, thinking
                  FROM usage_samples
                 WHERE sampled_at >= ? AND sampled_at < ?
                 UNION ALL
                SELECT s.session_id, s.sampled_at,
                       s.fresh_input, s.cache_creation, s.cache_read, s.output, s.thinking
                  FROM usage_samples s
                  JOIN (
                        SELECT session_id, MAX(sampled_at) AS baseline
                          FROM usage_samples
                         WHERE sampled_at < ?
                         GROUP BY session_id
                       ) p
                    ON s.session_id = p.session_id AND s.sampled_at = p.baseline
                 ORDER BY session_id ASC, sampled_at ASC
                """,
                [.real(lower), .real(upper), .real(lower)]
            ) { row in
                UsageSampleRow(
                    sessionID: row.string(0),
                    sampledAt: Date(timeIntervalSince1970: row.double(1)),
                    usage: TokenUsage(
                        freshInput: row.int(2),
                        cacheCreation: row.int(3),
                        cacheRead: row.int(4),
                        output: row.int(5),
                        thinking: row.int(6)
                    )
                )
            }
        }
    }

    // MARK: - Sample retention

    /// How much sample history keeps its full resolution.
    ///
    /// Eight days, because the widest window that reads individual samples is
    /// the seven-day usage share, and a day of slack keeps a query that starts
    /// mid-day from meeting the compacted region at its own edge.
    public static let sampleFullResolutionDays = 8

    /// Collapses samples older than `cutoff` to one row per session per local
    /// day, and reports how many rows went.
    ///
    /// Nothing pruned `usage_samples` until 2026-09-03 and nothing was meant
    /// to: the rollup repair reads every sample to decide which day a session's
    /// tokens belong to, so deleting them outright would move a month of
    /// history onto session start days the next time the repair ran. Measured
    /// cadence here is 17 to 36 samples an hour per active session, which is
    /// tens of thousands of rows a month and hundreds of thousands a year,
    /// every one of them read by a repair that runs on a 60 second throttle.
    ///
    /// Collapsing rather than deleting is what makes this safe. The walk in
    /// `UsageSampleWalk` measures the rise between consecutive samples, so the
    /// tokens spent on a day sit between that day's last sample and the
    /// previous day's last sample. Keeping exactly those rows preserves every
    /// day's figure while making the table proportional to sessions times days
    /// rather than to sessions times minutes. What is lost is resolution
    /// *within* an old day, which only the hourly chart and the seven-day share
    /// ever ask for, and neither reaches past `sampleFullResolutionDays`.
    ///
    /// The day grouping uses SQLite's own `localtime`, not `Calendar`. The two
    /// can disagree by an hour across a daylight-saving boundary, which at
    /// worst keeps one extra row or files one boundary sample under the
    /// neighbouring day. Both are cheaper than reading every row into memory to
    /// group it in Swift.
    @discardableResult
    public func compactUsageSamples(olderThan cutoff: Date) -> Int {
        let seconds = cutoff.timeIntervalSince1970
        return perform("compact usage samples", default: 0) { database in
            let rows = try database.query(
                "SELECT id, session_id, sampled_at FROM usage_samples WHERE sampled_at < ? ORDER BY id ASC",
                [.real(seconds)]
            ) { row in
                (id: row.int(0), sessionID: row.string(1), sampledAt: row.double(2))
            }
            guard !rows.isEmpty else { return 0 }

            // Grouped here rather than in SQL. `date(sampled_at,'unixepoch',
            // 'localtime')` would answer with the host's zone whatever calendar
            // this store was given, so a store pinned to another zone, which is
            // how the rollup tests make day boundaries deterministic, would
            // collapse by one definition of a day and reconcile by another.
            //
            // The survivor is the row with the greatest `sampled_at`, ties
            // broken by id, not the greatest id. `recordUsageSample` takes the
            // moment as an argument, so a clock that steps backwards or a
            // sample recorded late writes a higher id with an earlier
            // timestamp, and keeping that row would hand the day's reconciled
            // total an endpoint that is not the day's end.
            var survivors: [String: (id: Int, sampledAt: Double)] = [:]
            for row in rows {
                let day = dayString(for: Date(timeIntervalSince1970: row.sampledAt))
                let key = "\(row.sessionID)\u{0000}\(day)"
                if let held = survivors[key],
                   held.sampledAt > row.sampledAt
                    || (held.sampledAt == row.sampledAt && held.id > row.id) {
                    continue
                }
                survivors[key] = (id: row.id, sampledAt: row.sampledAt)
            }

            let kept = Set(survivors.values.map(\.id))
            let doomed = rows.map(\.id).filter { !kept.contains($0) }
            guard !doomed.isEmpty else { return 0 }

            // In batches, because SQLite caps how many parameters one statement
            // may carry and a year of samples is well past it.
            var removed = 0
            try database.withTransaction {
                var index = doomed.startIndex
                while index < doomed.endIndex {
                    let end = doomed.index(index, offsetBy: 400, limitedBy: doomed.endIndex) ?? doomed.endIndex
                    let batch = Array(doomed[index..<end])
                    let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                    try database.execute(
                        "DELETE FROM usage_samples WHERE id IN (\(placeholders))",
                        batch.map { .integer(Int64($0)) }
                    )
                    removed += batch.count
                    index = end
                }
            }
            return removed
        }
    }

    // MARK: - Aggregates

    /// Token totals per local day, oldest first, covering the last `days` days
    /// including today.
    ///
    /// A day with no row at all is omitted, which is not the same as a day that
    /// returns zero. `rollupBuckets` writes a row for every session on the day
    /// it started, `session_count` included, so a day whose only session spent
    /// nothing comes back as a measured zero rather than as an absence. That is
    /// the truth of it: a session did run and it did spend nothing, and the
    /// chart draws a zero for a day that was observed rather than leaving a gap
    /// that reads as "not watched". Callers that need "no session ran" have to
    /// ask for the row's `session_count`, not infer it from the total.
    ///
    /// The upper bound on `day` is not decoration. `residualDay` comes from
    /// `max(lastActivityAt, lastSampleAt)` and `lastActivityAt` takes any
    /// transcript timestamp later than the one it holds, unclamped, so a single
    /// skewed record files tokens on a day that has not happened yet. Without
    /// the bound those tokens were summed into today.
    ///
    /// Served straight from `daily_rollups`, so this is an index range scan and
    /// never touches the sessions table.
    public func dailyTotals(days: Int) -> [(day: String, usage: TokenUsage)] {
        guard days > 0 else { return [] }
        let now = Date()
        let earliest = calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now
        let lowerBound = dayString(for: earliest)

        return perform("read daily totals", default: []) { database in
            try database.query(
                """
                SELECT day,
                       SUM(fresh_input), SUM(cache_creation), SUM(cache_read),
                       SUM(output), SUM(thinking)
                  FROM daily_rollups
                 WHERE day >= ? AND day <= ?
                 GROUP BY day
                 ORDER BY day ASC
                """,
                [.text(lowerBound), .text(dayString(for: now))]
            ) { row in
                (
                    day: row.string(0),
                    usage: TokenUsage(
                        freshInput: row.int(1),
                        cacheCreation: row.int(2),
                        cacheRead: row.int(3),
                        output: row.int(4),
                        thinking: row.int(5)
                    )
                )
            }
        }
    }

    /// Rebuilds `daily_rollups` from `sessions` and `usage_samples`.
    ///
    /// ## What it repairs
    ///
    /// `upsert(session:)` keys a session's whole contribution on the day it
    /// *started*, because that is the only day the row in front of it can name
    /// in O(1). A session that begins at 21:25 and is still running at 00:52
    /// therefore puts everything it spends after midnight onto the previous
    /// day, and `dailyTotals(days: 1)`, which asks `WHERE day >= '<today>'`,
    /// finds nothing at all. Observed on the live database on 2026-09-03: all
    /// eight rollup rows dated the previous day while a live session held
    /// 172.7 M tokens.
    ///
    /// The correction lives here and only here. Splitting a session across days
    /// inside the incremental write would need the previous split back to
    /// subtract it, which the session row does not carry; a repair rebuilt from
    /// durable facts can always be run again, and a wrong incremental write
    /// cannot be taken back.
    ///
    /// ## How a session is split
    ///
    /// `usage_samples` hold each session's running total, so the rises between
    /// them say *when* tokens were spent while the session row says *how many*.
    /// The rises are bucketed by the local day the later sample falls in,
    /// through the same `UsageSampleWalk` the hourly chart and the window share
    /// use, high-water mark included: the samples are not monotonic, and
    /// differencing against the previous sample counts a recovery twice.
    ///
    /// The buckets are then reconciled to the row, field by field, so they add
    /// up to exactly what the session holds:
    ///
    /// - measured less than the row: the difference was spent after the last
    ///   sample, so it goes on the day of the session's last activity.
    /// - measured more than the row: the buckets are scaled down in proportion,
    ///   the remainder handed out largest first. Nothing goes negative.
    /// - no samples at all: the whole total goes on the start day, which is
    ///   exactly what the incremental path already does.
    ///
    /// The sum over days is therefore exactly the sum of `combinedUsage` over
    /// sessions, whatever the samples say, and `rollupsSplitASessionAcrossMidnight`
    /// asserts it. That property is the point: this project has already shipped
    /// a rollup rewritten downward by a cursor that outlived its total, and a
    /// repair that can lose tokens is the same defect wearing a different hat.
    ///
    /// `session_count` stays on the start day alone. It counts sessions rather
    /// than session-days, and moving it would change a figure this repair was
    /// not asked to touch.
    ///
    /// ## Cost and failure
    ///
    /// O(sessions + samples), all of both, in one transaction: the split of a
    /// session that ran three days ago is as much a fact as today's, so a
    /// partial rebuild would have to invent a rule for the sessions that
    /// straddle its edge. Every read happens inside the transaction and throws,
    /// so a statement that fails rolls the `DELETE` back with it rather than
    /// leaving the table rebuilt from half the rows. Callers must throttle it;
    /// `MonitorEngine` does.
    public func recomputeRollups() {
        perform("recompute rollups") { database in
            try database.withTransaction {
                try database.execute("DELETE FROM daily_rollups")

                // Combined, matching `upsert(session:)`. A repair that used the
                // parent-only figure would quietly rewrite history down by
                // every session's subagent spend.
                let sessions = try database.query(
                    """
                    SELECT id, project_name, started_at, last_activity_at,
                           fresh_input, cache_creation, cache_read, output, thinking,
                           subagent_fresh_input, subagent_cache_creation, subagent_cache_read,
                           subagent_output, subagent_thinking
                      FROM sessions
                    """
                ) { row in
                    RollupSession(
                        id: row.string(0),
                        project: row.string(1),
                        startedAt: Date(timeIntervalSince1970: row.double(2)),
                        lastActivityAt: Date(timeIntervalSince1970: row.double(3)),
                        usage: TokenUsage(
                            freshInput: row.int(4),
                            cacheCreation: row.int(5),
                            cacheRead: row.int(6),
                            output: row.int(7),
                            thinking: row.int(8)
                        ) + TokenUsage(
                            freshInput: row.int(9),
                            cacheCreation: row.int(10),
                            cacheRead: row.int(11),
                            output: row.int(12),
                            thinking: row.int(13)
                        )
                    )
                }

                // Ordered by session and then by time, which is the order the
                // walk differentiates in.
                let samples = try database.query(
                    """
                    SELECT session_id, sampled_at,
                           fresh_input, cache_creation, cache_read, output, thinking
                      FROM usage_samples
                     ORDER BY session_id ASC, sampled_at ASC, id ASC
                    """
                ) { row in
                    UsageSampleRow(
                        sessionID: row.string(0),
                        sampledAt: Date(timeIntervalSince1970: row.double(1)),
                        usage: TokenUsage(
                            freshInput: row.int(2),
                            cacheCreation: row.int(3),
                            cacheRead: row.int(4),
                            output: row.int(5),
                            thinking: row.int(6)
                        )
                    )
                }

                for (bucket, contribution) in self.rollupBuckets(sessions: sessions, samples: samples) {
                    try self.applyRollup(
                        day: bucket.day,
                        project: bucket.project,
                        usage: contribution.usage,
                        sign: 1,
                        sessionCountDelta: contribution.sessionCount,
                        in: database
                    )
                }
            }
        }
    }

    /// One `(day, project)` cell of `daily_rollups`.
    private struct RollupBucket: Hashable {
        let day: String
        let project: String
    }

    private struct RollupContribution {
        var usage: TokenUsage = .zero
        var sessionCount: Int64 = 0
    }

    /// What every session read back from disk contributes, and where.
    private struct RollupSession {
        let id: String
        let project: String
        let startedAt: Date
        let lastActivityAt: Date
        /// Combined, parent plus subagents. See `recomputeRollups`.
        let usage: TokenUsage
    }

    /// The whole rollup table as it should be, in an order that does not depend
    /// on how a dictionary happened to hash.
    private func rollupBuckets(
        sessions: [RollupSession],
        samples: [UsageSampleRow]
    ) -> [(RollupBucket, RollupContribution)] {
        // Everything ever sampled is in range, so every session's first sample
        // counts in full: a rollup covers a session's whole life rather than a
        // window of it, and there is no earlier bucket for those tokens to
        // belong to.
        //
        // It is filed on the day the session started rather than the day it was
        // first sampled. Those tokens were spent before anything sampled them,
        // which for every session already running when the app launches is most
        // of what they hold, and dating them at the launch moment put a month
        // of another day's work on today's row. The start day is the same day
        // the incremental write uses, so the repair and the write agree about
        // the part neither of them observed.
        let everything = Date.distantPast..<Date.distantFuture
        var measured: [String: [String: TokenUsage]] = [:]
        UsageSampleWalk.enumerateIncreases(
            in: samples,
            range: everything,
            sessionStarts: Dictionary(
                sessions.map { ($0.id, $0.startedAt) },
                uniquingKeysWith: { first, _ in first }
            ),
            firstSampleTime: .sessionStart
        ) { sessionID, sampledAt, delta in
            measured[sessionID, default: [:]][self.dayString(for: sampledAt), default: .zero] += delta
        }

        var lastSampleAt: [String: Date] = [:]
        for row in samples {
            lastSampleAt[row.sessionID] = max(lastSampleAt[row.sessionID] ?? row.sampledAt, row.sampledAt)
        }

        var buckets: [RollupBucket: RollupContribution] = [:]
        for session in sessions {
            let startDay = dayString(for: session.startedAt)
            // The unmeasured remainder was spent after the last sample, so it
            // belongs to the last day the session was seen working, not to the
            // day it happened to start on.
            let residual = max(session.lastActivityAt, lastSampleAt[session.id] ?? session.lastActivityAt)
            let split = Self.daySplit(
                total: session.usage,
                measured: measured[session.id] ?? [:],
                fallbackDay: startDay,
                residualDay: dayString(for: residual)
            )
            for (day, usage) in split {
                buckets[RollupBucket(day: day, project: session.project), default: RollupContribution()].usage += usage
            }
            buckets[RollupBucket(day: startDay, project: session.project), default: RollupContribution()]
                .sessionCount += 1
        }

        return buckets
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                lhs.0.day == rhs.0.day ? lhs.0.project < rhs.0.project : lhs.0.day < rhs.0.day
            }
    }

    /// Splits one session's stored total across the local days its samples rose
    /// on, in a way that adds back up to that total exactly.
    ///
    /// Per field, because each of the five counters is its own quantity and the
    /// breakdown shows cache separately from fresh input. See `recomputeRollups`
    /// for the three cases and why each is answered the way it is.
    static func daySplit(
        total: TokenUsage,
        measured: [String: TokenUsage],
        fallbackDay: String,
        residualDay: String
    ) -> [String: TokenUsage] {
        // A session with no samples has nothing to say about when, so its
        // total goes where the incremental path already puts it.
        let anchor = measured.isEmpty ? fallbackDay : residualDay
        var result: [String: TokenUsage] = [:]
        for field in UsageSampleWalk.fields {
            let amounts = measured
                .map { (day: $0.key, value: $0.value[keyPath: field]) }
                .sorted { $0.day < $1.day }
            for placed in Self.apportion(total: total[keyPath: field], across: amounts, anchor: anchor) {
                guard placed.value != 0 else { continue }
                result[placed.day, default: .zero][keyPath: field] += placed.value
            }
        }
        return result
    }

    /// Places `total` across the measured days so that the parts sum to exactly
    /// `total` and none of them is negative.
    ///
    /// The measured amounts are a shape, not a magnitude: the session row is
    /// the authority on how much was spent and the samples only on when. When
    /// the two disagree the shape gives way, never the total, because a repair
    /// that changes a sum is the failure this whole path exists to prevent.
    static func apportion(
        total: Int,
        across amounts: [(day: String, value: Int)],
        anchor: String
    ) -> [(day: String, value: Int)] {
        guard total > 0 else { return [] }
        let measured = amounts.reduce(0) { $0 + $1.value }
        guard measured > 0 else { return [(day: anchor, value: total)] }
        if measured == total { return amounts }

        if measured < total {
            var result = amounts
            let remainder = total - measured
            if let index = result.firstIndex(where: { $0.day == anchor }) {
                result[index].value += remainder
            } else {
                result.append((day: anchor, value: remainder))
            }
            return result
        }

        // Measured more than the row holds, which is what a session row written
        // down to a smaller figure looks like from here. Scale in proportion
        // and hand the rounding remainder out largest fraction first, so the
        // parts land on exactly `total`.
        let scale = Double(total) / Double(measured)
        var scaled = amounts.map { (day: $0.day, value: Int((Double($0.value) * scale).rounded(.down))) }
        var leftover = total - scaled.reduce(0) { $0 + $1.value }
        let byFraction = amounts.indices.sorted { lhs, rhs in
            let left = Double(amounts[lhs].value) * scale
            let right = Double(amounts[rhs].value) * scale
            let leftFraction = left - left.rounded(.down)
            let rightFraction = right - right.rounded(.down)
            return leftFraction == rightFraction
                ? amounts[lhs].day < amounts[rhs].day
                : leftFraction > rightFraction
        }
        for index in byFraction where leftover > 0 {
            scaled[index].value += 1
            leftover -= 1
        }
        return scaled
    }

    // MARK: - Subagent totals

    /// Every persisted subagent of a session, ordered by id so a read is
    /// reproducible.
    ///
    /// This is the other half of `read_cursors`. The cursor says where the
    /// subagent transcript was left off; without the total that offset stands
    /// for, a relaunch resumes mid-file and counts only what arrives next.
    public func subagentTotals(forSession sessionID: String) -> [SubagentTotal] {
        perform("read subagent totals", default: []) { database in
            try database.query(
                """
                SELECT parent_session_id, subagent_id, agent_type, task_description,
                       model, last_activity_at, records_parsed,
                       fresh_input, cache_creation, cache_read, output, thinking
                  FROM subagent_totals
                 WHERE parent_session_id = ?
                 ORDER BY subagent_id ASC
                """,
                [.text(sessionID)]
            ) { row in
                SubagentTotal(
                    parentSessionID: row.string(0),
                    subagentID: row.string(1),
                    agentType: row.stringOptional(2),
                    taskDescription: row.stringOptional(3),
                    usage: TokenUsage(
                        freshInput: row.int(7),
                        cacheCreation: row.int(8),
                        cacheRead: row.int(9),
                        output: row.int(10),
                        thinking: row.int(11)
                    ),
                    recordsParsed: row.int(6),
                    lastActivityAt: row.doubleOptional(5).map { Date(timeIntervalSince1970: $0) },
                    model: row.stringOptional(4)
                )
            }
        }
    }

    /// Writes a subagent's running total, replacing whatever was there.
    ///
    /// The value is absolute, not a delta: the tracker owns the accumulation
    /// and this row is only its durable copy. `COALESCE` on the label columns
    /// keeps a description already on disk when a later pass has none, because
    /// a missing `meta.json` costs a subagent its labels, never its tokens.
    ///
    /// `subagent_totals` still has a `spawn_depth` column: nothing in this
    /// application ever rendered it, so 9.9 stopped reading and writing it
    /// rather than migrating the column away. A schema change to drop one
    /// unread integer column was judged disproportionate to what it buys.
    public func upsertSubagentTotal(_ total: SubagentTotal) {
        perform("upsert subagent total") { database in
            try database.execute(
                """
                INSERT INTO subagent_totals (
                    parent_session_id, subagent_id, agent_type, task_description,
                    model, last_activity_at, records_parsed,
                    fresh_input, cache_creation, cache_read, output, thinking
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(parent_session_id, subagent_id) DO UPDATE SET
                    agent_type = COALESCE(excluded.agent_type, subagent_totals.agent_type),
                    task_description = COALESCE(excluded.task_description, subagent_totals.task_description),
                    model = COALESCE(excluded.model, subagent_totals.model),
                    last_activity_at = excluded.last_activity_at,
                    records_parsed = excluded.records_parsed,
                    fresh_input = excluded.fresh_input,
                    cache_creation = excluded.cache_creation,
                    cache_read = excluded.cache_read,
                    output = excluded.output,
                    thinking = excluded.thinking
                """,
                [
                    .text(total.parentSessionID),
                    .text(total.subagentID),
                    SQLiteValue(total.agentType),
                    SQLiteValue(total.taskDescription),
                    SQLiteValue(total.model),
                    SQLiteValue(total.lastActivityAt?.timeIntervalSince1970),
                    .integer(Int64(total.recordsParsed)),
                    .integer(Int64(total.usage.freshInput)),
                    .integer(Int64(total.usage.cacheCreation)),
                    .integer(Int64(total.usage.cacheRead)),
                    .integer(Int64(total.usage.output)),
                    .integer(Int64(total.usage.thinking)),
                ]
            )
        }
    }

    /// Drops every subagent row belonging to a session, so an ended session
    /// leaves nothing a recycled id could inherit.
    public func deleteSubagentTotals(forSession sessionID: String) {
        perform("delete subagent totals") { database in
            try database.execute(
                "DELETE FROM subagent_totals WHERE parent_session_id = ?",
                [.text(sessionID)]
            )
        }
    }

    // MARK: - CursorStoring

    public func cursor(forSession sessionID: String) -> ReadCursor? {
        perform("read cursor", default: nil) { database in
            try database.queryFirst(
                "SELECT path, inode, byte_offset FROM read_cursors WHERE session_id = ?",
                [.text(sessionID)]
            ) { row in
                // Stored as the signed bit pattern; see the schema comment.
                ReadCursor(
                    path: row.string(0),
                    inode: UInt64(bitPattern: row.int64(1)),
                    byteOffset: UInt64(bitPattern: row.int64(2))
                )
            }
        }
    }

    public func saveCursor(_ cursor: ReadCursor, forSession sessionID: String) {
        perform("save cursor") { database in
            try database.execute(
                """
                INSERT INTO read_cursors (session_id, path, inode, byte_offset)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(session_id) DO UPDATE SET
                    path = excluded.path,
                    inode = excluded.inode,
                    byte_offset = excluded.byte_offset
                """,
                [
                    .text(sessionID),
                    .text(cursor.path),
                    .integer(Int64(bitPattern: cursor.inode)),
                    .integer(Int64(bitPattern: cursor.byteOffset)),
                ]
            )
        }
    }

    // MARK: - Day bucketing

    /// A local calendar date as "YYYY-MM-DD".
    ///
    /// TIMEZONE ASSUMPTION: local, not UTC. See the `daily_rollups` comment in
    /// `Schema.swift`. Built from `DateComponents` rather than a `DateFormatter`
    /// because `DateFormatter` is not `Sendable` and this runs from whatever
    /// thread the FSEvents callback lands on.
    public func dayString(for date: Date) -> String {
        Self.dayString(for: date, calendar: calendar)
    }

    public static func dayString(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Private

    private static let sessionColumns = """
        SELECT id, project_name, working_directory, provider, pid, proc_start,
               started_at, last_activity_at, ended_at, model, claude_code_version,
               fresh_input, cache_creation, cache_read, output, thinking,
               subagent_fresh_input, subagent_cache_creation, subagent_cache_read,
               subagent_output, subagent_thinking, subagent_count
          FROM sessions
        """

    /// Rebuilds an `AISession` from a row.
    ///
    /// `currentActivity` is deliberately not persisted: an activity label names a
    /// file the user was editing, and there is no product reason to keep that on
    /// disk after the session ends. It comes back nil.
    ///
    /// `status` is derived, not stored. A row with `ended_at` is `.completed`;
    /// anything else reads back `.idle`, because a stored row proves the session
    /// existed, never that it is running right now. Liveness is the discovery
    /// adapter's job (`kill(pid, 0)` plus a matching `procStart`).
    private static func makeSession(_ row: SQLiteRow) -> AISession {
        AISession(
            id: row.string(0),
            provider: AIProviderType(rawValue: row.string(3)) ?? .claudeCode,
            pid: Int32(truncatingIfNeeded: row.int64(4)),
            procStart: row.string(5),
            projectName: row.string(1),
            workingDirectory: row.string(2),
            status: row.isNull(8) ? .idle : .completed,
            currentActivity: nil,
            startedAt: Date(timeIntervalSince1970: row.double(6)),
            lastActivityAt: Date(timeIntervalSince1970: row.double(7)),
            usage: TokenUsage(
                freshInput: row.int(11),
                cacheCreation: row.int(12),
                cacheRead: row.int(13),
                output: row.int(14),
                thinking: row.int(15)
            ),
            // Read back separately, never pre-added: `combinedUsage` is the
            // derived figure and a session loaded from disk has to agree with
            // the one that was written.
            subagentUsage: TokenUsage(
                freshInput: row.int(16),
                cacheCreation: row.int(17),
                cacheRead: row.int(18),
                output: row.int(19),
                thinking: row.int(20)
            ),
            subagentCount: row.int(21),
            model: row.stringOptional(9),
            claudeCodeVersion: row.stringOptional(10)
        )
    }

    private struct RollupKey {
        let day: String
        let project: String
        let usage: TokenUsage
    }

    /// The bucket a session currently contributes to, read before it is changed.
    ///
    /// The usage returned is the combined figure, parent plus subagents,
    /// because that is what `upsert(session:)` adds back. Reading the
    /// parent-only figure here would subtract less than the next write adds,
    /// and every upsert would inflate the bucket by the session's subagent
    /// spend.
    private func rollupKeyAndUsage(for sessionID: String, in database: SQLiteDatabase) throws -> RollupKey? {
        try database.queryFirst(
            """
            SELECT project_name, started_at,
                   fresh_input, cache_creation, cache_read, output, thinking,
                   subagent_fresh_input, subagent_cache_creation, subagent_cache_read,
                   subagent_output, subagent_thinking
              FROM sessions
             WHERE id = ?
            """,
            [.text(sessionID)]
        ) { row in
            RollupKey(
                day: self.dayString(for: Date(timeIntervalSince1970: row.double(1))),
                project: row.string(0),
                usage: TokenUsage(
                    freshInput: row.int(2),
                    cacheCreation: row.int(3),
                    cacheRead: row.int(4),
                    output: row.int(5),
                    thinking: row.int(6)
                ) + TokenUsage(
                    freshInput: row.int(7),
                    cacheCreation: row.int(8),
                    cacheRead: row.int(9),
                    output: row.int(10),
                    thinking: row.int(11)
                )
            )
        }
    }

    /// Adds (or, with `sign: -1`, subtracts) one session's contribution to a
    /// `(day, project)` bucket, then drops the bucket if it has emptied out.
    private func applyRollup(
        day: String,
        project: String,
        usage: TokenUsage,
        sign: Int64,
        sessionCountDelta: Int64,
        in database: SQLiteDatabase
    ) throws {
        try database.execute(
            """
            INSERT INTO daily_rollups
                (day, project_name, fresh_input, cache_creation, cache_read, output, thinking, session_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day, project_name) DO UPDATE SET
                fresh_input    = fresh_input    + excluded.fresh_input,
                cache_creation = cache_creation + excluded.cache_creation,
                cache_read     = cache_read     + excluded.cache_read,
                output         = output         + excluded.output,
                thinking       = thinking       + excluded.thinking,
                session_count  = session_count  + excluded.session_count
            """,
            [
                .text(day),
                .text(project),
                .integer(sign * Int64(usage.freshInput)),
                .integer(sign * Int64(usage.cacheCreation)),
                .integer(sign * Int64(usage.cacheRead)),
                .integer(sign * Int64(usage.output)),
                .integer(sign * Int64(usage.thinking)),
                .integer(sessionCountDelta),
            ]
        )

        if sign < 0 || sessionCountDelta < 0 {
            try database.execute(
                """
                DELETE FROM daily_rollups
                 WHERE day = ? AND project_name = ?
                   AND session_count <= 0
                   AND fresh_input = 0 AND cache_creation = 0 AND cache_read = 0
                   AND output = 0 AND thinking = 0
                """,
                [.text(day), .text(project)]
            )
        }
    }

    /// Runs `body`, converting any failure into a health downgrade and a count.
    ///
    /// Nothing in the store throws to its caller: the domain contract is
    /// non-throwing, and a persistence failure must not become a UI failure.
    /// The count is what makes the swallowed failure visible anyway, to a
    /// caller that wants to know whether its own read answered.
    @discardableResult
    private func perform<T>(
        _ label: String,
        default fallback: T,
        _ body: (SQLiteDatabase) throws -> T
    ) -> T {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard let database else {
            // The query never ran. Counted the same as a failure, because from
            // the caller's side the outcome is identical: the fallback below is
            // this type's own default, not a measurement.
            noteUnanswered()
            return fallback
        }
        do {
            let value = try body(database)
            noteRecovery()
            return value
        } catch {
            note(failure: error, while: label)
            return fallback
        }
    }

    private func perform(_ label: String, _ body: (SQLiteDatabase) throws -> Void) {
        perform(label, default: (), body)
    }

    /// Records a failure, every time and not only the first.
    ///
    /// This was a `switch` that moved `_health` to `.degraded` once and took a
    /// `break` branch for the life of the process. Latched that way, a later
    /// failure left no trace at all, and a caller comparing health either side
    /// of a read concluded the read had been answered.
    private func note(failure error: Error, while label: String) {
        noteUnansweredOnThisThread()
        healthLock.lock()
        defer { healthLock.unlock() }
        _unansweredQueries &+= 1
        // The file opened but a statement failed. Report it without tearing the
        // connection down: a single bad write is not proof the file is gone,
        // and the next write may well succeed.
        _health = .degraded(reason: "\(label) failed: \(error)")
    }

    private func noteUnanswered() {
        noteUnansweredOnThisThread()
        healthLock.lock()
        defer { healthLock.unlock() }
        _unansweredQueries &+= 1
    }

    /// Returns health to what the store opened with.
    ///
    /// Recovery, not promotion. A store that fell back to memory at launch is
    /// still in memory and stays `.degraded` however well it answers; what
    /// clears here is only the extra degradation a failed statement added on
    /// top of that. The count is never decremented: a failure that happened is
    /// a fact, and only the condition of the store is allowed to improve.
    private func noteRecovery() {
        healthLock.lock()
        defer { healthLock.unlock() }
        if _health != baselineHealth { _health = baselineHealth }
    }
}
