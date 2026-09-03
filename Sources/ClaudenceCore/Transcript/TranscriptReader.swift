import Foundation

/// Tails a Claude Code transcript, emitting only what was appended since the
/// previous call.
///
/// Transcripts reach 12 MB and beyond, so full re-parsing is forbidden. The
/// reader persists `(path, inode, byteOffset)` through `CursorStoring` and
/// resumes from the offset. A changed inode means the file rotated and resets
/// the offset to zero. When nothing has been appended the file is never opened
/// at all: a `stat` decides it.
///
/// Everything this type emits is constrained by `TranscriptDelta`, and
/// everything it decodes is constrained by `TranscriptRecord`. See spec
/// sections 2.3 and 3.1.
public struct TranscriptReader: TranscriptReading {

    public let sourceName = "Claude Code transcript"

    /// Bytes pulled from the file per read. Bounds peak memory on a first,
    /// cold read of a large transcript.
    static let defaultChunkSize = 1 << 20

    /// A single line longer than this is dropped and counted as skipped rather
    /// than buffered. Real records are kilobytes; this only guards against a
    /// corrupt file with no newlines.
    static let maxLineBytes = 32 * 1024 * 1024

    private let locator: TranscriptLocator
    private let cursorStore: any CursorStoring
    private let chunkSize: Int
    /// Only used to bucket `TranscriptDelta.usageByDay`. Injected so a test
    /// pins the day boundary the same way `ClaudenceStore` lets one pin its own.
    private let calendar: Calendar

    public init(
        cursorStore: any CursorStoring,
        locator: TranscriptLocator = TranscriptLocator(),
        calendar: Calendar = .current
    ) {
        self.init(
            cursorStore: cursorStore,
            locator: locator,
            chunkSize: TranscriptReader.defaultChunkSize,
            calendar: calendar
        )
    }

    init(cursorStore: any CursorStoring, locator: TranscriptLocator, chunkSize: Int, calendar: Calendar = .current) {
        self.cursorStore = cursorStore
        self.locator = locator
        self.chunkSize = max(4_096, chunkSize)
        self.calendar = calendar
    }

    // MARK: - TranscriptReading

    public func readIncremental(sessionID: String, workingDirectory: String) -> TranscriptDelta {
        let read = cursorStore.readCursor(forSession: sessionID)
        // A cursor that could not be read is not a cursor at zero. Starting at
        // zero here re-parses records the caller's accumulator already holds,
        // and the doubled figure is written straight back over the session row
        // and the daily rollup. Nothing is opened, nothing is parsed and no
        // cursor is saved; the caller skips the session and the next pass
        // retries.
        if case .unavailable = read { return .cursorUnavailable }
        let cursor = read.cursor

        guard let url = resolveURL(sessionID: sessionID, workingDirectory: workingDirectory, cursor: cursor),
              let status = FileStatus(path: url.path) else {
            // A missing or unreadable transcript is an ordinary state.
            return .empty
        }

        let resumable = cursor.map {
            $0.path == url.path && $0.inode == status.inode && $0.byteOffset <= status.size
        } ?? false
        // A changed inode is rotation; a shrunken file is truncation. Both
        // restart at zero.
        let start: UInt64 = resumable ? (cursor?.byteOffset ?? 0) : 0

        if start >= status.size {
            // Nothing appended. The file is never opened.
            persist(ReadCursor(path: url.path, inode: status.inode, byteOffset: start),
                    forSession: sessionID, existing: cursor)
            return .empty
        }

        let builder = DeltaBuilder(calendar: calendar)
        let consumed = scan(url: url, from: start, into: builder)

        persist(ReadCursor(path: url.path, inode: status.inode, byteOffset: consumed),
                forSession: sessionID, existing: cursor)
        return builder.delta
    }

    /// Reads an already-known transcript path incrementally.
    ///
    /// Subagent transcripts are located by directory listing rather than by
    /// session id, so they arrive as a path. `cursorKey` namespaces the stored
    /// offset; a subagent's key must not collide with its parent's session id.
    public func readIncremental(atPath path: String, cursorKey: String) -> TranscriptDelta {
        // Same rule as the overload above, and the same consequence: a
        // subagent's stored total is written back from its accumulator, so a
        // re-scan from zero doubles that row too.
        let read = cursorStore.readCursor(forSession: cursorKey)
        if case .unavailable = read { return .cursorUnavailable }
        let cursor = read.cursor
        guard let status = FileStatus(path: path) else { return .empty }

        let resumable = cursor.map {
            $0.path == path && $0.inode == status.inode && $0.byteOffset <= status.size
        } ?? false
        let start: UInt64 = resumable ? (cursor?.byteOffset ?? 0) : 0

        if start >= status.size {
            persist(ReadCursor(path: path, inode: status.inode, byteOffset: start),
                    forSession: cursorKey, existing: cursor)
            return .empty
        }

        let builder = DeltaBuilder(calendar: calendar)
        let consumed = scan(url: URL(fileURLWithPath: path), from: start, into: builder)

        persist(ReadCursor(path: path, inode: status.inode, byteOffset: consumed),
                forSession: cursorKey, existing: cursor)
        return builder.delta
    }

