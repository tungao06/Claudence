import Darwin
import Foundation

/// Discovers live Claude Code sessions from `~/.claude/sessions/<pid>.json`.
///
/// `discover()` never throws and never traps. A missing directory, an
/// unreadable file, a permission denial and a corrupt JSON body all reduce to
/// "this file produced no session". Zero sessions is an ordinary state, not an
/// error. See spec section 2.1.
public struct SessionRegistryAdapter: SessionDiscovering {

    public let sourceName = "Session registry"

    /// Directory scanned for `<pid>.json` files. Injectable so tests never
    /// touch the user's real `~/.claude`.
    public let directory: URL

    private let livenessCheck: @Sendable (RegistryRecord) -> Bool
    private let clock: @Sendable () -> Date
    private let diagnostics: Diagnostics

    public init(
        directory: URL = Constants.sessionsDirectory,
        livenessCheck: (@Sendable (RegistryRecord) -> Bool)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.clock = clock
        self.diagnostics = Diagnostics()
        if let livenessCheck {
            self.livenessCheck = livenessCheck
        } else {
            // The default check is cached, because `kill` plus `sysctl` plus a
            // `DateFormatter` parse per record per filesystem event is pure
            // repetition: a burst of registry writes asks the same question of
            // the same processes several times inside a quarter of a second.
            let cache = LivenessCache()
            self.livenessCheck = { record in
                cache.isAlive(pid: record.pid, procStart: record.procStart)
            }
        }
    }

    // MARK: - Discovery

