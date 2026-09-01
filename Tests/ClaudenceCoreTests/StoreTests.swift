import Foundation
import Testing
@testable import ClaudenceCore

// MARK: - Harness

/// A database in a fresh temporary directory, removed when the test ends.
/// Nothing here ever touches `~/Library/Application Support`.
private final class TempDatabase {
    let directory: URL
    let url: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceStoreTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("claudence.db")
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func makeSession(
    id: String = UUID().uuidString,
    project: String = "Claudence",
    workingDirectory: String = "/Users/test/Claudence",
    pid: Int32 = 4242,
    procStart: String = "2026-09-02T10:00:00Z",
    status: SessionStatus = .running,
    startedAt: Date = Date(),
    lastActivityAt: Date? = nil,
    usage: TokenUsage = .zero,
    model: String? = "claude-opus-4",
    version: String? = "2.0.1"
) -> AISession {
    AISession(
        id: id,
        provider: .claudeCode,
        pid: pid,
        procStart: procStart,
        projectName: project,
        workingDirectory: workingDirectory,
        status: status,
        startedAt: startedAt,
        lastActivityAt: lastActivityAt ?? startedAt,
        usage: usage,
        model: model,
        claudeCodeVersion: version
    )
}

// MARK: - Schema and migration

@Test("open, migrate, reopen: user_version advances once and migration is idempotent")
func migrationIsIdempotent() throws {
    let temp = TempDatabase()

    let fresh = try SQLiteDatabase(url: temp.url)
    #expect(try Schema.userVersion(fresh) == 0)
    let applied = try Schema.migrate(fresh)
    #expect(applied == Schema.current)
    #expect(Schema.current > 0)

    // Re-running against the same connection changes nothing.
    let again = try Schema.migrate(fresh)
    #expect(again == Schema.current)
    fresh.close()

    // Reopening the file finds the version already set and does no work.
    let reopened = try SQLiteDatabase(url: temp.url)
    #expect(try Schema.userVersion(reopened) == Schema.current)
    #expect(try Schema.migrate(reopened) == Schema.current)

    let tables = try reopened.query(
        "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
    ) { $0.string(0) }
    for expected in ["daily_rollups", "read_cursors", "sessions", "usage_samples"] {
        #expect(tables.contains(expected), "missing table \(expected)")
    }
    reopened.close()
}

@Test("a store opened on a temp path reports healthy and persists across reopen")
func storeSurvivesReopen() {
    let temp = TempDatabase()
    let session = makeSession(id: "persisted", usage: TokenUsage(freshInput: 7))

    do {
        let store = ClaudenceStore(url: temp.url)
        #expect(store.health == .healthy)
        store.upsert(session: session)
    }

    let reopened = ClaudenceStore(url: temp.url)
    #expect(reopened.health == .healthy)
    #expect(reopened.session(id: "persisted")?.usage.freshInput == 7)
}

// MARK: - Sessions

@Test("insert and read back a session with exact token components")
func roundTripSession() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)

    let started = Date(timeIntervalSince1970: 1_772_000_000)
    let active = started.addingTimeInterval(600)
    let usage = TokenUsage(
        freshInput: 2_137,
        cacheCreation: 22_004,
        cacheRead: 24_915,
        output: 8_211,
        thinking: 1_204
    )
    let session = makeSession(
        id: "abc-123",
        project: "Claudence",
        workingDirectory: "/Users/test/Claudence",
        pid: 90_210,
        procStart: "2026-09-02T09:15:00Z",
        startedAt: started,
        lastActivityAt: active,
        usage: usage,
        model: "claude-opus-4-1",
        version: "2.0.14"
    )
    store.upsert(session: session)

    let loaded = try! #require(store.session(id: "abc-123"))
    #expect(loaded.id == "abc-123")
    #expect(loaded.provider == .claudeCode)
    #expect(loaded.pid == 90_210)
    #expect(loaded.procStart == "2026-09-02T09:15:00Z")
    #expect(loaded.projectName == "Claudence")
    #expect(loaded.workingDirectory == "/Users/test/Claudence")
    #expect(loaded.model == "claude-opus-4-1")
    #expect(loaded.claudeCodeVersion == "2.0.14")
    #expect(abs(loaded.startedAt.timeIntervalSince(started)) < 0.001)
    #expect(abs(loaded.lastActivityAt.timeIntervalSince(active)) < 0.001)

    // Components exact, not rounded, not recombined.
    #expect(loaded.usage.freshInput == 2_137)
    #expect(loaded.usage.cacheCreation == 22_004)
    #expect(loaded.usage.cacheRead == 24_915)
    #expect(loaded.usage.output == 8_211)
    #expect(loaded.usage.thinking == 1_204)
    #expect(loaded.usage == usage)
}

