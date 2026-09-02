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

    private let database: SQLiteDatabase?
    private let healthLock = NSLock()
    private var _health: StoreHealth
    private let calendar: Calendar

    public var health: StoreHealth {
        healthLock.lock()
        defer { healthLock.unlock() }
        return _health
    }

    /// The connection, for tests and for diagnostics. `nil` when unavailable.
    public var connection: SQLiteDatabase? { database }

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

        func openInMemory(reason: String) -> (SQLiteDatabase?, StoreHealth) {
            do {
                let memory = try SQLiteDatabase(url: nil)
                try Schema.migrate(memory)
                return (memory, .degraded(reason: reason))
            } catch {
                return (nil, .unavailable(reason: "\(reason); in-memory fallback also failed: \(error)"))
            }
        }

        if let url {
            do {
                let opened = try SQLiteDatabase(url: url)
                try Schema.migrate(opened)
                self.database = opened
                self._health = .healthy
            } catch {
                let (fallback, health) = openInMemory(
                    reason: "cannot use \(url.path): \(error)"
                )
                self.database = fallback
                self._health = health
            }
        } else {
            // An explicit in-memory store is a deliberate choice, not a failure,
            // so it reports healthy.
            do {
                let memory = try SQLiteDatabase(url: nil)
                try Schema.migrate(memory)
                self.database = memory
                self._health = .healthy
            } catch {
                self.database = nil
                self._health = .unavailable(reason: "cannot open in-memory database: \(error)")
            }
        }
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

    // MARK: - Aggregates

    /// Token totals per local day, oldest first, covering the last `days` days
    /// including today. Days with no activity are omitted.
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
                 WHERE day >= ?
                 GROUP BY day
                 ORDER BY day ASC
                """,
                [.text(lowerBound)]
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

    /// Token totals and session counts per project, heaviest first.
    ///
    /// Computed from `sessions` rather than `daily_rollups` because `since` is an
    /// arbitrary instant while the rollups are only day-granular; reading the
    /// rollups would silently round the window to a day boundary and report a
    /// number the user did not ask for.
    public func projectTotals(since: Date? = nil) -> [(project: String, usage: TokenUsage, sessionCount: Int)] {
        perform("read project totals", default: []) { database in
            let sql = """
                SELECT project_name,
                       SUM(fresh_input), SUM(cache_creation), SUM(cache_read),
                       SUM(output), SUM(thinking), COUNT(*)
                  FROM sessions
                 \(since == nil ? "" : "WHERE started_at >= ?")
                 GROUP BY project_name
                 ORDER BY (SUM(fresh_input) + SUM(cache_creation) + SUM(cache_read) + SUM(output)) DESC,
                          project_name ASC
                """
            let parameters: [SQLiteValue] = since.map { [.real($0.timeIntervalSince1970)] } ?? []
            return try database.query(sql, parameters) { row in
                (
                    project: row.string(0),
                    usage: TokenUsage(
                        freshInput: row.int(1),
                        cacheCreation: row.int(2),
                        cacheRead: row.int(3),
                        output: row.int(4),
                        thinking: row.int(5)
                    ),
                    sessionCount: row.int(6)
                )
            }
        }
    }

    /// Rebuilds `daily_rollups` from `sessions`. O(number of sessions).
    ///
    /// A repair path, not a hot path: use it after an import, a manual edit, or
    /// any suspicion that the incremental updates drifted.
    public func recomputeRollups() {
        perform("recompute rollups") { database in
            try database.withTransaction {
                try database.execute("DELETE FROM daily_rollups")
                // Combined, matching `upsert(session:)`. A repair that used the
                // parent-only figure would quietly rewrite history down by
                // every session's subagent spend.
                let rows = try database.query(
                    """
                    SELECT project_name, started_at,
                           fresh_input, cache_creation, cache_read, output, thinking,
                           subagent_fresh_input, subagent_cache_creation, subagent_cache_read,
                           subagent_output, subagent_thinking
                      FROM sessions
                    """
                ) { row in
                    (
                        project: row.string(0),
                        startedAt: Date(timeIntervalSince1970: row.double(1)),
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
                for row in rows {
                    try self.applyRollup(
                        day: self.dayString(for: row.startedAt),
                        project: row.project,
                        usage: row.usage,
                        sign: 1,
                        sessionCountDelta: 1,
                        in: database
                    )
                }
            }
        }
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
                       spawn_depth, model, last_activity_at, records_parsed,
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
                        freshInput: row.int(8),
                        cacheCreation: row.int(9),
                        cacheRead: row.int(10),
                        output: row.int(11),
                        thinking: row.int(12)
                    ),
                    recordsParsed: row.int(7),
                    lastActivityAt: row.doubleOptional(6).map { Date(timeIntervalSince1970: $0) },
                    spawnDepth: row.int(4),
                    model: row.stringOptional(5)
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
    public func upsertSubagentTotal(_ total: SubagentTotal) {
        perform("upsert subagent total") { database in
            try database.execute(
                """
                INSERT INTO subagent_totals (
                    parent_session_id, subagent_id, agent_type, task_description,
                    spawn_depth, model, last_activity_at, records_parsed,
                    fresh_input, cache_creation, cache_read, output, thinking
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(parent_session_id, subagent_id) DO UPDATE SET
                    agent_type = COALESCE(excluded.agent_type, subagent_totals.agent_type),
                    task_description = COALESCE(excluded.task_description, subagent_totals.task_description),
                    spawn_depth = excluded.spawn_depth,
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
                    .integer(Int64(total.spawnDepth)),
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

    /// Runs `body`, converting any failure into a health downgrade.
    ///
    /// Nothing in the store throws to its caller: the domain contract is
    /// non-throwing, and a persistence failure must not become a UI failure.
    @discardableResult
    private func perform<T>(
        _ label: String,
        default fallback: T,
        _ body: (SQLiteDatabase) throws -> T
    ) -> T {
        guard let database else { return fallback }
        do {
            return try body(database)
        } catch {
            note(failure: error, while: label)
            return fallback
        }
    }

    private func perform(_ label: String, _ body: (SQLiteDatabase) throws -> Void) {
        perform(label, default: (), body)
    }

    private func note(failure error: Error, while label: String) {
        healthLock.lock()
        defer { healthLock.unlock() }
        let reason = "\(label) failed: \(error)"
        switch _health {
        case .healthy:
            // The file opened but a statement failed. Report it without tearing
            // the connection down: a single bad write is not proof the file is
            // gone, and the next write may well succeed.
            _health = .degraded(reason: reason)
        case .degraded, .unavailable:
            break
        }
    }
}
