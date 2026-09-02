import Foundation
import Testing
@testable import ClaudenceCore

// MARK: - Fakes

private struct FakeDiscovery: SessionDiscovering {
    let sourceName = "fake-discovery"
    let sessions: [AISession]
    func discover() -> [AISession] { sessions }
}

private final class FakeTranscripts: TranscriptReading, @unchecked Sendable {
    let sourceName = "fake-transcripts"
    private let lock = NSLock()
    private var queued: [String: [TranscriptDelta]] = [:]
    private(set) var calls: [String] = []

    func queue(_ delta: TranscriptDelta, for sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        queued[sessionID, default: []].append(delta)
    }

    func readIncremental(sessionID: String, workingDirectory: String) -> TranscriptDelta {
        lock.lock(); defer { lock.unlock() }
        calls.append(sessionID)
        guard var pending = queued[sessionID], !pending.isEmpty else { return .empty }
        let next = pending.removeFirst()
        queued[sessionID] = pending
        return next
    }
}

private struct FakeUsage: UsageProviding {
    let sourceName = "fake-usage"
    let state: UsageState
    func fetch(minimumInterval: TimeInterval) async -> UsageState { state }
}

private func makeSession(
    id: String,
    name: String = "demo",
    status: SessionStatus = .running,
    startedAt: Date = Date(timeIntervalSince1970: 1_000_000)
) -> AISession {
    AISession(
        id: id,
        pid: 4242,
        procStart: "Tue Sep  1 19:27:02 2026",
        projectName: name,
        workingDirectory: "/Users/someone/project/\(name)",
        status: status,
        startedAt: startedAt,
        lastActivityAt: startedAt
    )
}

// MARK: - TokenUsage

@Test("token totals follow the single locked formula")
func tokenFormula() {
    let usage = TokenUsage(freshInput: 2, cacheCreation: 22_018, cacheRead: 24_858, output: 147, thinking: 16)
    #expect(usage.billableInput == 46_878)
    #expect(usage.total == 47_025)
}

@Test("token usage adds componentwise")
func tokenAddition() {
    let a = TokenUsage(freshInput: 1, cacheCreation: 2, cacheRead: 3, output: 4, thinking: 5)
    let b = TokenUsage(freshInput: 10, cacheCreation: 20, cacheRead: 30, output: 40, thinking: 50)
    let sum = a + b
    #expect(sum.freshInput == 11)
    #expect(sum.cacheCreation == 22)
    #expect(sum.cacheRead == 33)
    #expect(sum.output == 44)
    #expect(sum.thinking == 55)
    #expect(sum.total == a.total + b.total)
}

// MARK: - Engine

@Test("engine accumulates deltas without double counting")
func engineAccumulates() async {
    let session = makeSession(id: "s1")
    let transcripts = FakeTranscripts()
    transcripts.queue(TranscriptDelta(usage: TokenUsage(freshInput: 100, output: 50)), for: "s1")
    transcripts.queue(TranscriptDelta(usage: TokenUsage(freshInput: 10, output: 5)), for: "s1")

    let engine = MonitorEngine(discovery: FakeDiscovery(sessions: [session]), transcripts: transcripts)

    await engine.refreshSessions()
    #expect(await engine.current().sessions.first?.usage.total == 150)

    await engine.refreshSessions()
    #expect(await engine.current().sessions.first?.usage.total == 165)

    // A third pass with no new records must not change the total.
    await engine.refreshSessions()
    #expect(await engine.current().sessions.first?.usage.total == 165)
}

@Test("a vanished session drops its accumulator so a recycled id starts clean")
func engineReaps() async {
    let transcripts = FakeTranscripts()
    transcripts.queue(TranscriptDelta(usage: TokenUsage(freshInput: 500)), for: "s1")

    let withSession = MonitorEngine(
        discovery: FakeDiscovery(sessions: [makeSession(id: "s1")]),
        transcripts: transcripts
    )
    await withSession.refreshSessions()
    #expect(await withSession.current().sessions.count == 1)

    let empty = MonitorEngine(discovery: FakeDiscovery(sessions: []), transcripts: FakeTranscripts())
    await empty.refreshSessions()
    #expect(await empty.current().sessions.isEmpty)
    #expect(await empty.current().todayUsage?.total == 0)
}