@Test("total and billableInput derive from the stored components after a round trip")
func derivedTotalsSurviveRoundTrip() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)

    let usage = TokenUsage(
        freshInput: 2_100,
        cacheCreation: 22_000,
        cacheRead: 24_900,
        output: 8_200,
        thinking: 900
    )
    store.upsert(session: makeSession(id: "derived", usage: usage))

    let loaded = try! #require(store.session(id: "derived"))
    #expect(loaded.usage.billableInput == 2_100 + 22_000 + 24_900)
    #expect(loaded.usage.total == 2_100 + 22_000 + 24_900 + 8_200)
    #expect(loaded.usage.billableInput == usage.billableInput)
    #expect(loaded.usage.total == usage.total)
    // Thinking is carried but is not part of the total, exactly as the domain
    // struct defines it.
    #expect(loaded.usage.total != loaded.usage.total + loaded.usage.thinking)

    // Nothing derived is stored on disk.
    let columns = try! store.connection!.query("PRAGMA table_info(sessions)") { $0.string(1) }
    #expect(!columns.contains("total"))
    #expect(!columns.contains("billable_input"))
}

@Test("upsert updates in place rather than duplicating")
func upsertReplacesRow() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let started = Date()

    store.upsert(session: makeSession(id: "one", startedAt: started, usage: TokenUsage(freshInput: 10)))
    store.upsert(session: makeSession(id: "one", startedAt: started, usage: TokenUsage(freshInput: 40, output: 5)))

    #expect(store.allSessions().count == 1)
    let loaded = try! #require(store.session(id: "one"))
    #expect(loaded.usage.freshInput == 40)
    #expect(loaded.usage.output == 5)
}

@Test("markEnded records an end time and the session reads back completed")
func markEndedSetsCompletion() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let started = Date(timeIntervalSince1970: 1_772_100_000)

    store.upsert(session: makeSession(id: "ending", startedAt: started))
    #expect(store.session(id: "ending")?.status == .idle)

    let ended = started.addingTimeInterval(3_600)
    store.markEnded(sessionID: "ending", at: ended)

    let loaded = try! #require(store.session(id: "ending"))
    #expect(loaded.status == .completed)
    #expect(abs(loaded.lastActivityAt.timeIntervalSince(ended)) < 0.001)
}

@Test("allSessions filters by since and orders by most recent activity")
func allSessionsFilterAndOrder() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let now = Date()

    store.upsert(session: makeSession(id: "old", startedAt: now.addingTimeInterval(-10_000)))
    store.upsert(session: makeSession(id: "mid", startedAt: now.addingTimeInterval(-5_000)))
    store.upsert(session: makeSession(id: "new", startedAt: now))

    #expect(store.allSessions().map(\.id) == ["new", "mid", "old"])
    #expect(store.allSessions(since: now.addingTimeInterval(-6_000)).map(\.id) == ["new", "mid"])
}

// MARK: - Cursors

