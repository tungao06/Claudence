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
    func fetch() async -> UsageState
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

    public init(
        usage: TokenUsage = .zero,
        latestActivity: Activity? = nil,
        latestModel: String? = nil,
        latestTimestamp: Date? = nil,
        recordsParsed: Int = 0,
        recordsSkipped: Int = 0
    ) {
        self.usage = usage
        self.latestActivity = latestActivity
        self.latestModel = latestModel
        self.latestTimestamp = latestTimestamp
        self.recordsParsed = recordsParsed
        self.recordsSkipped = recordsSkipped
    }

    public static let empty = TranscriptDelta()
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