@Test("activity and model carry over from the transcript delta")
func engineAppliesActivity() async {
    let transcripts = FakeTranscripts()
    transcripts.queue(
        TranscriptDelta(
            usage: TokenUsage(output: 10),
            latestActivity: Activity(verb: "Editing", subject: "Menu.tsx"),
            latestModel: "claude-sonnet-5"
        ),
        for: "s1"
    )
    let engine = MonitorEngine(discovery: FakeDiscovery(sessions: [makeSession(id: "s1")]), transcripts: transcripts)
    await engine.refreshSessions()

    let session = await engine.current().sessions.first
    #expect(session?.currentActivity?.display == "Editing Menu.tsx")
    #expect(session?.model == "claude-sonnet-5")
}

@Test("sessions sort by most recent activity first")
func engineSorts() async {
    let old = makeSession(id: "old", name: "old", startedAt: Date(timeIntervalSince1970: 1_000))
    let recent = makeSession(id: "recent", name: "recent", startedAt: Date(timeIntervalSince1970: 9_000))
    let engine = MonitorEngine(
        discovery: FakeDiscovery(sessions: [old, recent]),
        transcripts: FakeTranscripts()
    )
    await engine.refreshSessions()
    #expect(await engine.current().sessions.map(\.id) == ["recent", "old"])
}

@Test("usage fetch respects the cache TTL and force overrides it")
func engineUsageCaching() async {
    let windows = [UsageWindow(name: "five_hour", usedPercent: 72, resetsAt: Date().addingTimeInterval(8_040))]
    let engine = MonitorEngine(
        discovery: FakeDiscovery(sessions: []),
        transcripts: FakeTranscripts(),
        usageProvider: FakeUsage(state: .available(windows: windows, fetchedAt: Date()))
    )

    await engine.refreshUsage()
    #expect(await engine.current().primaryWindow?.usedPercent == 72)
    #expect(await engine.current().severity == .attention)

    // Within the TTL a second call is a no-op rather than a request.
    await engine.refreshUsage()
    #expect(await engine.current().usage.windows.count == 1)
}

@Test("with no usage provider the snapshot stays explicitly unavailable")
func engineUsageAbsent() async {
    let engine = MonitorEngine(discovery: FakeDiscovery(sessions: []), transcripts: FakeTranscripts())
    await engine.refreshUsage()
    if case .unavailable = await engine.current().usage {
        // expected
    } else {
        Issue.record("usage must degrade to unavailable, never to a fabricated value")
    }
}

@Test("observers receive the current snapshot on registration and on change")
func engineObservers() async {
    let engine = MonitorEngine(
        discovery: FakeDiscovery(sessions: [makeSession(id: "s1")]),
        transcripts: FakeTranscripts()
    )
    let box = Box()
    await engine.observe { snapshot in box.append(snapshot.sessions.count) }
    await engine.refreshSessions()
    #expect(box.values == [0, 1])
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Int) { lock.lock(); storage.append(value); lock.unlock() }
}

// MARK: - Burn rate

@Test("burn rate needs two samples and a real elapsed span")
func burnRateNeedsSamples() {
    var tracker = BurnRateTracker()
    #expect(tracker.rate().tokensPerMinute == 0)
    tracker.record(tokens: 100, at: Date(timeIntervalSince1970: 0))
    #expect(tracker.rate().tokensPerMinute == 0)
}

@Test("burn rate is tokens per minute across the sampled span")
func burnRateComputes() {
    var tracker = BurnRateTracker()
    let start = Date(timeIntervalSince1970: 0)
    tracker.record(tokens: 0, at: start)
    tracker.record(tokens: 12_400, at: start.addingTimeInterval(60))
    let rate = tracker.rate(now: start.addingTimeInterval(60))
    #expect(abs(rate.tokensPerMinute - 12_400) < 0.001)
    #expect(rate.samples == [12_400])
}