@Test("cursor saves, loads and overwrites")
func cursorRoundTripAndOverwrite() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)

    #expect(store.cursor(forSession: "missing") == nil)

    let first = ReadCursor(path: "/Users/test/.claude/projects/a/s.jsonl", inode: 1_234_567, byteOffset: 0)
    store.saveCursor(first, forSession: "s1")
    #expect(store.cursor(forSession: "s1") == first)

    // Same file, further along.
    let advanced = ReadCursor(path: first.path, inode: first.inode, byteOffset: 12_582_912)
    store.saveCursor(advanced, forSession: "s1")
    #expect(store.cursor(forSession: "s1") == advanced)

    // Rotation: new inode, offset back to zero.
    let rotated = ReadCursor(path: first.path, inode: 7_654_321, byteOffset: 0)
    store.saveCursor(rotated, forSession: "s1")
    #expect(store.cursor(forSession: "s1") == rotated)

    // One row per session, never a history.
    let count = try! store.connection!.scalarInt64("SELECT COUNT(*) FROM read_cursors")
    #expect(count == 1)

    // Cursors are per session.
    store.saveCursor(first, forSession: "s2")
    #expect(store.cursor(forSession: "s2") == first)
    #expect(store.cursor(forSession: "s1") == rotated)
}

@Test("a cursor with a high-bit inode survives the signed storage round trip")
func cursorHandlesUnsignedExtremes() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)

    let extreme = ReadCursor(path: "/tmp/huge.jsonl", inode: UInt64.max, byteOffset: UInt64(Int64.max) + 1)
    store.saveCursor(extreme, forSession: "extreme")
    #expect(store.cursor(forSession: "extreme") == extreme)
}

@Test("the store satisfies CursorStoring through the protocol seam")
func storeConformsToCursorStoring() {
    let temp = TempDatabase()
    let seam: any CursorStoring = ClaudenceStore(url: temp.url)
    let cursor = ReadCursor(path: "/tmp/x.jsonl", inode: 9, byteOffset: 90)
    seam.saveCursor(cursor, forSession: "seam")
    #expect(seam.cursor(forSession: "seam") == cursor)
}

// MARK: - Usage samples

@Test("usage samples come back ordered by time")
func usageSamplesOrderedByTime() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let base = Date(timeIntervalSince1970: 1_772_200_000)

    // Written out of order on purpose.
    store.recordUsageSample(sessionID: "s", usage: TokenUsage(freshInput: 300), at: base.addingTimeInterval(120))
    store.recordUsageSample(sessionID: "s", usage: TokenUsage(freshInput: 100), at: base)
    store.recordUsageSample(sessionID: "s", usage: TokenUsage(freshInput: 200), at: base.addingTimeInterval(60))
    store.recordUsageSample(sessionID: "other", usage: TokenUsage(freshInput: 999), at: base)

    let samples = store.usageSamples(sessionID: "s")
    #expect(samples.map(\.usage.freshInput) == [100, 200, 300])
    #expect(samples.map(\.sampledAt) == [base, base.addingTimeInterval(60), base.addingTimeInterval(120)])

    let windowed = store.usageSamples(sessionID: "s", since: base.addingTimeInterval(60))
    #expect(windowed.map(\.usage.freshInput) == [200, 300])

    // Samples never leak between sessions.
    #expect(store.usageSamples(sessionID: "other").map(\.usage.freshInput) == [999])
}

@Test("usage samples do not feed the rollups")
func usageSamplesDoNotDoubleCount() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let now = Date()

    store.upsert(session: makeSession(id: "s", project: "P", startedAt: now, usage: TokenUsage(freshInput: 500)))
    store.recordUsageSample(sessionID: "s", usage: TokenUsage(freshInput: 500), at: now)
    store.recordUsageSample(sessionID: "s", usage: TokenUsage(freshInput: 500), at: now.addingTimeInterval(1))

    let totals = store.dailyTotals(days: 1)
    #expect(totals.count == 1)
    #expect(totals.first?.usage.freshInput == 500)
}

// MARK: - Aggregates

@Test("daily totals aggregate across sessions and projects")
func dailyTotalsAggregate() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let now = Date()
    let today = ClaudenceStore.dayString(for: now)

    store.upsert(session: makeSession(
        id: "a", project: "Alpha", startedAt: now,
        usage: TokenUsage(freshInput: 100, cacheCreation: 200, cacheRead: 300, output: 40, thinking: 5)
    ))
    store.upsert(session: makeSession(
        id: "b", project: "Beta", startedAt: now,
        usage: TokenUsage(freshInput: 10, cacheCreation: 20, cacheRead: 30, output: 4, thinking: 1)
    ))

    let totals = store.dailyTotals(days: 7)
    let todayRow = try! #require(totals.first { $0.day == today })
    #expect(todayRow.usage.freshInput == 110)
    #expect(todayRow.usage.cacheCreation == 220)
    #expect(todayRow.usage.cacheRead == 330)
    #expect(todayRow.usage.output == 44)
    #expect(todayRow.usage.thinking == 6)
    #expect(todayRow.usage.billableInput == 660)
    #expect(todayRow.usage.total == 704)
}