    // MARK: - Path resolution

    /// A cursor whose file still exists is trusted, which keeps the steady
    /// state free of directory scans. Otherwise the locator runs.
    private func resolveURL(sessionID: String, workingDirectory: String, cursor: ReadCursor?) -> URL? {
        if let cursor, !cursor.path.isEmpty, FileManager.default.fileExists(atPath: cursor.path) {
            return URL(fileURLWithPath: cursor.path)
        }
        return locator.locate(sessionID: sessionID, workingDirectory: workingDirectory)
    }

    private func persist(_ cursor: ReadCursor, forSession sessionID: String, existing: ReadCursor?) {
        guard existing != cursor else { return }
        cursorStore.saveCursor(cursor, forSession: sessionID)
    }

    // MARK: - Scanning

    /// Reads from `start` to end of file and returns the new offset, which is
    /// always just past the last complete line. A trailing line with no
    /// newline is a write in progress: it is not consumed and the offset stays
    /// before it, so the next call sees it whole.
    private func scan(url: URL, from start: UInt64, into builder: DeltaBuilder) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return start }
        defer { try? handle.close() }
        do { try handle.seek(toOffset: start) } catch { return start }

        let scanner = LineScanner(maxLineBytes: TranscriptReader.maxLineBytes)

        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: chunkSize) } catch { break }
            guard let chunk, !chunk.isEmpty else { break }
            scanner.feed(chunk) { line in
                self.ingest(line: line, into: builder)
            } onOverlongLine: {
                builder.skip()
            }
        }

        return start + scanner.consumedBytes
    }

    /// One complete line. Non-assistant lines stop at the type probe.
    private func ingest(line: Data, into builder: DeltaBuilder) {
        guard !line.isEmpty else { return }
        let decoder = JSONDecoder()

        guard let probe = try? decoder.decode(TranscriptLineType.self, from: line) else {
            builder.skip()
            return
        }
        guard probe.isAssistant else {
            // The one thing taken from a non-assistant line, and only until
            // there is one: a session with no assistant record at all still
            // knows where it ran. See `TranscriptLineType`.
            if let cwd = probe.cwd, !cwd.isEmpty {
                builder.noteWorkingDirectoryIfAbsent(cwd)
            }
            return
        }
        guard let record = try? decoder.decode(TranscriptRecord.self, from: line) else {
            builder.skip()
            return
        }
        builder.absorb(record)
    }
}

// MARK: - Delta assembly

/// Accumulates a delta. A reference type so it can be captured by the scanner's
/// callbacks without overlapping-access problems.
final class DeltaBuilder {
    private var usage: TokenUsage = .zero
    private var activity: Activity?
    private var model: String?
    private var timestamp: Date?
    private var earliestTimestamp: Date?
    private var parsed = 0
    private var skipped = 0
    private var toolCounts: [String: Int] = [:]
    private var filePaths: [String] = []
    private var trail: [TimedActivity] = []
    private var serviceTier: String?
    /// The newest record's own usage block, kept apart from the running sum.
    private var lastRequestUsage: TokenUsage?
    private var gitBranch: String?
    private var workingDirectory: String?
    private var usageByDay: [String: TokenUsage] = [:]
    private var usageByModel: [String: TokenUsage] = [:]

    private let calendar: Calendar
    /// The `[dayStart, dayEnd)` interval `cachedDay` is valid for. A record
    /// whose timestamp falls inside it reuses the string; one that does not is
    /// the only case that pays for `ClaudenceStore.dayString` again. Real
    /// transcripts hold long runs of records from the same local day, so this
    /// turns "one calendar computation per record" into "one per day actually
    /// crossed" on the hot re-scan path `PerformanceTests` times.
    private var cachedDayStart: Date?
    private var cachedDayEnd: Date?
    private var cachedDay: String?

    init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    /// Bounded so a long-running session cannot grow these without limit. The
    /// interface only ever shows a handful.
    private static let maxFilePaths = 12
    private static let maxTrail = 24