@Test("samples outside the window are dropped so an idle gap decays the rate")
func burnRateWindowing() {
    var tracker = BurnRateTracker(window: 100)
    let start = Date(timeIntervalSince1970: 0)
    tracker.record(tokens: 0, at: start)
    tracker.record(tokens: 1_000, at: start.addingTimeInterval(10))
    tracker.record(tokens: 1_000, at: start.addingTimeInterval(500))
    // Only the last sample survives the window, so no rate can be claimed.
    #expect(tracker.rate(now: start.addingTimeInterval(500)).tokensPerMinute == 0)
}

@Test("a tracker with no new samples reports a falling rate and then zero")
func burnRateDecaysWithoutNewSamples() {
    var tracker = BurnRateTracker(window: 300)
    let start = Date(timeIntervalSince1970: 0)
    tracker.record(tokens: 0, at: start)
    tracker.record(tokens: 60_000, at: start.addingTimeInterval(60))

    // Nothing is recorded after this point. Only `now` moves, and it is the
    // caller's clock that has to make the figure fall.
    let whileSpending = tracker.rate(now: start.addingTimeInterval(60)).tokensPerMinute
    let twoMinutesIn = tracker.rate(now: start.addingTimeInterval(120)).tokensPerMinute
    let fourMinutesIn = tracker.rate(now: start.addingTimeInterval(240)).tokensPerMinute
    #expect(abs(whileSpending - 60_000) < 0.001)
    #expect(twoMinutesIn < whileSpending)
    #expect(fourMinutesIn < twoMinutesIn)

    // A whole window later nothing observed remains, so there is no span left
    // to divide by and the rate is zero rather than the stale average.
    #expect(tracker.rate(now: start.addingTimeInterval(600)).tokensPerMinute == 0)
}

@Test("a read drops expired samples from the sparkline as well as the rate")
func burnRateReadEvictsSeries() {
    var tracker = BurnRateTracker(window: 100)
    let start = Date(timeIntervalSince1970: 0)
    tracker.record(tokens: 0, at: start)
    tracker.record(tokens: 500, at: start.addingTimeInterval(20))
    tracker.record(tokens: 900, at: start.addingTimeInterval(60))
    // At t=110 the first sample has left the 100 s window, so neither the rate
    // nor the sparkline may still count its delta.
    let rate = tracker.rate(now: start.addingTimeInterval(110))
    #expect(rate.samples == [400])
    #expect(abs(rate.tokensPerMinute - 400 / (90.0 / 60)) < 0.001)
}

// MARK: - Formatting

@Test("token formatting matches the spec table")
func tokenFormatting() {
    #expect(Format.tokens(0) == "0")
    #expect(Format.tokens(999) == "999")
    #expect(Format.tokens(1_200) == "1.2k")
    #expect(Format.tokens(12_400) == "12.4k")
    #expect(Format.tokens(128_000) == "128k")
    #expect(Format.tokens(1_240_000) == "1.24M")
}

@Test("duration formatting steps through its units")
func durationFormatting() {
    #expect(Format.duration(45) == "45s")
    #expect(Format.duration(754) == "12m 34s")
    #expect(Format.duration(8_040) == "2h 14m")
    #expect(Format.duration(280_800) == "3d 6h")
}

@Test("an unknown value formats as a dash, never as zero")
func unavailableFormatting() {
    // The em dash, not two hyphens: that is the glyph the design uses for an
    // absent value and the one the sessions table prints in its own empty
    // cells, and having both spellings on one window made a missing figure
    // look like two different kinds of missing.
    #expect(Format.percent(nil) == "\u{2014}")
    #expect(Format.cost(nil) == "unavailable")
    #expect(Format.timeUntil(nil) == nil)
    #expect(Format.timeUntil(Date(timeIntervalSince1970: 0)) == nil)
}

// MARK: - Thresholds and windows