@Test("daily totals span days and come back oldest first, windowed by the day count")
func dailyTotalsWindowAndOrder() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let now = Date()
    let calendar = Calendar.current

    let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now)!
    let tenDaysAgo = calendar.date(byAdding: .day, value: -10, to: now)!

    store.upsert(session: makeSession(id: "today", project: "P", startedAt: now, usage: TokenUsage(output: 1)))
    store.upsert(session: makeSession(id: "recent", project: "P", startedAt: twoDaysAgo, usage: TokenUsage(output: 2)))
    store.upsert(session: makeSession(id: "ancient", project: "P", startedAt: tenDaysAgo, usage: TokenUsage(output: 3)))

    let week = store.dailyTotals(days: 7)
    #expect(week.count == 2)
    #expect(week.map(\.day) == week.map(\.day).sorted())
    #expect(week.map(\.usage.output) == [2, 1])

    let fortnight = store.dailyTotals(days: 14)
    #expect(fortnight.count == 3)
    #expect(fortnight.map(\.usage.output) == [3, 2, 1])

    #expect(store.dailyTotals(days: 0).isEmpty)
}

@Test("rollups stay consistent when a session's usage is updated repeatedly")
func rollupsDoNotDoubleCountOnUpdate() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let now = Date()

    for value in [100, 250, 900] {
        store.upsert(session: makeSession(id: "growing", project: "P", startedAt: now, usage: TokenUsage(freshInput: value)))
    }

    let totals = store.dailyTotals(days: 1)
    #expect(totals.count == 1)
    #expect(totals.first?.usage.freshInput == 900)

    let count = try! store.connection!.scalarInt64("SELECT session_count FROM daily_rollups WHERE project_name = 'P'")
    #expect(count == 1)

    // The incremental path agrees with a full recompute.
    store.recomputeRollups()
    #expect(store.dailyTotals(days: 1).first?.usage.freshInput == 900)
}

@Test("rollups follow a session when its project changes")
func rollupsFollowProjectRename() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let now = Date()

    store.upsert(session: makeSession(id: "moving", project: "Old", startedAt: now, usage: TokenUsage(freshInput: 500)))
    store.upsert(session: makeSession(id: "moving", project: "New", startedAt: now, usage: TokenUsage(freshInput: 500)))

    let rows = try! store.connection!.query(
        "SELECT project_name, fresh_input, session_count FROM daily_rollups ORDER BY project_name"
    ) { ($0.string(0), $0.int(1), $0.int(2)) }

    #expect(rows.count == 1)
    #expect(rows.first?.0 == "New")
    #expect(rows.first?.1 == 500)
    #expect(rows.first?.2 == 1)
    #expect(store.dailyTotals(days: 1).first?.usage.freshInput == 500)
}

@Test("project totals group by project and count sessions")
func projectTotalsGroupAndCount() {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let now = Date()

    store.upsert(session: makeSession(id: "a1", project: "Alpha", startedAt: now,
                                      usage: TokenUsage(freshInput: 100, output: 10)))
    store.upsert(session: makeSession(id: "a2", project: "Alpha", startedAt: now.addingTimeInterval(-60),
                                      usage: TokenUsage(freshInput: 200, cacheRead: 50, output: 20)))
    store.upsert(session: makeSession(id: "b1", project: "Beta", startedAt: now,
                                      usage: TokenUsage(freshInput: 5, output: 1)))

    let totals = store.projectTotals()
    #expect(totals.count == 2)

    let alpha = try! #require(totals.first { $0.project == "Alpha" })
    #expect(alpha.sessionCount == 2)
    #expect(alpha.usage.freshInput == 300)
    #expect(alpha.usage.cacheRead == 50)
    #expect(alpha.usage.output == 30)
    #expect(alpha.usage.total == 380)

    let beta = try! #require(totals.first { $0.project == "Beta" })
    #expect(beta.sessionCount == 1)
    #expect(beta.usage.total == 6)

    // Heaviest project first.
    #expect(totals.first?.project == "Alpha")

    // `since` is an instant, not a day boundary.
    let recent = store.projectTotals(since: now.addingTimeInterval(-30))
    let recentAlpha = try! #require(recent.first { $0.project == "Alpha" })
    #expect(recentAlpha.sessionCount == 1)
    #expect(recentAlpha.usage.freshInput == 100)
}