    public func discover() -> [AISession] {
        EngineCounters.shared.countDiscovery()
        let records = loadRecords()
        let now = clock()
        return records
            .filter(\.isInteractive)
            .filter(livenessCheck)
            .map { session(from: $0, now: now) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Every decodable record in the directory, live or not, unfiltered.
    /// Exposed for diagnostics and for the status-value survey.
    public func loadRecords() -> [RegistryRecord] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return [] }

        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: directory.path)
        } catch {
            // Permission denied, or the directory vanished mid-scan.
            return []
        }

        let decoder = JSONDecoder()
        var records: [RegistryRecord] = []
        records.reserveCapacity(names.count)

        for name in names where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                diagnostics.recordUnreadable()
                continue
            }
            guard let record = try? decoder.decode(RegistryRecord.self, from: data) else {
                // Malformed or truncated mid-write. Skipped silently, counted
                // so the rate is observable rather than invisible.
                diagnostics.recordMalformed()
                continue
            }
            records.append(record)
        }
        return records
    }

    private func session(from record: RegistryRecord, now: Date) -> AISession {
        AISession(
            id: record.sessionId,
            provider: .claudeCode,
            pid: record.pid,
            procStart: record.procStart,
            projectName: record.displayName,
            workingDirectory: record.cwd,
            status: Self.mapStatus(
                record.status,
                lastActivityAt: record.lastActivityDate,
                now: now
            ),
            currentActivity: nil,
            startedAt: record.startedAtDate,
            lastActivityAt: record.lastActivityDate,
            usage: .zero,
            model: nil,
            claudeCodeVersion: record.version
        )
    }

    // MARK: - Diagnostics

    /// Files whose JSON body could not be decoded since this adapter was made.
    public var malformedFileCount: Int { diagnostics.malformedCount }
    /// Files that existed but could not be read (permissions, races).
    public var unreadableFileCount: Int { diagnostics.unreadableCount }
    /// Live processes whose `procStart` string could not be parsed. A non-zero
    /// value means Claude Code changed the timestamp format and liveness has
    /// gone conservative: sessions are being hidden, not resurrected.
    public static var unparsedProcStartCount: Int { shared.unparsedProcStartCount }

    // MARK: - Status mapping

    /// Every distinct raw `status` string this process has seen, in first-seen
    /// order. Spec section 6 says the real enumeration must be discovered by
    /// observation during M1; this is that instrument. Observed so far:
    /// `busy`, `idle`.
    public static var observedStatusValues: Set<String> { shared.observedStatuses }

    /// Same values in the order they were first seen. Handy for a debug pane.
    public static var observedStatusValuesInOrder: [String] { shared.observedStatusOrder }

    /// Clears the survey. Tests only.
    public static func resetObservedStatusValues() { shared.resetObservedStatuses() }

    /// Maps the registry's raw status string onto the derivable states.
    ///
    /// Only `running`, `idle` and `completed` have a proven source today, so
    /// nothing else can be produced here (`SessionStatus.isDerivable`).
    /// `completed` is normally expressed by the file's absence rather than by a
    /// status string, but the terminal spellings are mapped defensively.
    ///
    /// Unknown values fall back on `updatedAt` age against
    /// `Constants.Watch.idleThreshold`: a registry entry touched recently means
    /// the session is doing something, a stale one means it is not.
    @discardableResult
    public static func mapStatus(
        _ raw: String?,
        lastActivityAt: Date,
        now: Date = Date()
    ) -> SessionStatus {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let normalized, !normalized.isEmpty {
            shared.observe(status: normalized)
        }

        let isRecent = now.timeIntervalSince(lastActivityAt) < Constants.Watch.idleThreshold

        switch normalized {
        case "busy", "running", "working", "active", "thinking":
            // Deliberately NOT age-gated. Measured on Claude Code 2.1.257:
            // `updatedAt` only moves on a status transition, so a session that
            // stays busy for minutes carries an `updatedAt` many minutes old.
            // Gating this on `idleThreshold` reported a session as idle while
            // it was actively running a tool. The stale-`busy` case that gating
            // was meant to catch (a crashed session leaving the file behind) is
            // already handled upstream by the liveness filter, which drops the
            // record entirely once the process is gone.
            return .running
        case "idle", "ready", "waiting_for_input":
            return .idle
        case "completed", "complete", "done", "finished", "exited", "closed":
            return .completed
        case nil, "":
            return isRecent ? .running : .idle
        default:
            // Unknown value. Recorded above, routed by recency here.
            return isRecent ? .running : .idle
        }
    }

    // MARK: - Liveness

    /// A registry entry is live only when **both** hold:
    ///
    /// 1. `kill(pid, 0)` says the process exists. `EPERM` counts as alive (the
    ///    process is there, we merely may not signal it); `ESRCH` is dead.
    /// 2. The live process's real start time, read from `sysctl` with
    ///    `KERN_PROC_PID` (`kp_proc.p_starttime`), matches the record's
    ///    `procStart` string.
    ///
    /// Step 2 is the load-bearing half. PIDs are recycled after a reboot, so
    /// `kill` alone would resurrect a dead session under a stranger's process.
    ///
    /// Comparison is done on `Date` values, not on strings, with a tolerance of
    /// `procStartTolerance`. `procStart` is second-resolution while
    /// `p_starttime` is a microsecond `timeval`, so an exact match is not
    /// available. `procStart` was verified to be C-locale `ctime` layout in
    /// **UTC** (`"Tue Sep  1 19:27:02 2026"`), but a local-time reading is also
    /// accepted so a formatting change in Claude Code degrades to a slightly
    /// weaker check instead of hiding every session.
    ///
    /// An unparseable `procStart` is treated as **dead**: hiding a live session
    /// is recoverable, showing a stranger's process as a session is not. The
    /// case is counted in `unparsedProcStartCount` so it is discoverable.
    public static func isAlive(pid: Int32, procStart: String) -> Bool {
        guard pid > 0 else { return false }
        guard processExists(pid: pid) else { return false }
        guard let actual = processStartTime(pid: pid) else { return false }
        guard let claimed = parseProcStart(procStart) else {
            shared.recordUnparsedProcStart()
            return false
        }
        return abs(actual.timeIntervalSince(claimed)) <= procStartTolerance
    }

    /// `procStart` truncates to whole seconds; `p_starttime` does not.
    public static let procStartTolerance: TimeInterval = 2

    /// `kill(pid, 0)`. `EPERM` means the process exists under another user.
    public static func processExists(pid: Int32) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Real start time of a live process, via `sysctl` `KERN_PROC_PID`.
    /// `nil` when the process is gone or the call is refused.
    public static func processStartTime(pid: Int32) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        // A zeroed entry means the pid was not found.
        guard info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        guard tv.tv_sec > 0 else { return nil }
        return Date(
            timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        )
    }

    /// Parses a registry `procStart` string. UTC first (the verified reading),
    /// then the local zone as a fallback.
    public static func parseProcStart(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in procStartFormatters {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// Renders a `Date` the way Claude Code writes `procStart`: C-locale
    /// `ctime` layout in UTC, day-of-month space-padded to two columns.
    public static func formatProcStart(_ date: Date) -> String {
        let raw = procStartFormatters[0].string(from: date)
        // "Tue Sep 1 19:27:02 2026" -> "Tue Sep  1 19:27:02 2026"
        var parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 5, parts[2].count == 1 else { return raw }
        parts[2] = " " + parts[2]
        return parts.joined(separator: " ")
    }

    private static let procStartFormatters: [DateFormatter] = {
        let layout = "EEE MMM d HH:mm:ss yyyy"
        return [TimeZone(identifier: "UTC")!, TimeZone.current].map { zone in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            f.timeZone = zone
            f.dateFormat = layout
            f.isLenient = false
            return f
        }
    }()

    // MARK: - Shared mutable state

    private static let shared = Diagnostics()
}

// MARK: - Diagnostics box

/// The adapter is a `Sendable` value type, so its counters live in a
/// lock-guarded reference box rather than in `var` storage.
private final class Diagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var malformed = 0
    private var unreadable = 0
    private var unparsedProcStart = 0
    private var statuses: Set<String> = []
    private var statusOrder: [String] = []

    func recordMalformed() {
        lock.lock(); defer { lock.unlock() }
        malformed += 1
    }

    func recordUnreadable() {
        lock.lock(); defer { lock.unlock() }
        unreadable += 1
    }

    func recordUnparsedProcStart() {
        lock.lock(); defer { lock.unlock() }
        unparsedProcStart += 1
    }

    func observe(status: String) {
        lock.lock(); defer { lock.unlock() }
        if statuses.insert(status).inserted {
            statusOrder.append(status)
        }
    }

    func resetObservedStatuses() {
        lock.lock(); defer { lock.unlock() }
        statuses.removeAll()
        statusOrder.removeAll()
    }

    var malformedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return malformed
    }

    var unreadableCount: Int {
        lock.lock(); defer { lock.unlock() }
        return unreadable
    }

    var unparsedProcStartCount: Int {
        lock.lock(); defer { lock.unlock() }
        return unparsedProcStart
    }

    var observedStatuses: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return statuses
    }

    var observedStatusOrder: [String] {
        lock.lock(); defer { lock.unlock() }
        return statusOrder
    }
}