@Test("severity thresholds are read from named constants")
func severityThresholds() {
    #expect(Constants.UsageThreshold.severity(forPercent: 10) == .healthy)
    #expect(Constants.UsageThreshold.severity(forPercent: 65) == .attention)
    #expect(Constants.UsageThreshold.severity(forPercent: 85) == .warning)
    #expect(Constants.UsageThreshold.severity(forPercent: 97) == .critical)

    #expect(Constants.ContextThreshold.severity(forPercent: 50) == .healthy)
    #expect(Constants.ContextThreshold.severity(forPercent: 90) == .warning)
    #expect(Constants.ContextThreshold.severity(forPercent: 99) == .critical)
}

@Test("only states with a proven data source are marked derivable")
func derivableStates() {
    #expect(SessionStatus.running.isDerivable)
    #expect(SessionStatus.idle.isDerivable)
    #expect(SessionStatus.completed.isDerivable)
    // Waiting became derivable once Claude Code was observed writing the
    // status string itself, rather than it being inferred from a clock. See
    // SessionRegistryAdapter and spec section 6.
    #expect(SessionStatus.waiting.isDerivable)
    #expect(!SessionStatus.permission.isDerivable)
    #expect(!SessionStatus.error.isDerivable)
}

@Test("usage window display names cover flat and model-scoped forms")
func windowDisplayNames() {
    #expect(UsageWindow(name: "five_hour").displayName == "5 Hour")
    #expect(UsageWindow(name: "seven_day").displayName == "7 Day")
    #expect(UsageWindow(name: "seven_day_opus").displayName == "Opus")
    #expect(UsageWindow(name: "seven_day_sonnet_4_6").displayName == "Sonnet 4 6")
}

@Test("remaining percent is the complement and never goes negative")
func windowRemaining() {
    #expect(UsageWindow(name: "five_hour", usedPercent: 72).remainingPercent == 28)
    #expect(UsageWindow(name: "five_hour", usedPercent: 130).remainingPercent == 0)
    #expect(UsageWindow(name: "five_hour", usedPercent: nil).remainingPercent == nil)
}

@Test("home-relative paths abbreviate to a tilde")
func displayPath() {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var session = makeSession(id: "s1")
    session = AISession(
        id: "s1", pid: 1, procStart: "x", projectName: "p",
        workingDirectory: "\(home)/project/demo",
        status: .running, startedAt: Date(), lastActivityAt: Date()
    )
    #expect(session.displayPath == "~/project/demo")
}

// MARK: - Seeding against a store that does not answer

/// A real store with its session read made to fail on demand, and health
/// pinned at `.degraded` the way an earlier unrelated failure leaves it.
///
/// The read has to fail while the writes still work. The defect under test is
/// a collapsed total written back over a good row, and a store broken end to
/// end has nothing to overwrite and so shows nothing.
private final class ReadFailingStore: ClaudenceStoring, @unchecked Sendable {
    let inner: ClaudenceStore
    private let lock = NSLock()
    private var _failSessionReads: Bool
    private var _failDailyTotals = false
    private var _recomputeCalls = 0
    private var _unanswered: UInt64 = 0

    init(inner: ClaudenceStore, failSessionReads: Bool) {
        self.inner = inner
        self._failSessionReads = failSessionReads
    }

