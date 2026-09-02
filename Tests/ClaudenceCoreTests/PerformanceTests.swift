import Foundation
import Testing
@testable import ClaudenceCore

// The idle budget in spec section 13 is a behaviour, not a hope: an event that
// changes nothing must cost nothing downstream. These tests pin the three
// places where that used to leak — a republished snapshot, a re-probed
// process, and a re-read transcript.

// MARK: - Fakes

private struct StaticDiscovery: SessionDiscovering {
    let sourceName = "static-discovery"
    let sessions: [AISession]
    func discover() -> [AISession] { sessions }
}

private struct SilentTranscripts: TranscriptReading {
    let sourceName = "silent-transcripts"
    func readIncremental(sessionID: String, workingDirectory: String) -> TranscriptDelta { .empty }
}

private struct FixedUsage: UsageProviding {
    let sourceName = "fixed-usage"
    let windows: [UsageWindow]
    /// A fresh `fetchedAt` on every call, exactly like the real client.
    func fetch() async -> UsageState { .available(windows: windows, fetchedAt: Date()) }
}

private final class PublishCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MonitorSnapshot] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return storage.count }
    var last: MonitorSnapshot? { lock.lock(); defer { lock.unlock() }; return storage.last }
    func record(_ snapshot: MonitorSnapshot) { lock.lock(); storage.append(snapshot); lock.unlock() }
}