    /// `recordsParsed` counts assistant records only. A `user`, `system`, or
    /// `attachment` line is neither parsed nor skipped: it simply contributes
    /// nothing.
    /// Records a working directory seen on a line this builder otherwise
    /// ignores.
    ///
    /// `IfAbsent`, unlike the assignment in `absorb`, which is newest-wins. An
    /// assistant record's own `cwd` is the better answer whenever there is
    /// one, and it arrives later in the file than the first user line; taking
    /// this one only when nothing has been seen keeps the fallback a fallback.
    func noteWorkingDirectoryIfAbsent(_ cwd: String) {
        guard workingDirectory == nil else { return }
        workingDirectory = cwd
    }

    func absorb(_ record: TranscriptRecord) {
        parsed += 1

        let date = record.date
        if let usageBlock = record.message?.usage {
            let block = usageBlock.tokenUsage
            usage += block
            // Records arrive in file order, so the last one absorbed is the
            // newest. This overwrite is the point: the context window needs the
            // size of one request, never the sum of every request.
            lastRequestUsage = block
            // Attributed to this record's own timestamp, not the delta's
            // latest: an exact per-record split is what `HistoryImporter` needs
            // to file a session's spend on every day it actually touched.
            if let date {
                usageByDay[dayString(for: date), default: .zero] += block
            }
            // This record's own model, not `self.model`: `self.model` is
            // "newest wins" for the delta as a whole, but attribution needs
            // the model that actually produced *this* usage block. A record
            // with none is not dropped -- the tokens are real -- it is
            // counted under a bucket that says so.
            let recordModel = record.message?.model
            let modelKey = (recordModel?.isEmpty == false) ? recordModel! : ModelAttribution.unknown
            usageByModel[modelKey, default: .zero] += block
        }
        if let model = record.message?.model, !model.isEmpty {
            self.model = model
        }
        if let date {
            timestamp = date
            earliestTimestamp = earliestTimestamp.map { min($0, date) } ?? date
        }
        if let tier = record.message?.usage?.serviceTier, !tier.isEmpty {
            serviceTier = tier
        }
        // Newest wins, like the tier above: a session that switches branch
        // mid-run should read as being on the branch it is on now.
        if let branch = record.gitBranch, !branch.isEmpty {
            gitBranch = branch
        }
        if let cwd = record.cwd, !cwd.isEmpty {
            workingDirectory = cwd
        }
        // The activity of a delta is the LAST tool_use in the newly read
        // records, so later blocks overwrite earlier ones.
        for block in record.message?.content ?? [] {
            guard block.isToolUse else { continue }

            if let name = block.name, !name.isEmpty {
                toolCounts[name, default: 0] += 1
            }
            // Path only. The file is never opened.
            if let path = block.input?.filePath, !path.isEmpty {
                filePaths.removeAll { $0 == path }
                filePaths.append(path)
                if filePaths.count > DeltaBuilder.maxFilePaths {
                    filePaths.removeFirst(filePaths.count - DeltaBuilder.maxFilePaths)
                }
            }
            if let next = ActivityMapper.activity(for: block) {
                activity = next
                if let date = record.date {
                    trail.append(TimedActivity(at: date, activity: next))
                    if trail.count > DeltaBuilder.maxTrail {
                        trail.removeFirst(trail.count - DeltaBuilder.maxTrail)
                    }
                }
            }
        }
    }

    func skip() { skipped += 1 }

    /// `ClaudenceStore.dayString`, cached against `[cachedDayStart,
    /// cachedDayEnd)` so a run of records from the same local day costs one
    /// calendar computation, not one per record.
    private func dayString(for date: Date) -> String {
        if let start = cachedDayStart, let end = cachedDayEnd, let cached = cachedDay,
           date >= start, date < end {
            return cached
        }
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let day = ClaudenceStore.dayString(for: date, calendar: calendar)
        cachedDayStart = start
        cachedDayEnd = end
        cachedDay = day
        return day
    }

    var delta: TranscriptDelta {
        TranscriptDelta(
            usage: usage,
            latestActivity: activity,
            latestModel: model,
            latestTimestamp: timestamp,
            recordsParsed: parsed,
            recordsSkipped: skipped,
            toolCounts: toolCounts,
            filePaths: filePaths,
            activityTrail: trail,
            serviceTier: serviceTier,
            lastRequestUsage: lastRequestUsage,
            gitBranch: gitBranch,
            workingDirectory: workingDirectory,
            usageByDay: usageByDay,
            usageByModel: usageByModel,
            earliestTimestamp: earliestTimestamp
        )
    }
}

// MARK: - Line splitting

