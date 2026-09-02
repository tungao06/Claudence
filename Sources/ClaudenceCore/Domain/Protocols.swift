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
        gitBranch: String? = nil
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
    }

    public static let empty = TranscriptDelta()
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

/// Persistence seam. The store implementation owns the SQLite schema.
public protocol CursorStoring: Sendable {
    func cursor(forSession sessionID: String) -> ReadCursor?
    func saveCursor(_ cursor: ReadCursor, forSession sessionID: String)
}