// MARK: - Transactions

@Test("a transaction that throws rolls back every statement in it")
func transactionRollsBackOnThrow() throws {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let database = try #require(store.connection)

    store.upsert(session: makeSession(id: "keeper", project: "Kept"))

    struct Boom: Error {}

    #expect(throws: Boom.self) {
        try database.withTransaction {
            try database.execute("DELETE FROM sessions")
            try database.execute(
                """
                INSERT INTO sessions (id, project_name, working_directory, provider, pid, proc_start,
                                      started_at, last_activity_at, fresh_input, cache_creation,
                                      cache_read, output, thinking)
                VALUES ('ghost', 'Ghost', '/tmp', 'claudeCode', 1, 'x', 0, 0, 0, 0, 0, 0, 0)
                """
            )
            throw Boom()
        }
    }

    #expect(store.session(id: "keeper") != nil)
    #expect(store.session(id: "ghost") == nil)
    #expect(store.allSessions().count == 1)

    // The connection is still usable after a rollback.
    try database.withTransaction {
        try database.execute("DELETE FROM sessions WHERE id = 'nobody'")
    }
    #expect(store.allSessions().count == 1)
}

@Test("a nested transaction rolls back to its savepoint without losing the outer work")
func nestedTransactionRollsBackToSavepoint() throws {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let database = try #require(store.connection)
    struct Boom: Error {}

    try database.withTransaction {
        try database.execute(
            "INSERT INTO read_cursors (session_id, path, inode, byte_offset) VALUES ('outer', '/a', 1, 1)"
        )
        try? database.withTransaction {
            try database.execute(
                "INSERT INTO read_cursors (session_id, path, inode, byte_offset) VALUES ('inner', '/b', 2, 2)"
            )
            throw Boom()
        }
    }

    #expect(store.cursor(forSession: "outer") != nil)
    #expect(store.cursor(forSession: "inner") == nil)
}

// MARK: - Binding correctness

@Test("string binding survives quotes, backslashes and an embedded NUL")
func stringBindingIsParameterized() throws {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let database = try #require(store.connection)

    // A single quote would end the literal if this were interpolated, and the
    // trailing fragment is a valid statement on its own.
    let hostile = "O'Brien'); DROP TABLE sessions; --"
    // An embedded NUL: `sqlite3_bind_text` with a -1 length stops here, so the
    // tail only survives if the byte count is passed explicitly.
    let withNUL = "before\u{0}after"
    let backslashes = "C:\\Users\\test\\a\"b"

    store.upsert(session: makeSession(id: hostile, project: withNUL, workingDirectory: backslashes))

    // The table is still there, so the injection fragment was data, not SQL.
    #expect(store.allSessions().count == 1)

    let loaded = try #require(store.session(id: hostile))
    #expect(loaded.id == hostile)
    #expect(loaded.projectName == withNUL)
    #expect(loaded.projectName.unicodeScalars.contains("\u{0}"))
    #expect(loaded.projectName.hasSuffix("after"))
    #expect(loaded.workingDirectory == backslashes)

    // The stored byte length proves SQLite kept the whole string, NUL included,
    // rather than truncating at it.
    let byteLength = try database.scalarInt64(
        "SELECT LENGTH(CAST(project_name AS BLOB)) FROM sessions WHERE id = ?",
        [.text(hostile)]
    )
    #expect(byteLength == Int64(withNUL.utf8.count))

    // A parameterized lookup on the NUL-bearing value matches exactly.
    let matches = try database.scalarInt64(
        "SELECT COUNT(*) FROM sessions WHERE project_name = ?",
        [.text(withNUL)]
    )
    #expect(matches == 1)

    // A cursor path gets the same treatment.
    let cursor = ReadCursor(path: "/tmp/it's a 'path'\u{0}x.jsonl", inode: 5, byteOffset: 5)
    store.saveCursor(cursor, forSession: hostile)
    #expect(store.cursor(forSession: hostile) == cursor)
}