/// Splits a byte stream into newline-terminated lines across chunk boundaries.
///
/// `consumedBytes` counts only bytes belonging to complete lines, including
/// their terminating newline. Bytes of a trailing partial line are excluded, so
/// the caller's offset never advances past an unfinished write.
final class LineScanner {
    private let maxLineBytes: Int
    private var pending = Data()
    /// Length of the line currently being assembled, counting bytes that were
    /// dropped for overflow, so the offset stays exact.
    private var pendingBytes = 0
    private var overflowed = false

    private(set) var consumedBytes: UInt64 = 0

    init(maxLineBytes: Int) {
        self.maxLineBytes = maxLineBytes
    }

    func feed(_ chunk: Data, onLine: (Data) -> Void, onOverlongLine: () -> Void) {
        chunk.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                if let newline = memchr(base, 0x0A, remaining) {
                    let length = UnsafeRawPointer(newline) - base
                    append(base, count: length)
                    finishLine(onLine: onLine, onOverlongLine: onOverlongLine)
                    let step = length + 1
                    base = base.advanced(by: step)
                    remaining -= step
                } else {
                    append(base, count: remaining)
                    remaining = 0
                }
            }
        }
    }

    private func append(_ pointer: UnsafeRawPointer, count: Int) {
        guard count > 0 else { return }
        pendingBytes += count
        guard !overflowed else { return }
        if pending.count + count > maxLineBytes {
            overflowed = true
            pending = Data()
            return
        }
        pending.append(pointer.assumingMemoryBound(to: UInt8.self), count: count)
    }

    private func finishLine(onLine: (Data) -> Void, onOverlongLine: () -> Void) {
        if overflowed {
            onOverlongLine()
        } else {
            onLine(pending)
        }
        consumedBytes += UInt64(pendingBytes) + 1
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
        overflowed = false
    }
}

// MARK: - stat

/// Inode and size in one `stat`. The inode is the rotation signal.
struct FileStatus {
    let inode: UInt64
    let size: UInt64

    init?(path: String) {
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        inode = UInt64(info.st_ino)
        size = UInt64(max(0, info.st_size))
    }
}

// MARK: - Cursor storage

/// A durable cursor store with an in-memory one behind it, for the state where
/// the durable one has no database at all.
///
/// `StoreHealth.unavailable` means every call is a no-op: `saveCursor` writes
/// nothing and `readCursor` answers `.none`, which the reader reads as "start at
/// byte 0". The engine's accumulator is not reset by any of that, so every pass
/// re-read the whole transcript and added it to a total that already held it,
/// and the figure grew on every filesystem event. The state is rare, needing
/// even `:memory:` to fail to open, and the failure in it was unbounded.
///
/// Writes go to both, so the memory copy is warm if the durable store is lost
/// at a reopen. Reads come from memory only while the durable store is
/// unavailable, so the durable offsets stay the authority whenever there are
/// any.
public final class ResilientCursorStore: CursorStoring, @unchecked Sendable {
    private let durable: any CursorStoring
    private let memory = TranscriptMemoryCursorStore()

    public init(durable: any CursorStoring) {
        self.durable = durable
    }

    public var health: StoreHealth { durable.health }
    public var unansweredQueries: UInt64 { durable.unansweredQueries }
    public var unansweredQueriesOnThisThread: UInt64 { durable.unansweredQueriesOnThisThread }

    public func cursor(forSession sessionID: String) -> ReadCursor? {
        if case .unavailable = durable.health { return memory.cursor(forSession: sessionID) }
        return durable.cursor(forSession: sessionID)
    }

    public func saveCursor(_ cursor: ReadCursor, forSession sessionID: String) {
        memory.saveCursor(cursor, forSession: sessionID)
        durable.saveCursor(cursor, forSession: sessionID)
    }

    public func readCursor(forSession sessionID: String) -> CursorRead {
        if case .unavailable = durable.health {
            return memory.cursor(forSession: sessionID).map(CursorRead.at) ?? .none
        }
        return durable.readCursor(forSession: sessionID)
    }
}

/// In-memory cursor store. Sufficient for a single run and for tests; the
/// durable store owns its own schema and lives elsewhere.
public final class TranscriptMemoryCursorStore: CursorStoring, @unchecked Sendable {
    private var cursors: [String: ReadCursor] = [:]
    private let lock = NSLock()

    public init() {}

    /// Nothing here can fail, so the count never moves and every read this
    /// store performs is an answer.
    public var health: StoreHealth { .healthy }
    public var unansweredQueries: UInt64 { 0 }

    public func cursor(forSession sessionID: String) -> ReadCursor? {
        lock.lock()
        defer { lock.unlock() }
        return cursors[sessionID]
    }

    public func saveCursor(_ cursor: ReadCursor, forSession sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        cursors[sessionID] = cursor
    }
}