// MARK: - Liveness cache

/// Memoizes `isAlive` for a short window.
///
/// A process that answered `kill(pid, 0)` with a matching `procStart` a moment
/// ago is still the same process: pids are not recycled inside the TTL while
/// the original holder is running, and `procStart` is re-checked the moment the
/// entry expires. The TTL is `livenessTTL` — long enough to collapse an FSEvents
/// burst (the watcher's debounce is 250 ms, so a burst asks at most a couple of
/// times) into one syscall pair, short enough that an exit is noticed within a
/// second. Exit is normally detected sooner than that anyway: Claude Code
/// removes the registry file on exit, and a record that is not on disk is never
/// asked about.
///
/// The cache key includes `procStart`, so a recycled pid whose start time
/// differs is a cache miss rather than a stale "alive".
final class LivenessCache: @unchecked Sendable {

    /// Justified above. One second is four times the watcher's 250 ms debounce,
    /// so a burst collapses to a single probe, and it is the whole staleness
    /// bound: an exited process can never be reported live for longer.
    static let livenessTTL: TimeInterval = 1.0

    private struct Key: Hashable {
        let pid: Int32
        let procStart: String
    }

    private let lock = NSLock()
    private var entries: [Key: (alive: Bool, at: Date)] = [:]
    private let now: @Sendable () -> Date
    private let probe: @Sendable (Int32, String) -> Bool

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        probe: @escaping @Sendable (Int32, String) -> Bool = { pid, procStart in
            SessionRegistryAdapter.isAlive(pid: pid, procStart: procStart)
        }
    ) {
        self.now = now
        self.probe = probe
    }

    func isAlive(pid: Int32, procStart: String) -> Bool {
        let key = Key(pid: pid, procStart: procStart)
        let instant = now()

        lock.lock()
        if let entry = entries[key],
           instant.timeIntervalSince(entry.at) < LivenessCache.livenessTTL {
            lock.unlock()
            EngineCounters.shared.countLivenessCacheHit()
            return entry.alive
        }
        lock.unlock()

        EngineCounters.shared.countLivenessCheck()
        let alive = probe(pid, procStart)

        lock.lock()
        entries[key] = (alive, instant)
        // The registry holds a handful of records; anything older than the TTL
        // is dead weight and is dropped rather than accumulated.
        entries = entries.filter { instant.timeIntervalSince($0.value.at) < LivenessCache.livenessTTL }
        lock.unlock()
        return alive
    }
}
