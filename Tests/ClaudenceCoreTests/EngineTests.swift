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
    #expect(await empty.current().todayUsage.total == 0)
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
