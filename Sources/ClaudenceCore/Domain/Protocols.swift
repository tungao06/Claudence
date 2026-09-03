import Foundation

// MARK: - Adapter contract

/// Every external data source sits behind an adapter. Parsers never touch the
/// filesystem, a process, or the network directly. See spec section 4.
public protocol SourceAdapter: Sendable {
    /// Human-readable name used in diagnostics and degraded-state messages.
    var sourceName: String { get }
}

/// Discovers live agent sessions.
public protocol SessionDiscovering: SourceAdapter {
    /// Returns every currently live interactive session.
    /// Never throws for an absent or unreadable source: an unavailable source
    /// yields an empty array, because "no sessions" is an ordinary state.
    func discover() -> [AISession]
}

/// Streams token usage and activity for a known session.
public protocol TranscriptReading: SourceAdapter {
    /// Reads only records appended since the last call for this session.
    /// Implementations persist `(path, inode, byteOffset)` and resume from it.
    /// A changed inode means rotation and resets the offset to zero.
    func readIncremental(sessionID: String, workingDirectory: String) -> TranscriptDelta
}

/// Provides account usage windows.
public protocol UsageProviding: SourceAdapter, Sendable {
    /// - Parameter minimumInterval: how old a cached reading may be before the
    ///   network is asked again. An implementation that does not cache ignores
    ///   it. The engine passes the user's chosen refresh interval, so a shorter
    ///   choice is not swallowed by a provider's own fixed cache.
    func fetch(minimumInterval: TimeInterval) async -> UsageState
}

extension UsageProviding {
    public func fetch() async -> UsageState {
        await fetch(minimumInterval: Constants.Usage.cacheTTL)
    }
}

// MARK: - Transcript delta

/// Whether a read happened at all.
///
/// A delta that carries nothing because the file has not grown and a delta
/// that carries nothing because the reader never learned where to resume are
/// the same value otherwise, and the second must not be accumulated, written
/// back, or taken as "this session spent nothing".
public enum TranscriptReadOutcome: Sendable, Equatable {
    /// The transcript was read from a known offset. An empty delta means the
    /// file has nothing new in it.
    case read
    /// The stored cursor could not be read, so nothing was opened, parsed or
    /// persisted. The caller skips this session for the pass and retries.
    case cursorUnavailable
}

/// The only shape a transcript parser may emit. Anything outside these fields
/// is a privacy violation and is covered by tests. See spec section 3.1.
public struct TranscriptDelta: Sendable, Equatable {
    public var usage: TokenUsage
    public var latestActivity: Activity?
    public var latestModel: String?
    public var latestTimestamp: Date?
    public var recordsParsed: Int
    public var recordsSkipped: Int
    /// Tool-use counts by tool name, for this delta only. Names, never
    /// arguments. See spec section 3.1.
    public var toolCounts: [String: Int]
    /// Distinct `input.file_path` values seen in this delta, newest last.
    /// Paths only: the file is never opened and its contents are never read.
    public var filePaths: [String]
    /// Activities in the order they occurred, so a timeline can be built
    /// rather than only the newest state.
    public var activityTrail: [TimedActivity]
    /// `usage.service_tier` from the most recent record carrying one.
    public var serviceTier: String?
    /// The single most recent record's own `message.usage`, not the running sum.
    ///
    /// This is the only figure a context window can honestly be measured
    /// against. A context window sizes one request's input; the cumulative
    /// total counts every request the session ever made, and its `cache_read`
    /// alone runs to tens of millions on a long session, so dividing it by a
    /// limit yields percentages in the thousands. Keeping the newest block
    /// separately is what makes the difference between a meter and a fiction.
    public var lastRequestUsage: TokenUsage?
    /// `gitBranch` from the most recent record carrying one.
    ///
    /// Already on the allowlist and already decoded by `TranscriptRecord`; it
    /// was simply discarded here, so the session row rendered a path where the
    /// design shows `path · branch`. A branch name is a label the tool wrote,
    /// not content a person or a model produced.
    public var gitBranch: String?
    /// Whether this delta is a reading or a refusal to take one. See
    /// `TranscriptReadOutcome`.
    public var outcome: TranscriptReadOutcome