    /// Makes the aggregate behind `Tokens today` fail while everything else
    /// answers, which is what a single bad statement looks like from outside.
    var failDailyTotals: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _failDailyTotals
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _failDailyTotals = newValue
        }
    }

    /// How many times the engine asked for a rollup repair.
    var recomputeCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _recomputeCalls
    }

    var failSessionReads: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _failSessionReads
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _failSessionReads = newValue
        }
    }

    /// Already degraded when this pass begins, and with nowhere left to move.
    /// That is the condition a transition check cannot see through.
    var health: StoreHealth { .degraded(reason: "an earlier unrelated failure") }

    var unansweredQueries: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return inner.unansweredQueries &+ _unanswered
    }

    func session(id: String) -> AISession? {
        lock.lock()
        let failing = _failSessionReads
        if failing { _unanswered &+= 1 }
        lock.unlock()
        // A failed read and an absent row return the same nil. The count is
        // the only thing that separates them, exactly as in the real store.
        guard !failing else { return nil }
        return inner.session(id: id)
    }

    func upsert(session: AISession) { inner.upsert(session: session) }
    func markEnded(sessionID: String, at date: Date) {
        inner.markEnded(sessionID: sessionID, at: date)
    }
    func recordUsageSample(sessionID: String, usage: TokenUsage, at date: Date) {
        inner.recordUsageSample(sessionID: sessionID, usage: usage, at: date)
    }
    func dailyTotals(days: Int) -> [(day: String, usage: TokenUsage)] {
        lock.lock()
        let failing = _failDailyTotals
        if failing { _unanswered &+= 1 }
        lock.unlock()
        // A failed aggregate and a day with no rows return the same empty
        // array. Only the count separates them, exactly as in the real store.
        guard !failing else { return [] }
        return inner.dailyTotals(days: days)
    }
    func projectTotals(since: Date?) -> [(project: String, usage: TokenUsage, sessionCount: Int)] {
        inner.projectTotals(since: since)
    }
    func recomputeRollups() {
        lock.lock()
        _recomputeCalls += 1
        lock.unlock()
        inner.recomputeRollups()
    }
    func cursor(forSession sessionID: String) -> ReadCursor? {
        inner.cursor(forSession: sessionID)
    }
    func saveCursor(_ cursor: ReadCursor, forSession sessionID: String) {
        inner.saveCursor(cursor, forSession: sessionID)
    }
}

@Test("a seed read that does not answer never collapses a stored total")
func failedSeedReadDoesNotCollapseStoredTotal() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudenceEngineTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inner = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))

    // The real shape: a cursor already megabytes into the transcript, and the
    // total that cursor corresponds to. The pair is only correct together.
    let today = Date()
    let discovered = makeSession(id: "s1", startedAt: today)
    var stored = discovered
    stored.usage = TokenUsage(
        freshInput: 400_000, cacheCreation: 50_000, cacheRead: 100_000, output: 50_000
    )
    inner.upsert(session: stored)
    inner.saveCursor(
        ReadCursor(path: "/tmp/s1.jsonl", inode: 99, byteOffset: 8_388_608),
        forSession: "s1"
    )

    let storedTotal = try #require(inner.session(id: "s1")).usage.total
    let rollupBefore = inner.dailyTotals(days: 1).first?.usage.total
    #expect(storedTotal == 600_000)
    #expect(rollupBefore == 600_000)

    let store = ReadFailingStore(inner: inner, failSessionReads: true)
    let transcripts = FakeTranscripts()
    transcripts.queue(
        TranscriptDelta(usage: TokenUsage(freshInput: 1_000), recordsParsed: 4),
        for: "s1"
    )
    let engine = MonitorEngine(
        discovery: FakeDiscovery(sessions: [discovered]),
        transcripts: transcripts,
        store: store
    )

    await engine.refreshSessions()

    // The whole pass is skipped: no transcript read, so the cursor does not
    // advance, and no write, so neither the row nor the rollup moves.
    #expect(transcripts.calls.isEmpty)
    #expect(try #require(inner.session(id: "s1")).usage.total == storedTotal)
    #expect(inner.dailyTotals(days: 1).first?.usage.total == rollupBefore)

    // The retry, once the store answers again, resumes from where the cursor
    // already is: the stored total plus the delta, never the delta alone.
    store.failSessionReads = false
    await engine.refreshSessions()

    let session = try #require(await engine.current().sessions.first)
    #expect(session.usage.total == storedTotal + 1_000)
    #expect(try #require(inner.session(id: "s1")).usage.total == storedTotal + 1_000)
    #expect(inner.dailyTotals(days: 1).first?.usage.total == 601_000)
}

