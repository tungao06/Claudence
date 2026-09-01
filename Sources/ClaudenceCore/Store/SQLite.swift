import Foundation
import SQLite3

// MARK: - SQLITE_TRANSIENT
//
// `SQLITE_TRANSIENT` is a C macro (`(sqlite3_destructor_type)-1`) and the Swift
// importer does not expose macros that cast integers to function pointers, so it
// has to be reconstructed by hand. Passing it tells SQLite to copy the bytes
// before `sqlite3_bind_*` returns. Without it, SQLite keeps the caller's pointer
// and Swift's temporary buffer is gone by the time the statement steps, which
// reads freed memory rather than failing loudly.
//
// `nonisolated(unsafe)` because a C function pointer is not `Sendable` but is
// immutable and thread-safe in fact.
nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Error

/// Any failure coming out of the C API, carrying the SQLite result code and the
/// message SQLite produced at the moment of failure.
public struct SQLiteError: Error, CustomStringConvertible, Equatable {
    public let code: Int32
    public let message: String
    /// The statement being run when the failure happened, when there was one.
    public let sql: String?

    public init(code: Int32, message: String, sql: String? = nil) {
        self.code = code
        self.message = message
        self.sql = sql
    }

    public var description: String {
        if let sql, !sql.isEmpty {
            return "SQLite error \(code): \(message) [\(sql)]"
        }
        return "SQLite error \(code): \(message)"
    }

    /// Whether the database file itself is unusable, as opposed to a bad statement.
    public var isCorruptionOrAccess: Bool {
        switch code {
        case SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_CANTOPEN, SQLITE_PERM,
             SQLITE_READONLY, SQLITE_IOERR, SQLITE_FULL:
            return true
        default:
            return false
        }
    }
}

// MARK: - Values

/// Every type this wrapper can bind. Nothing else reaches the C API.
public enum SQLiteValue: Sendable, Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public init(_ value: Int) { self = .integer(Int64(value)) }
    public init(_ value: Int64) { self = .integer(value) }
    public init(_ value: Int32) { self = .integer(Int64(value)) }
    public init(_ value: Double) { self = .real(value) }
    public init(_ value: String) { self = .text(value) }
    public init(_ value: Data) { self = .blob(value) }

    public init(_ value: Int?) { self = value.map { .integer(Int64($0)) } ?? .null }
    public init(_ value: Int64?) { self = value.map { .integer($0) } ?? .null }
    public init(_ value: Double?) { self = value.map { .real($0) } ?? .null }
    public init(_ value: String?) { self = value.map { .text($0) } ?? .null }
    public init(_ value: Data?) { self = value.map { .blob($0) } ?? .null }
}