    public init(
        usage: TokenUsage = .zero,
        latestActivity: Activity? = nil,
        latestModel: String? = nil,
        latestTimestamp: Date? = nil,
        recordsParsed: Int = 0,
        recordsSkipped: Int = 0,
        toolCounts: [String: Int] = [:],
        filePaths: [String] = [],
        activityTrail: [TimedActivity] = [],
        serviceTier: String? = nil,
        lastRequestUsage: TokenUsage? = nil,
        gitBranch: String? = nil,
        outcome: TranscriptReadOutcome = .read
    ) {
        self.usage = usage
        self.latestActivity = latestActivity
        self.latestModel = latestModel
        self.latestTimestamp = latestTimestamp
        self.recordsParsed = recordsParsed
        self.recordsSkipped = recordsSkipped
        self.toolCounts = toolCounts
        self.filePaths = filePaths
        self.activityTrail = activityTrail
        self.serviceTier = serviceTier
        self.lastRequestUsage = lastRequestUsage
        self.gitBranch = gitBranch
        self.outcome = outcome
    }

    public static let empty = TranscriptDelta()

    /// Nothing was read because the reader could not find out where to resume.
    /// Distinct from `.empty`, which is a real reading of a file that has not
    /// grown.
    public static let cursorUnavailable = TranscriptDelta(outcome: .cursorUnavailable)
}

/// An activity with the moment it happened, for the session timeline.
public struct TimedActivity: Sendable, Equatable {
    public let at: Date
    public let activity: Activity

    public init(at: Date, activity: Activity) {
        self.at = at
        self.activity = activity
    }
}

// MARK: - Offset persistence

/// Where a transcript reader left off. Persisted so a restart does not
/// re-parse a 12 MB file or double-count tokens.
public struct ReadCursor: Sendable, Equatable, Codable {
    public var path: String
    public var inode: UInt64
    public var byteOffset: UInt64

    public init(path: String, inode: UInt64, byteOffset: UInt64) {
        self.path = path
        self.inode = inode
        self.byteOffset = byteOffset
    }
}

/// What the store said when asked where a reader left off.
///
/// `cursor(forSession:)` returns nil for a key that has never been read and
/// for a query that threw, and those two are opposites. The first means "start
/// at zero". The second means "where to resume is unknown", and taking it for
/// the first re-parses a file whose records have already been counted, adds the
/// whole thing to an accumulator already seeded with the stored total, and
/// writes the doubled figure back to the session row, the subagent row and the
/// daily rollup. A cursor and its total are only correct together, and that
/// holds in both directions: the undercount this project shipped once came
/// from a total lost against a live cursor, this is a cursor lost against a
/// live total.
public enum CursorRead: Sendable, Equatable {
    /// Nothing stored for this key. Reading starts at zero.
    case none
    /// Where the previous read stopped.
    case at(ReadCursor)
    /// The store did not answer. Nothing may be read, accumulated, or written
    /// for this key on this pass; the next pass tries again.
    case unavailable

    /// The offset to resume from, or nil when there is none.
    ///
    /// `unavailable` deliberately collapses to nil here, so this is reachable
    /// only after a caller has handled that case: it is a convenience for the
    /// two answering outcomes, not a way to ask the ambiguous question again.
    var cursor: ReadCursor? {
        if case .at(let cursor) = self { return cursor }
        return nil
    }
}

/// Persistence seam. The store implementation owns the SQLite schema.
///
/// It reports its own outcomes through `StoreOutcomeReporting` because the nil
/// above is ambiguous and only the store can say which nil it is.
public protocol CursorStoring: Sendable, StoreOutcomeReporting {
    func cursor(forSession sessionID: String) -> ReadCursor?
    func saveCursor(_ cursor: ReadCursor, forSession sessionID: String)
    /// `cursor(forSession:)` with its ambiguity resolved. A requirement rather
    /// than only an extension member so a store that composes another one can
    /// answer it differently; the default below is what every plain store uses.
    func readCursor(forSession sessionID: String) -> CursorRead
}

extension CursorStoring {
    /// `cursor(forSession:)` with its ambiguity resolved.
    ///
    /// The signal is the store's own count of queries that did not answer, the
    /// same one the engine, the analytics layer and the subagent tracker read.
    /// A health transition is the wrong question: health latches once it is
    /// degraded and has nowhere left to move.
    public func readCursor(forSession sessionID: String) -> CursorRead {
        // An unavailable store has no database behind it at all: it never
        // answers and never persists, and that is permanent for the life of
        // the process. There is no stored offset to strand and no stored total
        // to double, so it is treated as no store rather than as a read worth
        // retrying, which would otherwise freeze every session forever on a
        // machine whose only fault is that it cannot open a database file.
        if case .unavailable = health { return .none }
        let before = unansweredQueriesOnThisThread
        let stored = cursor(forSession: sessionID)
        guard unansweredQueriesOnThisThread == before else { return .unavailable }
        return stored.map(CursorRead.at) ?? .none
    }
}