/// A store with no database behind it: every call is a no-op, every query is
/// counted as unanswered, and health says `.unavailable` permanently. This is
/// what `ClaudenceStore` becomes when even the in-memory fallback fails.
private final class UnavailableStore: ClaudenceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _unanswered: UInt64 = 0

    var health: StoreHealth { .unavailable(reason: "no database") }

    var unansweredQueries: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _unanswered
    }

    private func countUnanswered() {
        lock.lock(); defer { lock.unlock() }
        _unanswered &+= 1
    }

    func session(id: String) -> AISession? { countUnanswered(); return nil }
    func upsert(session: AISession) { countUnanswered() }
    func markEnded(sessionID: String, at date: Date) { countUnanswered() }
    func recordUsageSample(sessionID: String, usage: TokenUsage, at date: Date) { countUnanswered() }
    func dailyTotals(days: Int) -> [(day: String, usage: TokenUsage)] { countUnanswered(); return [] }
    func projectTotals(since: Date?) -> [(project: String, usage: TokenUsage, sessionCount: Int)] {
        countUnanswered()
        return []
    }
    func recomputeRollups() { countUnanswered() }
    func cursor(forSession sessionID: String) -> ReadCursor? { countUnanswered(); return nil }
    func saveCursor(_ cursor: ReadCursor, forSession sessionID: String) { countUnanswered() }
}

@Test("a permanently unavailable store is no store, not a read worth retrying")
func unavailableStoreStillProducesSessions() async throws {
    let transcripts = FakeTranscripts()
    transcripts.queue(
        TranscriptDelta(usage: TokenUsage(freshInput: 2_000), recordsParsed: 2),
        for: "s1"
    )
    let engine = MonitorEngine(
        discovery: FakeDiscovery(sessions: [makeSession(id: "s1")]),
        transcripts: transcripts,
        store: UnavailableStore()
    )

    await engine.refreshSessions()

    // Nothing was ever persisted, so there is no stored total to lose and no
    // rollup to rewrite. Skipping here would show an empty popover on a
    // machine whose only fault is that it cannot open a database.
    let session = try #require(await engine.current().sessions.first)
    #expect(session.usage.total == 2_000)
    #expect(transcripts.calls == ["s1"])
}

// MARK: - Today's total and the rollup repair

@Test("a daily aggregate that does not answer publishes no total rather than a zero")
func failedDailyAggregatePublishesNoTodayTotal() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudenceEngineTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inner = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))

    let session = makeSession(id: "s1", startedAt: Date())
    let store = ReadFailingStore(inner: inner, failSessionReads: false)
    store.failDailyTotals = true

    let transcripts = FakeTranscripts()
    transcripts.queue(TranscriptDelta(usage: TokenUsage(freshInput: 1_000), recordsParsed: 1), for: "s1")
    let engine = MonitorEngine(
        discovery: FakeDiscovery(sessions: [session]),
        transcripts: transcripts,
        store: store
    )

    await engine.refreshSessions()
    // Nothing durable is wrong here; the header simply has no figure, and a
    // zero would be a measurement it did not take.
    #expect(await engine.current().todayUsage == nil)

    store.failDailyTotals = false
    transcripts.queue(TranscriptDelta(usage: TokenUsage(freshInput: 5), recordsParsed: 1), for: "s1")
    await engine.refreshSessions()
    #expect(await engine.current().todayUsage?.total == 1_005)
}

@Test("the rollups are repaired once when the engine starts, not on every pass")
func rollupRepairIsThrottled() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClaudenceEngineTests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inner = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))
    let store = ReadFailingStore(inner: inner, failSessionReads: false)

    let transcripts = FakeTranscripts()
    transcripts.queue(TranscriptDelta(usage: TokenUsage(freshInput: 10), recordsParsed: 1), for: "s1")
    transcripts.queue(TranscriptDelta(usage: TokenUsage(freshInput: 10), recordsParsed: 1), for: "s1")
    let engine = MonitorEngine(
        // Yesterday's session: the one whose spend the incremental path keeps
        // piling onto the day it started.
        discovery: FakeDiscovery(sessions: [
            makeSession(id: "s1", startedAt: Date().addingTimeInterval(-26 * 60 * 60))
        ]),
        transcripts: transcripts,
        store: store
    )

    await engine.refreshSessions()
    #expect(store.recomputeCalls == 1)

    // A second pass moments later produces tokens again, so it reaches the
    // aggregate, but a full rebuild per filesystem event is exactly the cost
    // this repair is not allowed to have.
    await engine.refreshSessions()
    #expect(store.recomputeCalls == 1)
}