private func session(
    id: String,
    status: SessionStatus = .running,
    lastActivityAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> AISession {
    AISession(
        id: id,
        pid: 1234,
        procStart: "Tue Sep  1 19:27:02 2026",
        projectName: "demo",
        workingDirectory: "/Users/someone/demo",
        status: status,
        startedAt: Date(timeIntervalSince1970: 1_699_000_000),
        lastActivityAt: lastActivityAt
    )
}

// MARK: - Snapshot suppression

@Test("repeated refreshes over unchanged sources publish exactly once")
func identicalRefreshesPublishOnce() async {
    let engine = MonitorEngine(
        discovery: StaticDiscovery(sessions: [session(id: "s1")]),
        transcripts: SilentTranscripts()
    )
    let counter = PublishCounter()
    await engine.observe { counter.record($0) }   // registration publish

    for _ in 0..<25 {
        await engine.refreshSessions()
    }

    // One for registration, one for the first real change, nothing after.
    #expect(counter.count == 2)
}

@Test("a snapshot differing only in updatedAt is not a change")
func updatedAtIsNotContent() {
    let sessions = [session(id: "s1")]
    let a = MonitorSnapshot(sessions: sessions, updatedAt: Date(timeIntervalSince1970: 10))
    let b = MonitorSnapshot(sessions: sessions, updatedAt: Date(timeIntervalSince1970: 9_999))
    #expect(a != b)                    // whole-value equality still sees the stamp
    #expect(a.hasSameContent(as: b))   // content equality does not
}

@Test("a usage reading differing only in fetchedAt is not a change")
func fetchedAtIsNotContent() {
    let windows = [UsageWindow(name: "five_hour", usedPercent: 41, resetsAt: nil)]
    let a = MonitorSnapshot(usage: .available(windows: windows, fetchedAt: Date(timeIntervalSince1970: 10)))
    let b = MonitorSnapshot(usage: .available(windows: windows, fetchedAt: Date(timeIntervalSince1970: 900)))
    #expect(a.hasSameContent(as: b))
}

@Test("a genuine change still publishes")
func realChangePublishes() async {
    let engine = MonitorEngine(
        discovery: StaticDiscovery(sessions: [session(id: "s1")]),
        transcripts: SilentTranscripts()
    )
    let counter = PublishCounter()
    await engine.observe { counter.record($0) }
    await engine.refreshSessions()
    #expect(counter.count == 2)

    let moved = MonitorEngine(
        discovery: StaticDiscovery(sessions: [session(id: "s1", status: .idle)]),
        transcripts: SilentTranscripts()
    )
    let second = PublishCounter()
    await moved.observe { second.record($0) }
    await moved.refreshSessions()
    #expect(second.last?.sessions.first?.status == .idle)
}

@Test("a repeated usage fetch with the same windows does not republish")
func repeatedUsageFetchDoesNotPublish() async {
    let windows = [UsageWindow(name: "five_hour", usedPercent: 41, resetsAt: nil)]
    let engine = MonitorEngine(
        discovery: StaticDiscovery(sessions: []),
        transcripts: SilentTranscripts(),
        usageProvider: FixedUsage(windows: windows)
    )
    let counter = PublishCounter()
    await engine.observe { counter.record($0) }

    await engine.refreshUsage(force: true)
    #expect(counter.count == 2)

    // Same numbers, new `fetchedAt` each time. None of these are news.
    for _ in 0..<10 {
        await engine.refreshUsage(force: true)
    }
    #expect(counter.count == 2)
    #expect(await engine.current().primaryWindow?.usedPercent == 41)
}

@Test("an idle refresh does not grow the burn-rate ring")
func idleRefreshDoesNotSample() async {
    let engine = MonitorEngine(
        discovery: StaticDiscovery(sessions: [session(id: "s1")]),
        transcripts: SilentTranscripts()
    )
    for _ in 0..<50 {
        await engine.refreshSessions()
    }
    // Fifty events, zero new tokens: a rate would be an invention.
    let rate = await engine.burnRate(forSession: "s1")
    #expect(rate.tokensPerMinute == 0)
    #expect(rate.samples.isEmpty)
}

// MARK: - Liveness cache

@Test("liveness is probed once per process inside the TTL")
func livenessCacheCollapsesABurst() {
    let probes = Counter()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
    let cache = LivenessCache(now: { clock.value }) { _, _ in
        probes.increment()
        return true
    }

    for _ in 0..<20 {
        #expect(cache.isAlive(pid: 42, procStart: "Tue Sep  1 19:27:02 2026"))
    }
    #expect(probes.value == 1)
}

@Test("an exit is noticed within the liveness TTL")
func livenessCacheExpires() {
    let probes = Counter()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
    let alive = Flag(true)
    let cache = LivenessCache(now: { clock.value }) { _, _ in
        probes.increment()
        return alive.value
    }

    #expect(cache.isAlive(pid: 42, procStart: "start"))
    alive.value = false

    // Still cached just before the TTL.
    clock.value = clock.value.addingTimeInterval(LivenessCache.livenessTTL - 0.01)
    #expect(cache.isAlive(pid: 42, procStart: "start"))

    // Re-probed the moment it expires, and the TTL is at most a second so an
    // exited process can never be shown as live for longer than that.
    clock.value = clock.value.addingTimeInterval(0.02)
    #expect(cache.isAlive(pid: 42, procStart: "start") == false)
    #expect(probes.value == 2)
    #expect(LivenessCache.livenessTTL <= 2)
}

@Test("a recycled pid with a different procStart is not a cache hit")
func livenessCacheKeyedOnProcStart() {
    let probes = Counter()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
    let cache = LivenessCache(now: { clock.value }) { _, procStart in
        probes.increment()
        return procStart == "old"
    }

    #expect(cache.isAlive(pid: 42, procStart: "old"))
    #expect(cache.isAlive(pid: 42, procStart: "new") == false)
    #expect(probes.value == 2)
}

// MARK: - Transcript at end of file

@Test("a read at end of file writes no cursor and returns nothing")
func transcriptReadAtEndOfFileIsANoOp() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudence-perf-\(UUID().uuidString)", isDirectory: true)
    let projects = directory.appendingPathComponent("projects", isDirectory: true)
    let work = "/tmp/claudence-perf-project"
    let slug = TranscriptLocator.slug(forWorkingDirectory: work)
    let project = projects.appendingPathComponent(slug, isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sessionID = "11111111-2222-3333-4444-555555555555"
    let line = """
    {"type":"assistant","sessionId":"\(sessionID)","timestamp":"2026-09-01T12:00:00.000Z",\
    "message":{"model":"claude-x","usage":{"input_tokens":10,"output_tokens":5},"content":[]}}
    """
    try (line + "\n").write(to: project.appendingPathComponent(sessionID + ".jsonl"),
                            atomically: true, encoding: .utf8)

    let store = CountingCursorStore()
    let reader = TranscriptReader(
        cursorStore: store,
        locator: TranscriptLocator(projectsDirectory: projects)
    )

    // Cold read: the file is opened, the record is parsed, the cursor advances.
    let first = reader.readIncremental(sessionID: sessionID, workingDirectory: work)
    #expect(first.recordsParsed == 1)
    #expect(store.saves == 1)

    // The file has not grown. `TranscriptReader` decides that from `stat`
    // alone: `start >= status.size` returns before `scan` ever opens a handle,
    // and the unchanged cursor is not written back either.
    for _ in 0..<20 {
        let repeated = reader.readIncremental(sessionID: sessionID, workingDirectory: work)
        #expect(repeated == .empty)
        #expect(repeated.recordsParsed == 0)
        #expect(repeated.recordsSkipped == 0)
    }
    #expect(store.saves == 1)
}

// MARK: - Test support

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool
    init(_ value: Bool) { storage = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date
    init(_ value: Date) { storage = value }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private final class CountingCursorStore: CursorStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [String: ReadCursor] = [:]
    private var writes = 0

    var saves: Int { lock.lock(); defer { lock.unlock() }; return writes }

    func cursor(forSession sessionID: String) -> ReadCursor? {
        lock.lock(); defer { lock.unlock() }
        return cursors[sessionID]
    }

    func saveCursor(_ cursor: ReadCursor, forSession sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        cursors[sessionID] = cursor
        writes += 1
    }
}