@Test("every bindable type round trips, including empty and NULL")
func valueBindingRoundTrip() throws {
    let temp = TempDatabase()
    let database = try SQLiteDatabase(url: temp.url)
    try database.execute("CREATE TABLE t (i INTEGER, d REAL, s TEXT, b BLOB, n TEXT)")
    try database.execute(
        "INSERT INTO t (i, d, s, b, n) VALUES (?, ?, ?, ?, ?)",
        [.integer(Int64.min), .real(0.5), .text(""), .blob(Data()), .null]
    )
    try database.execute(
        "INSERT INTO t (i, d, s, b, n) VALUES (?, ?, ?, ?, ?)",
        [.integer(Int64.max), .real(-1.25), .text("ok"), .blob(Data([0, 1, 255])), .text("here")]
    )

    let rows = try database.query("SELECT i, d, s, b, n FROM t ORDER BY i") { row in
        (row.int64(0), row.double(1), row.stringOptional(2), row.dataOptional(3), row.stringOptional(4))
    }

    #expect(rows.count == 2)
    #expect(rows[0].0 == Int64.min)
    #expect(rows[0].1 == 0.5)
    // An empty string stays an empty string, never NULL.
    #expect(rows[0].2 == "")
    #expect(rows[0].3 == Data())
    #expect(rows[0].4 == nil)
    #expect(rows[1].0 == Int64.max)
    #expect(rows[1].1 == -1.25)
    #expect(rows[1].2 == "ok")
    #expect(rows[1].3 == Data([0, 1, 255]))
    #expect(rows[1].4 == "here")

    // A parameter-count mismatch is caught before it reaches SQLite.
    #expect(throws: SQLiteError.self) {
        try database.execute("INSERT INTO t (i) VALUES (?)", [])
    }
    database.close()
}

// MARK: - Concurrency

@Test("concurrent writes from many tasks neither corrupt nor deadlock")
func concurrentWritesAreSafe() async throws {
    let temp = TempDatabase()
    let store = ClaudenceStore(url: temp.url)
    let taskCount = 8
    let perTask = 25
    let started = Date()

    await withTaskGroup(of: Void.self) { group in
        for task in 0..<taskCount {
            group.addTask {
                for index in 0..<perTask {
                    let id = "s-\(task)-\(index)"
                    store.upsert(session: makeSession(
                        id: id,
                        project: "P\(task % 3)",
                        startedAt: started,
                        usage: TokenUsage(freshInput: 1, output: 1)
                    ))
                    store.recordUsageSample(
                        sessionID: id,
                        usage: TokenUsage(freshInput: 1),
                        at: started.addingTimeInterval(Double(index))
                    )
                    store.saveCursor(
                        ReadCursor(path: "/tmp/\(id).jsonl", inode: UInt64(index), byteOffset: UInt64(index * 100)),
                        forSession: id
                    )
                    // Interleave reads with the writes.
                    _ = store.session(id: id)
                    _ = store.dailyTotals(days: 1)
                }
            }
        }
    }

    #expect(store.health == .healthy)
    #expect(store.allSessions().count == taskCount * perTask)

    let database = try #require(store.connection)
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM usage_samples") == Int64(taskCount * perTask))
    #expect(try database.scalarInt64("SELECT COUNT(*) FROM read_cursors") == Int64(taskCount * perTask))

    // Rollups agree with the sessions table: no lost or doubled increments.
    let projects = store.projectTotals()
    #expect(projects.reduce(0) { $0 + $1.sessionCount } == taskCount * perTask)
    let day = store.dailyTotals(days: 1)
    #expect(day.count == 1)
    #expect(day.first?.usage.freshInput == taskCount * perTask)
    #expect(day.first?.usage.output == taskCount * perTask)

    #expect(try database.scalarString("PRAGMA integrity_check") == "ok")
}

