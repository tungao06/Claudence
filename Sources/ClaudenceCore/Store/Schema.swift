import Foundation
import SQLite3

/// The persisted schema and its migrations.
///
/// Versioning is driven by `PRAGMA user_version`, an integer SQLite keeps in the
/// database header for exactly this purpose. It costs no table and no extra read.
///
/// A migration is applied when `user_version < migration.version`, and the whole
/// ladder runs inside one transaction, so an interrupted upgrade leaves the file
/// on its previous version rather than half-migrated.
///
/// Adding a migration means appending to `migrations` and bumping nothing else:
/// `current` is derived from the list.
public enum Schema {

    /// One step of the ladder. `version` is the value `user_version` takes on
    /// after `statements` have run.
    struct Migration {
        let version: Int32
        let statements: [String]
    }

    /// The version this build expects. Derived, never hand-maintained.
    public static var current: Int32 { migrations.last?.version ?? 0 }

    static let migrations: [Migration] = [
        Migration(version: 1, statements: migration1),
        Migration(version: 2, statements: migration2),
        Migration(version: 3, statements: migration3),
    ]

    // MARK: - v1

    private static let migration1: [String] = [
        // A session as last observed. Token counts are stored as the five
        // components only: `total` and `billableInput` are derived by
        // `TokenUsage` and never persisted, so there is one definition of them.
        """
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            project_name TEXT NOT NULL,
            working_directory TEXT NOT NULL,
            provider TEXT NOT NULL,
            pid INTEGER NOT NULL,
            proc_start TEXT NOT NULL,
            started_at REAL NOT NULL,
            last_activity_at REAL NOT NULL,
            ended_at REAL,
            model TEXT,
            claude_code_version TEXT,
            fresh_input INTEGER NOT NULL DEFAULT 0,
            cache_creation INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            thinking INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_sessions_started_at ON sessions (started_at)",
        "CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions (project_name)",

        // Where the transcript reader left off, one row per session.
        // `inode` and `byte_offset` are `UInt64` in the domain model but SQLite
        // integers are signed 64-bit, so they are stored bit-for-bit via
        // `Int64(bitPattern:)` and read back the same way. A raw cast would trap
        // on an inode above `Int64.max`.
        """
        CREATE TABLE IF NOT EXISTS read_cursors (
            session_id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            inode INTEGER NOT NULL,
            byte_offset INTEGER NOT NULL
        )
        """,

        // A point-in-time snapshot of a session's cumulative usage. Samples are
        // what the burn-rate sparkline is computed from; deltas are taken
        // between consecutive rows, never stored.
        """
        CREATE TABLE IF NOT EXISTS usage_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            sampled_at REAL NOT NULL,
            fresh_input INTEGER NOT NULL DEFAULT 0,
            cache_creation INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            thinking INTEGER NOT NULL DEFAULT 0
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_usage_samples_session_time ON usage_samples (session_id, sampled_at)",

        // Per-day, per-project token totals.
        //
        // TIMEZONE ASSUMPTION: `day` is a *local* calendar date rendered
        // "YYYY-MM-DD" using the machine's current time zone at the moment the
        // row is written, not UTC. "Today" in the dashboard has to mean the
        // user's today, and a UTC day boundary would cut a late-evening session
        // in half for anyone east or west of Greenwich. The consequence is that
        // rollups are not portable across time zones: moving the machine, or a
        // DST shift, changes which day a future session lands in but does not
        // rewrite history. Existing rows are never re-bucketed.
        """
        CREATE TABLE IF NOT EXISTS daily_rollups (
            day TEXT NOT NULL,
            project_name TEXT NOT NULL,
            fresh_input INTEGER NOT NULL DEFAULT 0,
            cache_creation INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            thinking INTEGER NOT NULL DEFAULT 0,
            session_count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, project_name)
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_daily_rollups_day ON daily_rollups (day)",
    ]

    // MARK: - v3

    private static let migration3: [String] = [
        // `usage_samples` is queried two ways and indexed for only one of them.
        // The primary key covers `(session_id, sampled_at)`, which serves the
        // per-session burn-rate read, but `usageSamples(in:)` filters on
        // `sampled_at` alone for the hourly chart, the window share and the
        // rollup repair, and with no index on that column each of those is a
        // full table scan. Measured cadence on this machine is 17 to 36 samples
        // an hour per active session, so a month is tens of thousands of rows
        // and a year is hundreds of thousands, scanned on every dashboard read.
        """
        CREATE INDEX IF NOT EXISTS idx_usage_samples_sampled_at
            ON usage_samples(sampled_at)
        """,
    ]

    // MARK: - v2

    private static let migration2: [String] = [
        // Accumulated tokens per subagent.
        //
        // `read_cursors` already survives a restart, so a subagent transcript
        // resumes at the byte offset it reached last run. Without a persisted
        // total to resume from, everything written before that offset is never
        // read again and the figure collapses to whatever arrived since launch.
        // The cursor and the total have to be durable together or neither is
        // useful.
        //
        // Token counts are the five components only, matching `sessions`:
        // `total` and `billableInput` stay derived by `TokenUsage` so there is
        // one definition of them.
        //
        // `task_description` comes from the `meta.json` Claude Code writes
        // beside the transcript. It is a task label, not message content, and
        // is the same field `AISubagent` already carries.
        //
        // No secondary index: every query is by `parent_session_id`, which is
        // the leading column of the primary key, so SQLite's automatic index on
        // that key already serves it. A second index would only cost writes.
        """
        CREATE TABLE IF NOT EXISTS subagent_totals (
            parent_session_id TEXT NOT NULL,
            subagent_id TEXT NOT NULL,
            agent_type TEXT,
            task_description TEXT,
            spawn_depth INTEGER NOT NULL DEFAULT 1,
            model TEXT,
            last_activity_at REAL,
            records_parsed INTEGER NOT NULL DEFAULT 0,
            fresh_input INTEGER NOT NULL DEFAULT 0,
            cache_creation INTEGER NOT NULL DEFAULT 0,
            cache_read INTEGER NOT NULL DEFAULT 0,
            output INTEGER NOT NULL DEFAULT 0,
            thinking INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (parent_session_id, subagent_id)
        )
        """,

        // A session's subagent spend, kept on the session row beside its own.
        //
        // The rollups are derived from this row, and until now the row held
        // parent-transcript tokens only. Measured on this machine, subagents
        // are around 41% of what a session actually spends, so every daily
        // figure under-reported by roughly that much.
        //
        // The two totals stay separate columns rather than one combined
        // figure: the engine seeds its parent accumulator from `usage` and the
        // subagent tracker seeds from `subagent_totals`, and each has to line
        // up with its own read cursor. Collapsing them would leave neither
        // side able to resume. `combinedUsage` is derived from the pair, the
        // same way `total` is derived from the components.
        //
        // ADD COLUMN with a NOT NULL default rewrites nothing: SQLite records
        // the default in the schema and existing rows read back as zero, which
        // is exactly right for a row written before subagents were counted.
        "ALTER TABLE sessions ADD COLUMN subagent_fresh_input INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE sessions ADD COLUMN subagent_cache_creation INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE sessions ADD COLUMN subagent_cache_read INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE sessions ADD COLUMN subagent_output INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE sessions ADD COLUMN subagent_thinking INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE sessions ADD COLUMN subagent_count INTEGER NOT NULL DEFAULT 0",
    ]

    // MARK: - Migration

    /// Brings `database` up to `current`. Idempotent: running it against an
    /// already-current database reads one pragma and does nothing else.
    ///
    /// Throws `SQLiteError` when the file cannot be migrated; the caller decides
    /// whether that is fatal. `ClaudenceStore` treats it as a reason to degrade.
    @discardableResult
    public static func migrate(_ database: SQLiteDatabase) throws -> Int32 {
        let existing = try userVersion(database)

        if existing > current {
            // A newer build wrote this file. Downgrading would drop columns the
            // other build needs, so refuse rather than corrupt.
            throw SQLiteError(
                code: SQLITE_MISMATCH,
                message: "database schema version \(existing) is newer than this build's \(current)",
                sql: "PRAGMA user_version"
            )
        }

        guard existing < current else { return existing }

        try database.withTransaction {
            for migration in migrations where migration.version > existing {
                for statement in migration.statements {
                    try database.execute(statement)
                }
                // `PRAGMA user_version = ?` cannot be parameterized; SQLite
                // requires a literal. The value is an `Int32` from our own
                // table, so interpolating it is not an injection surface.
                try database.execute("PRAGMA user_version = \(migration.version)")
            }
        }

        return try userVersion(database)
    }

    public static func userVersion(_ database: SQLiteDatabase) throws -> Int32 {
        let value = try database.scalarInt64("PRAGMA user_version") ?? 0
        return Int32(truncatingIfNeeded: value)
    }
}
