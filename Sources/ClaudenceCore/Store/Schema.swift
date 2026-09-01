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
        Migration(version: 1, statements: migration1)
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