@Test("two connections on the same file interleave writes without SQLITE_BUSY")
func separateConnectionsShareTheFile() async throws {
    let temp = TempDatabase()
    let writerA = ClaudenceStore(url: temp.url)
    let writerB = ClaudenceStore(url: temp.url)
    let started = Date()

    // WAL is what lets a second connection write while the first reads.
    let mode = try writerA.connection?.scalarString("PRAGMA journal_mode")
    #expect(mode == "wal")

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for index in 0..<40 {
                writerA.upsert(session: makeSession(id: "a-\(index)", project: "A", startedAt: started,
                                                    usage: TokenUsage(freshInput: 2)))
            }
        }
        group.addTask {
            for index in 0..<40 {
                writerB.upsert(session: makeSession(id: "b-\(index)", project: "B", startedAt: started,
                                                    usage: TokenUsage(freshInput: 3)))
            }
        }
        group.addTask {
            for _ in 0..<40 {
                _ = writerA.allSessions()
                _ = writerB.projectTotals()
            }
        }
    }

    #expect(writerA.health == .healthy)
    #expect(writerB.health == .healthy)
    #expect(writerA.allSessions().count == 80)

    let totals = writerB.projectTotals()
    #expect(try #require(totals.first { $0.project == "A" }).sessionCount == 40)
    #expect(try #require(totals.first { $0.project == "B" }).sessionCount == 40)
}

// MARK: - Degraded state

@Test("an unopenable path degrades to memory instead of crashing")
func unopenablePathDegrades() {
    // A path whose parent cannot be created: `/dev/null` is a file, so a
    // directory under it is impossible.
    let impossible = URL(fileURLWithPath: "/dev/null/claudence/claudence.db")
    let store = ClaudenceStore(url: impossible)

    if case .degraded(let reason) = store.health {
        #expect(!reason.isEmpty)
    } else {
        Issue.record("expected a degraded store, got \(store.health)")
    }

    // Still fully functional, just not persistent.
    store.upsert(session: makeSession(id: "in-memory", usage: TokenUsage(freshInput: 3)))
    #expect(store.session(id: "in-memory")?.usage.freshInput == 3)
    #expect(store.health.isPersistent == false)
}

@Test("a corrupt database file degrades to memory instead of crashing")
func corruptFileDegrades() throws {
    let temp = TempDatabase()
    try FileManager.default.createDirectory(at: temp.directory, withIntermediateDirectories: true)
    // A valid-length file that is not a database.
    try Data(repeating: 0x41, count: 8_192).write(to: temp.url)

    let store = ClaudenceStore(url: temp.url)
    #expect(store.health.isPersistent == false)
    #expect(store.health.reason?.isEmpty == false)

    store.upsert(session: makeSession(id: "still-works"))
    #expect(store.session(id: "still-works") != nil)
}

@Test("a database written by a newer schema is refused rather than downgraded")
func newerSchemaIsRefused() throws {
    let temp = TempDatabase()
    let seeded = try SQLiteDatabase(url: temp.url)
    try seeded.execute("PRAGMA user_version = \(Schema.current + 10)")
    seeded.close()

    #expect(throws: SQLiteError.self) {
        let database = try SQLiteDatabase(url: temp.url)
        defer { database.close() }
        try Schema.migrate(database)
    }

    let store = ClaudenceStore(url: temp.url)
    #expect(store.health.isPersistent == false)
}

@Test("a closed connection reports misuse rather than trapping")
func closedConnectionThrows() throws {
    let temp = TempDatabase()
    let database = try SQLiteDatabase(url: temp.url)
    try Schema.migrate(database)
    database.close()
    database.close() // idempotent

    #expect(throws: SQLiteError.self) {
        try database.execute("SELECT 1")
    }
}
