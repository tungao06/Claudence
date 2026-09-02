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

    public init(
        cursorStore: any CursorStoring,
        locator: TranscriptLocator = TranscriptLocator()
    ) {
        self.init(cursorStore: cursorStore, locator: locator, chunkSize: TranscriptReader.defaultChunkSize)
    }

    init(cursorStore: any CursorStoring, locator: TranscriptLocator, chunkSize: Int) {
        self.cursorStore = cursorStore
        self.locator = locator
        self.chunkSize = max(4_096, chunkSize)
    }

    // MARK: - TranscriptReading

    public func readIncremental(sessionID: String, workingDirectory: String) -> TranscriptDelta {
        let cursor = cursorStore.cursor(forSession: sessionID)

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

        let builder = DeltaBuilder()
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
        let cursor = cursorStore.cursor(forSession: cursorKey)
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

        let builder = DeltaBuilder()
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
        guard probe.isAssistant else { return }
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
    private var parsed = 0
    private var skipped = 0

    /// `recordsParsed` counts assistant records only. A `user`, `system`, or
    /// `attachment` line is neither parsed nor skipped: it simply contributes
    /// nothing.
    func absorb(_ record: TranscriptRecord) {
        parsed += 1

        if let usageBlock = record.message?.usage {
            usage += usageBlock.tokenUsage
        }
        if let model = record.message?.model, !model.isEmpty {
            self.model = model
        }
        if let date = record.date {
            timestamp = date
        }
        // The activity of a delta is the LAST tool_use in the newly read
        // records, so later blocks overwrite earlier ones.
        for block in record.message?.content ?? [] {
            if let next = ActivityMapper.activity(for: block) {
                activity = next
            }
        }
    }

    func skip() { skipped += 1 }

    var delta: TranscriptDelta {
        TranscriptDelta(
            usage: usage,
            latestActivity: activity,
            latestModel: model,
            latestTimestamp: timestamp,
            recordsParsed: parsed,
            recordsSkipped: skipped
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

/// In-memory cursor store. Sufficient for a single run and for tests; the
/// durable store owns its own schema and lives elsewhere.
public final class TranscriptMemoryCursorStore: CursorStoring, @unchecked Sendable {
    private var cursors: [String: ReadCursor] = [:]
    private let lock = NSLock()

    public init() {}

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