extension SQLiteValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
                       ExpressibleByStringLiteral, ExpressibleByNilLiteral {
    public init(integerLiteral value: Int) { self = .integer(Int64(value)) }
    public init(floatLiteral value: Double) { self = .real(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Row

/// A view onto the current row of a stepping statement.
///
/// Only valid for the duration of the row callback: it holds the raw statement
/// pointer and the next `sqlite3_step` invalidates every column pointer.
public struct SQLiteRow {
    private let statement: OpaquePointer
    private let names: [String: Int32]

    init(statement: OpaquePointer, names: [String: Int32]) {
        self.statement = statement
        self.names = names
    }

    public var columnCount: Int32 { sqlite3_column_count(statement) }

    public func index(of name: String) -> Int32? { names[name] }

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }

    public func int64Optional(_ index: Int32) -> Int64? {
        isNull(index) ? nil : sqlite3_column_int64(statement, index)
    }

    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }

    public func intOptional(_ index: Int32) -> Int? {
        isNull(index) ? nil : Int(sqlite3_column_int64(statement, index))
    }

    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

    public func doubleOptional(_ index: Int32) -> Double? {
        isNull(index) ? nil : sqlite3_column_double(statement, index)
    }

    /// Decoded with an explicit byte count rather than `String(cString:)`, so a
    /// stored value containing an embedded NUL survives the round trip intact.
    public func stringOptional(_ index: Int32) -> String? {
        guard !isNull(index) else { return nil }
        // `sqlite3_column_text` must run before `sqlite3_column_bytes`: the
        // conversion to UTF-8 is what fixes the byte count.
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: count), as: UTF8.self)
    }

    public func string(_ index: Int32) -> String { stringOptional(index) ?? "" }

    public func dataOptional(_ index: Int32) -> Data? {
        guard !isNull(index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    public func data(_ index: Int32) -> Data { dataOptional(index) ?? Data() }

    // Name-addressed accessors, for queries where positional indexes get fragile.
    public func int(_ name: String) -> Int? { index(of: name).map { int($0) } }
    public func double(_ name: String) -> Double? { index(of: name).map { double($0) } }
    public func string(_ name: String) -> String? { index(of: name).flatMap { stringOptional($0) } }
}

// MARK: - Database

/// A single SQLite connection.
///
/// ## Concurrency
///
/// A `final class` guarded by one `NSRecursiveLock`, marked `@unchecked Sendable`.
/// Every method that touches `handle` takes `lock` for its whole duration, and no
/// raw pointer escapes the locked region: prepared statements are created,
/// stepped and finalized inside a single call, and `SQLiteRow` is only handed to
/// a closure that runs while the lock is held.
///
/// An `actor` was rejected because `CursorStoring` in the locked domain contract
/// declares synchronous, non-throwing methods. An actor would force `await` on
/// every call site and the seam would have to change, so the lock is the design
/// that fits the contract. The lock is *recursive* so that `withTransaction` can
/// call `execute`/`query` from inside its body.
///
/// The connection is opened `SQLITE_OPEN_FULLMUTEX` as a second line of defence:
/// even if a pointer ever did escape, SQLite serializes internally.
public final class SQLiteDatabase: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    private var transactionDepth = 0

    /// The file this connection is attached to, or nil for an in-memory database.
    public let fileURL: URL?

    /// How long SQLite waits on a lock held by another connection before
    /// returning `SQLITE_BUSY`. Generous, because writes here are tiny.
    public static let busyTimeoutMilliseconds: Int32 = 5_000

    // MARK: Lifecycle

    /// Opens (and creates, with parent directories) a database at `url`.
    /// Pass nil for a private in-memory database.
    public init(url: URL?) throws {
        self.fileURL = url

        let path: String
        if let url {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            path = url.path
        } else {
            path = ":memory:"
        }

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            // `sqlite3_open_v2` allocates a handle even on failure, so that the
            // error can be read off it. It still has to be closed.
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError(code: rc, message: message, sql: "open \(path)")
        }
        self.handle = handle

        sqlite3_busy_timeout(handle, Self.busyTimeoutMilliseconds)

        // WAL lets a reader run while a writer commits, which is what makes the
        // menu bar refresh without stalling on the transcript writer. It is a
        // no-op for `:memory:`, where SQLite reports `memory` instead, so a
        // mismatch is not an error.
        _ = try? queryFirstUnlocked("PRAGMA journal_mode=WAL") { $0.string(0) }
        try executeUnlocked("PRAGMA synchronous=NORMAL")
        try executeUnlocked("PRAGMA foreign_keys=ON")
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    /// Idempotent. After this, every call throws `SQLITE_MISUSE`.
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    // MARK: Introspection

    public var lastInsertRowID: Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    // MARK: Public API

    /// Runs a statement that returns no rows.
    public func execute(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(sql, parameters)
    }

    /// Runs a query, mapping every row through `transform`.
    ///
    /// The `SQLiteRow` handed to `transform` is only valid inside the call.
    public func query<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        transform: (SQLiteRow) throws -> T
    ) throws -> [T] {
        lock.lock()
        defer { lock.unlock() }
        return try queryUnlocked(sql, parameters, transform: transform)
    }

    /// Runs a query and returns the first row only, stopping the scan there.
    public func queryFirst<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        transform: (SQLiteRow) throws -> T
    ) throws -> T? {
        lock.lock()
        defer { lock.unlock() }
        return try queryFirstUnlocked(sql, parameters, transform: transform)
    }

    public func scalarInt64(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> Int64? {
        try queryFirst(sql, parameters) { $0.int64Optional(0) } ?? nil
    }

    public func scalarString(_ sql: String, _ parameters: [SQLiteValue] = []) throws -> String? {
        try queryFirst(sql, parameters) { $0.stringOptional(0) } ?? nil
    }

    /// Commits when `body` returns, rolls back when it throws.
    ///
    /// Nesting is supported through savepoints, so a store method that already
    /// wraps its work can be called from inside a larger transaction without
    /// SQLite complaining about a nested `BEGIN`.
    ///
    /// The outermost transaction uses `BEGIN IMMEDIATE`: it takes the write lock
    /// up front rather than upgrading mid-transaction, which is the case WAL
    /// cannot resolve and reports as an unrecoverable `SQLITE_BUSY`.
    @discardableResult
    public func withTransaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let depth = transactionDepth
        let savepoint = "claudence_sp_\(depth)"

        if depth == 0 {
            try executeUnlocked("BEGIN IMMEDIATE")
        } else {
            try executeUnlocked("SAVEPOINT \(savepoint)")
        }
        transactionDepth = depth + 1
        defer { transactionDepth = depth }

        do {
            let result = try body()
            if depth == 0 {
                try executeUnlocked("COMMIT")
            } else {
                try executeUnlocked("RELEASE \(savepoint)")
            }
            return result
        } catch {
            // Rollback is best effort: if it fails too, the original error is
            // the one worth reporting.
            if depth == 0 {
                try? executeUnlocked("ROLLBACK")
            } else {
                try? executeUnlocked("ROLLBACK TO \(savepoint)")
                try? executeUnlocked("RELEASE \(savepoint)")
            }
            throw error
        }
    }

    // MARK: - Private, lock already held

    private func executeUnlocked(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        _ = try stepAll(sql, parameters) { _ in () }
    }

    private func queryUnlocked<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        transform: (SQLiteRow) throws -> T
    ) throws -> [T] {
        try stepAll(sql, parameters, transform: transform)
    }

    private func queryFirstUnlocked<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        transform: (SQLiteRow) throws -> T
    ) throws -> T? {
        try stepAll(sql, parameters, limit: 1, transform: transform).first
    }

    /// The one place that prepares, binds, steps and finalizes. The statement
    /// pointer never leaves this function.
    private func stepAll<T>(
        _ sql: String,
        _ parameters: [SQLiteValue],
        limit: Int? = nil,
        transform: (SQLiteRow) throws -> T
    ) throws -> [T] {
        guard let handle else {
            throw SQLiteError(code: SQLITE_MISUSE, message: "database is closed", sql: sql)
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw error(code: prepareResult, sql: sql)
        }
        defer { sqlite3_finalize(statement) }

        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == parameters.count else {
            throw SQLiteError(
                code: SQLITE_MISUSE,
                message: "statement expects \(expected) parameters, \(parameters.count) supplied",
                sql: sql
            )
        }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let rc = bind(value, to: statement, at: index)
            guard rc == SQLITE_OK else { throw error(code: rc, sql: sql) }
        }

        var names: [String: Int32] = [:]
        let columnCount = sqlite3_column_count(statement)
        if columnCount > 0 {
            names.reserveCapacity(Int(columnCount))
            for index in 0..<columnCount {
                if let namePointer = sqlite3_column_name(statement, index) {
                    names[String(cString: namePointer)] = index
                }
            }
        }

        var results: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            switch rc {
            case SQLITE_ROW:
                results.append(try transform(SQLiteRow(statement: statement, names: names)))
                if let limit, results.count >= limit { return results }
            case SQLITE_DONE:
                return results
            default:
                throw error(code: rc, sql: sql)
            }
        }
    }

    private func bind(_ value: SQLiteValue, to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(statement, index)
        case .integer(let v):
            return sqlite3_bind_int64(statement, index, v)
        case .real(let v):
            return sqlite3_bind_double(statement, index, v)
        case .text(let v):
            // The byte count is explicit rather than -1. With -1 SQLite reads to
            // the first NUL, so a Swift string containing "\0" would be silently
            // truncated at the boundary. SQLITE_TRANSIENT makes SQLite copy the
            // bytes before the bridged buffer for `v` goes away.
            return sqlite3_bind_text(statement, index, v, Int32(v.utf8.count), SQLITE_TRANSIENT)
        case .blob(let v):
            if v.isEmpty {
                // `sqlite3_bind_blob` with a null pointer binds NULL, not an
                // empty blob, and an empty `Data` has no base address.
                return sqlite3_bind_zeroblob(statement, index, 0)
            }
            return v.withUnsafeBytes { buffer in
                sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
            }
        }
    }

    private func error(code: Int32, sql: String?) -> SQLiteError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
        return SQLiteError(code: code, message: message, sql: sql)
    }
}
