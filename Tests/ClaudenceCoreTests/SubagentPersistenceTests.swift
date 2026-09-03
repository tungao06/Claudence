import Foundation
import Testing

@testable import ClaudenceCore

// MARK: - Fixture

/// A throwaway subagent tree:
/// `<projects>/<slug>/<sessionId>/subagents/agent-<id>.jsonl`, with the
/// `meta.json` beside it that Claude Code writes. Nothing here touches the real
/// `~/.claude`.
private final class SubagentFixture {
    let root: URL
    let projectsDirectory: URL
    let sessionID: String
    let workingDirectory = "/Users/tester/TungAo-Project/project/Claudence"
    let subagentsDirectory: URL

    init(sessionID: String = UUID().uuidString.lowercased()) {
        self.sessionID = sessionID
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudence-subagent-persistence-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        projectsDirectory = root.appendingPathComponent("projects", isDirectory: true)
        subagentsDirectory = projectsDirectory
            .appendingPathComponent(TranscriptLocator.slug(forWorkingDirectory: workingDirectory), isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        try? FileManager.default.createDirectory(at: subagentsDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func transcript(_ agent: String) -> URL {
        subagentsDirectory.appendingPathComponent("\(agent).jsonl")
    }

    /// Creates a subagent with its labels and an initial set of records.
    /// Returns the byte length of what was written, which is where a cursor
    /// from a previous run would sit.
    @discardableResult
    func create(_ agent: String, agentType: String? = nil, description: String? = nil, lines: [String] = []) -> UInt64 {
        if let agentType, let description {
            let meta = """
                {"agentType":"\(agentType)","description":"\(description)","toolUseId":"toolu_1","spawnDepth":1}
                """
            try? Data(meta.utf8).write(to: subagentsDirectory.appendingPathComponent("\(agent).meta.json"))
        }
        FileManager.default.createFile(atPath: transcript(agent).path, contents: Data())
        return append(agent, lines: lines)
    }

    @discardableResult
    func append(_ agent: String, lines: [String]) -> UInt64 {
        guard !lines.isEmpty else { return size(agent) }
        let text = lines.map { $0 + "\n" }.joined()
        if let handle = try? FileHandle(forWritingTo: transcript(agent)) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
            try? handle.close()
        }
        return size(agent)
    }

    func remove(_ agent: String) {
        try? FileManager.default.removeItem(at: transcript(agent))
        try? FileManager.default.removeItem(at: subagentsDirectory.appendingPathComponent("\(agent).meta.json"))
    }

    func size(_ agent: String) -> UInt64 { FileStatus(path: transcript(agent).path)?.size ?? 0 }
    func inode(_ agent: String) -> UInt64 { FileStatus(path: transcript(agent).path)?.inode ?? 0 }

    /// A record shaped like a real Claude Code assistant line.
    func record(
        timestamp: String = "2026-08-18T07:39:02.837Z",
        model: String = "claude-sonnet-5",
        input: Int,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        thinking: Int = 0
    ) -> String {
        """
        {"parentUuid":"\(UUID().uuidString.lowercased())","isSidechain":true,"userType":"external",\
        "cwd":"\(workingDirectory)","sessionId":"\(sessionID)","version":"2.1.257","gitBranch":"main",\
        "type":"assistant","message":{"id":"msg_01Abc","type":"message","role":"assistant",\
        "model":"\(model)","content":[{"type":"text","text":"ordinary response text"}],\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreation),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),\
        "output_tokens_details":{"thinking_tokens":\(thinking)},"service_tier":"standard"}},\
        "uuid":"\(UUID().uuidString.lowercased())","timestamp":"\(timestamp)"}
        """
    }

    func makeTracker(store: (any SubagentTotalStoring)?, cursors: CursorStoring) -> SubagentTracker {
        SubagentTracker(
            locator: SubagentLocator(projectsDirectory: projectsDirectory),
            reader: TranscriptReader(
                cursorStore: cursors,
                locator: TranscriptLocator(projectsDirectory: projectsDirectory)
            ),
            store: store
        )
    }

    /// The descriptor the tracker itself will see, found the same way: by
    /// listing the directory. Building one by hand would risk a path that
    /// differs from the located one and a cursor the reader then ignores.
    func descriptor(_ agent: String) -> SubagentDescriptor {
        SubagentLocator(projectsDirectory: projectsDirectory)
            .subagents(forSession: sessionID, workingDirectory: workingDirectory)
            .first { $0.id == agent }!
    }

    /// The key the reader stores a subagent's offset under, taken from the
    /// tracker rather than spelled out, so the two cannot drift apart.
    func cursorKey(_ agent: String) -> String {
        SubagentTracker.cursorKey(for: descriptor(agent))
    }

    /// The cursor a previous run would have left after consuming the whole
    /// file, expressed against the located path.
    func cursorAtEnd(_ agent: String) -> ReadCursor {
        let path = descriptor(agent).transcriptPath
        let status = FileStatus(path: path)
        return ReadCursor(path: path, inode: status?.inode ?? 0, byteOffset: status?.size ?? 0)
    }
}

/// An in-memory `SubagentTotalStoring` that also counts its writes, so a test
/// can assert that an idle pass touches the database not at all.
private final class FakeTotalStore: SubagentTotalStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [String: SubagentTotal] = [:]
    private var _writes = 0
    private var _deletes = 0

    init(seed: [SubagentTotal] = []) {
        for total in seed { rows[Self.key(total.parentSessionID, total.subagentID)] = total }
    }

    var writes: Int { lock.lock(); defer { lock.unlock() }; return _writes }
    var deletes: Int { lock.lock(); defer { lock.unlock() }; return _deletes }

    func resetCounters() {
        lock.lock()
        defer { lock.unlock() }
        _writes = 0
        _deletes = 0
    }

    /// Answering, always. Nothing here can fail, so the count never moves and
    /// every read this store performs is an answer.
    var health: StoreHealth { .healthy }
    var unansweredQueries: UInt64 { 0 }

    func subagentTotals(forSession sessionID: String) -> [SubagentTotal] {
        lock.lock()
        defer { lock.unlock() }
        return rows.values
            .filter { $0.parentSessionID == sessionID }
            .sorted { $0.subagentID < $1.subagentID }
    }

    func upsertSubagentTotal(_ total: SubagentTotal) {
        lock.lock()
        defer { lock.unlock() }
        _writes += 1
        rows[Self.key(total.parentSessionID, total.subagentID)] = total
    }

    func deleteSubagentTotals(forSession sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        _deletes += 1
        rows = rows.filter { $0.value.parentSessionID != sessionID }
    }

    private static func key(_ parent: String, _ subagent: String) -> String { "\(parent)|\(subagent)" }
}

/// `ClaudenceStore` gets its `SubagentTotalStoring` conformance elsewhere in
/// the source module; this adapter lets the test drive the real database
/// without declaring a second conformance to the same protocol.
private struct StoreTotals: SubagentTotalStoring {
    let store: ClaudenceStore

    var health: StoreHealth { store.health }
    var unansweredQueries: UInt64 { store.unansweredQueries }

    func subagentTotals(forSession sessionID: String) -> [SubagentTotal] {
        store.subagentTotals(forSession: sessionID)
    }

    func upsertSubagentTotal(_ total: SubagentTotal) {
        store.upsertSubagentTotal(total)
    }

    func deleteSubagentTotals(forSession sessionID: String) {
        store.deleteSubagentTotals(forSession: sessionID)
    }
}

/// The real store with its subagent-totals read made to fail on demand, and
/// health pinned at `.degraded` the way an earlier unrelated failure leaves it.
///
/// The read has to fail while the writes still work. The defect under test is a
/// collapsed total written back over a good row, and a store broken end to end
/// has nothing to overwrite and so shows nothing.
private final class ReadFailingTotalStore: SubagentTotalStoring, @unchecked Sendable {
    let inner: ClaudenceStore
    private let lock = NSLock()
    private var _failTotalReads: Bool
    private var _unanswered: UInt64 = 0

    init(inner: ClaudenceStore, failTotalReads: Bool) {
        self.inner = inner
        self._failTotalReads = failTotalReads
    }

    var failTotalReads: Bool {
        get {
            lock.lock(); defer { lock.unlock() }
            return _failTotalReads
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _failTotalReads = newValue
        }
    }

    /// Already degraded when this pass begins, and with nowhere left to move.
    /// That is the condition a health transition cannot see through.
    var health: StoreHealth { .degraded(reason: "an earlier unrelated failure") }

    var unansweredQueries: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return inner.unansweredQueries &+ _unanswered
    }

    func subagentTotals(forSession sessionID: String) -> [SubagentTotal] {
        lock.lock()
        let failing = _failTotalReads
        if failing { _unanswered &+= 1 }
        lock.unlock()
        // A session with no subagents and a query that threw both come back as
        // the same empty array, because that is this read's own default inside
        // `perform`. The count is the only thing that separates them, exactly
        // as in the real store.
        guard !failing else { return [] }
        return inner.subagentTotals(forSession: sessionID)
    }

    func upsertSubagentTotal(_ total: SubagentTotal) { inner.upsertSubagentTotal(total) }

    func deleteSubagentTotals(forSession sessionID: String) {
        inner.deleteSubagentTotals(forSession: sessionID)
    }
}

/// A subagent store with no database behind it: every call is a no-op, every
/// query counts as unanswered, and health says `.unavailable` permanently.
private final class UnavailableTotalStore: SubagentTotalStoring, @unchecked Sendable {
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

    func subagentTotals(forSession sessionID: String) -> [SubagentTotal] {
        countUnanswered()
        return []
    }

    func upsertSubagentTotal(_ total: SubagentTotal) { countUnanswered() }
    func deleteSubagentTotals(forSession sessionID: String) { countUnanswered() }
}

// MARK: - Seeding

@Suite("Subagent totals survive a restart")
struct SubagentPersistenceTests {

    /// The regression this whole mechanism exists for.
    ///
    /// The read cursor is persisted and the total was not, so a relaunch
    /// resumed mid-transcript and counted only what arrived afterwards. Every
    /// token before the offset vanished from the live figure.
    @Test("a resumed cursor adds its delta to the persisted total instead of starting from zero")
    func seededTotalPlusDeltaRatherThanDeltaAlone() async {
        let fixture = SubagentFixture()
        let firstRun = fixture.record(input: 1_000, cacheRead: 4_000, output: 200)
        fixture.create("agent-a", agentType: "Explore", description: "map the store", lines: [firstRun])

        // What the previous process left behind: a cursor at the end of the
        // first record, and the total that offset stands for.
        let cursors = TranscriptMemoryCursorStore()
        cursors.saveCursor(fixture.cursorAtEnd("agent-a"), forSession: fixture.cursorKey("agent-a"))
        let persisted = SubagentTotal(
            parentSessionID: fixture.sessionID,
            subagentID: "agent-a",
            agentType: "Explore",
            taskDescription: "map the store",
            usage: TokenUsage(freshInput: 1_000, cacheRead: 4_000, output: 200),
            recordsParsed: 1,
            lastActivityAt: Date(timeIntervalSince1970: 1_772_000_000),
            model: "claude-sonnet-5"
        )
        let store = FakeTotalStore(seed: [persisted])

        // This run appends one more record and reads only that.
        fixture.append("agent-a", lines: [fixture.record(input: 7, cacheRead: 11, output: 3)])

        let tracker = fixture.makeTracker(store: store, cursors: cursors)
        let subagents = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents

        let agent = try! #require(subagents.first { $0.id == "agent-a" })
        #expect(agent.usage == TokenUsage(freshInput: 1_007, cacheRead: 4_011, output: 203))
        #expect(agent.recordsParsed == 2)
        // Without seeding this is what the defect produced.
        #expect(agent.usage != TokenUsage(freshInput: 7, cacheRead: 11, output: 3))
        #expect(agent.agentType == "Explore")
        #expect(agent.taskDescription == "map the store")

        // And the grown total went back to the store.
        let saved = try! #require(store.subagentTotals(forSession: fixture.sessionID).first)
        #expect(saved.usage == agent.usage)
        #expect(saved.recordsParsed == 2)
    }

    @Test("seeding reads the store once per session, not once per pass")
    func seedingHappensOncePerSession() async {
        let fixture = SubagentFixture()
        fixture.create("agent-a", lines: [fixture.record(input: 5)])
        let store = FakeTotalStore()
        let tracker = fixture.makeTracker(store: store, cursors: TranscriptMemoryCursorStore())

        for _ in 0..<3 {
            _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        }

        // Three passes, one record: the total is read once and written once.
        let agent = try! #require(store.subagentTotals(forSession: fixture.sessionID).first)
        #expect(agent.usage.freshInput == 5)
        #expect(store.writes == 1)
    }

    @Test("a refresh that reads no new records performs no write")
    func idlePassWritesNothing() async {
        let fixture = SubagentFixture()
        fixture.create("agent-a", lines: [fixture.record(input: 5, output: 2)])
        let store = FakeTotalStore()
        let tracker = fixture.makeTracker(store: store, cursors: TranscriptMemoryCursorStore())

        _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        #expect(store.writes == 1)
        store.resetCounters()

        // Nothing appended. The transcript is not even opened, and the row is
        // already exactly what the accumulator holds.
        for _ in 0..<5 {
            _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        }
        #expect(store.writes == 0)
        #expect(store.deletes == 0)
    }

    @Test("a growing transcript writes once per pass that actually read something")
    func writesFollowRealDeltas() async {
        let fixture = SubagentFixture()
        fixture.create("agent-a", lines: [fixture.record(input: 5)])
        let store = FakeTotalStore()
        let tracker = fixture.makeTracker(store: store, cursors: TranscriptMemoryCursorStore())

        _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        fixture.append("agent-a", lines: [fixture.record(input: 6)])
        _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)

        #expect(store.writes == 2)
        #expect(store.subagentTotals(forSession: fixture.sessionID).first?.usage.freshInput == 11)
    }

    @Test("forgetting a session keeps its persisted rows, which pair with the cursors")
    func forgetKeepsRows() async {
        let fixture = SubagentFixture()
        fixture.create("agent-a", lines: [fixture.record(input: 5)])
        let store = FakeTotalStore(seed: [
            SubagentTotal(parentSessionID: "other", subagentID: "agent-z", usage: TokenUsage(output: 9))
        ])
        let tracker = fixture.makeTracker(store: store, cursors: TranscriptMemoryCursorStore())

        _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        #expect(store.subagentTotals(forSession: fixture.sessionID).count == 1)

        await tracker.forget(sessionID: fixture.sessionID)

        let leftInMemory = await tracker.subagents(forSession: fixture.sessionID)
        // The row stays. It pairs with the read cursor, and nothing deletes a
        // cursor, so dropping the total alone would leave the transcript
        // resumable at byte N against a total of zero. A session brought back
        // with `claude --resume` would then count only what is appended after
        // the resume, the engine would write that collapsed figure to the
        // session row, and the rollup would be rewritten down by everything the
        // subagents had spent. This mirrors the parent side, where `markEnded`
        // keeps the session row for exactly the same reason.
        #expect(store.subagentTotals(forSession: fixture.sessionID).count == 1)
        #expect(leftInMemory.isEmpty)
        // Another session's rows are untouched.
        #expect(store.subagentTotals(forSession: "other").count == 1)
    }

    @Test("a subagent that vanished from disk loses its persisted row as well")
    func vanishedSubagentLosesItsRow() async {
        let fixture = SubagentFixture()
        fixture.create("agent-a", lines: [fixture.record(input: 5)])
        fixture.create("agent-b", lines: [fixture.record(input: 50)])
        let store = FakeTotalStore()
        let tracker = fixture.makeTracker(store: store, cursors: TranscriptMemoryCursorStore())

        _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        #expect(store.subagentTotals(forSession: fixture.sessionID).map(\.subagentID) == ["agent-a", "agent-b"])

        fixture.remove("agent-a")
        let remaining = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents

        #expect(remaining.map(\.id) == ["agent-b"])
        let rows = store.subagentTotals(forSession: fixture.sessionID)
        #expect(rows.map(\.subagentID) == ["agent-b"])
        // The survivor kept its figure through the rewrite.
        #expect(rows.first?.usage.freshInput == 50)
    }

    @Test("a subagent persisted by an earlier run whose transcript is gone is cleaned up on the first pass")
    func seededButVanishedSubagentIsCleanedUp() async {
        let fixture = SubagentFixture()
        fixture.create("agent-live", lines: [fixture.record(input: 5)])
        let store = FakeTotalStore(seed: [
            SubagentTotal(parentSessionID: fixture.sessionID, subagentID: "agent-gone",
                          usage: TokenUsage(freshInput: 900), recordsParsed: 3)
        ])
        let tracker = fixture.makeTracker(store: store, cursors: TranscriptMemoryCursorStore())

        let subagents = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents

        #expect(subagents.map(\.id) == ["agent-live"])
        #expect(store.subagentTotals(forSession: fixture.sessionID).map(\.subagentID) == ["agent-live"])
    }

    @Test("without a store the tracker behaves exactly as it did, correct within a run")
    func trackerWithoutAStoreStillAccumulates() async {
        let fixture = SubagentFixture()
        fixture.create("agent-a", lines: [fixture.record(input: 5, output: 1)])
        let tracker = fixture.makeTracker(store: nil, cursors: TranscriptMemoryCursorStore())

        _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        fixture.append("agent-a", lines: [fixture.record(input: 6, output: 2)])
        let subagents = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents

        #expect(subagents.first?.usage == TokenUsage(freshInput: 11, output: 3))
        await tracker.forget(sessionID: fixture.sessionID)
        let forgotten = await tracker.subagents(forSession: fixture.sessionID)
        #expect(forgotten.isEmpty)
    }

    // MARK: - Through the real store

    @Test("the tracker resumes from a real ClaudenceStore across a simulated relaunch")
    func totalsSurviveARelaunchThroughTheRealStore() async {
        let fixture = SubagentFixture()
        fixture.create("agent-a", agentType: "general-purpose", description: "do the work",
                       lines: [fixture.record(input: 1_000, cacheRead: 4_000, output: 200)])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceSubagentPersistence", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("claudence.db")

        // First run: read the transcript, persisting both cursor and total.
        do {
            let store = ClaudenceStore(url: databaseURL)
            let tracker = fixture.makeTracker(store: StoreTotals(store: store), cursors: store)
            _ = await tracker.refresh(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
            #expect(store.health == .healthy)
        }

        fixture.append("agent-a", lines: [fixture.record(input: 7, cacheRead: 11, output: 3)])

        // Second run: a new store and a new tracker over the same file.
        let store = ClaudenceStore(url: databaseURL)
        let tracker = fixture.makeTracker(store: StoreTotals(store: store), cursors: store)
        let subagents = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents

        let agent = try! #require(subagents.first)
        #expect(agent.usage == TokenUsage(freshInput: 1_007, cacheRead: 4_011, output: 203))
        #expect(agent.recordsParsed == 2)
        #expect(agent.agentType == "general-purpose")
        #expect(agent.taskDescription == "do the work")
        #expect(store.subagentTotals(forSession: fixture.sessionID).first?.usage == agent.usage)
    }

    // MARK: - Seeding against a store that does not answer

    /// The sibling of `failedSeedReadDoesNotCollapseStoredTotal` in
    /// `EngineTests`, one source along. The parent side was fixed first; this
    /// side is the larger figure. Subagents were 36.3% of this machine's month
    /// and 82% on one project, so a seed that reads zero and writes it back
    /// loses more than the parent path ever could.
    @Test("a subagent seed read that does not answer never collapses a stored total")
    func failedSubagentSeedReadDoesNotCollapseStoredTotal() async throws {
        let fixture = SubagentFixture()
        let firstRun = fixture.record(input: 1_000, cacheRead: 4_000, output: 200)
        let offsetAfterFirstRun = fixture.create(
            "agent-a", agentType: "Explore", description: "map the store", lines: [firstRun]
        )
        #expect(offsetAfterFirstRun > 0)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceSubagentSeedFailure", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inner = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))

        // What a previous process left behind: a cursor at the end of the first
        // record, and the total that offset stands for. The pair is only
        // correct together.
        let persisted = SubagentTotal(
            parentSessionID: fixture.sessionID,
            subagentID: "agent-a",
            agentType: "Explore",
            taskDescription: "map the store",
            usage: TokenUsage(freshInput: 1_000, cacheRead: 4_000, output: 200),
            recordsParsed: 1,
            lastActivityAt: Date(timeIntervalSince1970: 1_772_000_000),
            model: "claude-sonnet-5"
        )
        inner.upsertSubagentTotal(persisted)
        inner.saveCursor(fixture.cursorAtEnd("agent-a"), forSession: fixture.cursorKey("agent-a"))

        // This run has a second record waiting to be read.
        fixture.append("agent-a", lines: [fixture.record(input: 7, cacheRead: 11, output: 3)])

        let store = ReadFailingTotalStore(inner: inner, failTotalReads: true)
        let tracker = fixture.makeTracker(store: store, cursors: inner)

        let skipsBefore = EngineCounters.shared.snapshot.skippedUnseededSubagents
        let skipped = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents

        // Nothing is known about this session's subagents yet, and inventing a
        // zero would be the undercount itself.
        #expect(skipped.isEmpty)
        // Visible, not silent.
        #expect(EngineCounters.shared.snapshot.skippedUnseededSubagents == skipsBefore + 1)
        // No transcript was read, so the cursor is still where the previous run
        // left it, and no row was written, so the stored total is still the
        // figure that offset stands for.
        #expect(inner.cursor(forSession: fixture.cursorKey("agent-a"))?.byteOffset == offsetAfterFirstRun)
        let intact = try #require(inner.subagentTotals(forSession: fixture.sessionID).first)
        #expect(intact.usage == TokenUsage(freshInput: 1_000, cacheRead: 4_000, output: 200))
        #expect(intact.recordsParsed == 1)
        // The collapsed figure the defect wrote back.
        #expect(intact.usage != TokenUsage(freshInput: 7, cacheRead: 11, output: 3))

        // The retry, once the store answers again, resumes from where the
        // cursor already is: the stored total plus the delta, never the delta
        // alone.
        store.failTotalReads = false
        let resumed = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents

        let agent = try #require(resumed.first { $0.id == "agent-a" })
        #expect(agent.usage == TokenUsage(freshInput: 1_007, cacheRead: 4_011, output: 203))
        #expect(agent.recordsParsed == 2)
        #expect(agent.taskDescription == "map the store")
        let saved = try #require(inner.subagentTotals(forSession: fixture.sessionID).first)
        #expect(saved.usage == agent.usage)
        #expect(saved.recordsParsed == 2)
    }

    @Test("a permanently unavailable subagent store is no store, not a read worth retrying")
    func unavailableTotalStoreStillAccumulates() async throws {
        let fixture = SubagentFixture()
        fixture.create("agent-a", lines: [fixture.record(input: 5, output: 1)])
        let tracker = fixture.makeTracker(
            store: UnavailableTotalStore(),
            cursors: TranscriptMemoryCursorStore()
        )

        // Nothing was ever persisted, so there is no stored total to lose and
        // no cursor to strand. Skipping here would hide every subagent forever
        // on a machine whose only fault is that it cannot open a database.
        let subagents = await tracker.refresh(
            sessionID: fixture.sessionID,
            workingDirectory: fixture.workingDirectory
        ).subagents
        #expect(subagents.map(\.id) == ["agent-a"])
        #expect(subagents.first?.usage == TokenUsage(freshInput: 5, output: 1))
    }
}

// MARK: - The engine over a withheld subagent answer

/// Discovery that reports one fixed session, so a pass can be driven without a
/// registry on disk.
private struct StubDiscovery: SessionDiscovering {
    let sourceName = "stub-discovery"
    let sessions: [AISession]
    func discover() -> [AISession] { sessions }
}

/// A parent transcript that always answers and always carries nothing. The
/// parent side is deliberately uninteresting here: what is under test is what
/// the engine writes for the *subagents* when their figure cannot be
/// established, and a parent delta of its own would only add a second moving
/// part.
private struct StubTranscripts: TranscriptReading, @unchecked Sendable {
    let sourceName = "stub-transcripts"
    func readIncremental(sessionID: String, workingDirectory: String) -> TranscriptDelta { .empty }
}

@Suite("Engine over a withheld subagent answer")
struct EngineWithheldSubagentTests {

    /// What a previous run left on disk: a parent total, a subagent total, and
    /// the rollup row that stands for both.
    private func seedRow(store: ClaudenceStore, sessionID: String, workingDirectory: String) -> AISession {
        let session = AISession(
            id: sessionID,
            pid: 4242,
            procStart: "Tue Sep  1 19:27:02 2026",
            projectName: "Claudence",
            workingDirectory: workingDirectory,
            status: .running,
            startedAt: Date(),
            lastActivityAt: Date(),
            usage: TokenUsage(freshInput: 500, cacheRead: 2_000, output: 100),
            subagentUsage: TokenUsage(freshInput: 1_000, cacheRead: 4_000, output: 200),
            subagentCount: 1
        )
        store.upsert(session: session)
        return session
    }

    /// The blocker this suite exists for. `SubagentTracker.refresh` refuses to
    /// write a figure it could not establish, and until 2026-09-03 the engine
    /// wrote it on the tracker's behalf: an empty answer became
    /// `subagentUsage = .zero`, the upsert subtracted the stored combined total
    /// from the rollup and added a parent-only one, and the collapse the
    /// tracker prevents happened one layer up. The tracker's own test could not
    /// see it, because the tracker did nothing wrong.
    @Test("a withheld subagent seed leaves the session row and the rollup alone")
    func withheldSeedLeavesStoredSubagentTotalAlone() async throws {
        let fixture = SubagentFixture()
        fixture.create(
            "agent-a",
            agentType: "Explore",
            description: "map the store",
            lines: [fixture.record(input: 1_000, cacheRead: 4_000, output: 200)]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceEngineWithheldSeed", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))
        let session = seedRow(store: store, sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        let before = try #require(store.session(id: fixture.sessionID))
        let rollupBefore = store.dailyTotals(days: 1)

        // The subagent side cannot read its stored totals; everything else
        // works, which is what one bad statement looks like from outside.
        let totals = ReadFailingTotalStore(inner: store, failTotalReads: true)
        let engine = MonitorEngine(
            discovery: StubDiscovery(sessions: [session]),
            transcripts: StubTranscripts(),
            store: store,
            subagents: fixture.makeTracker(store: totals, cursors: store)
        )
        await engine.refreshSessions()

        let after = try #require(store.session(id: fixture.sessionID))
        #expect(after.subagentUsage == before.subagentUsage)
        #expect(after.subagentCount == before.subagentCount)
        #expect(store.dailyTotals(days: 1).map(\.usage) == rollupBefore.map(\.usage))

        // And the interface is told the combined figure, not a parent-only one.
        let published = try #require(await engine.current().sessions.first)
        #expect(published.subagentUsage == before.subagentUsage)
    }

    /// The second blocker, from the other source. A directory that exists and
    /// cannot be listed is not a session with no subagents, and reading it as
    /// one wrote the same zero over the same row.
    @Test("a subagent directory that cannot be listed leaves the stored total alone")
    func unreadableSubagentDirectoryLeavesStoredTotalAlone() async throws {
        let fixture = SubagentFixture()
        fixture.create(
            "agent-a",
            agentType: "Explore",
            description: "map the store",
            lines: [fixture.record(input: 1_000, cacheRead: 4_000, output: 200)]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceEngineUnreadableSubagents", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))
        let session = seedRow(store: store, sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        let before = try #require(store.session(id: fixture.sessionID))

        let engine = MonitorEngine(
            discovery: StubDiscovery(sessions: [session]),
            transcripts: StubTranscripts(),
            store: store,
            subagents: fixture.makeTracker(store: StoreTotals(store: store), cursors: store)
        )

        // The directory is there and unreadable, which is the case
        // `SubagentLocator` reports as nil and everything above it used to
        // read as "no subagents".
        try FileManager.default.setAttributes(
            [.posixPermissions: 0],
            ofItemAtPath: fixture.subagentsDirectory.path
        )
        let withheldBefore = EngineCounters.shared.snapshot.withheldSubagentListings
        await engine.refreshSessions()
        let withheldAfter = EngineCounters.shared.snapshot.withheldSubagentListings
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.subagentsDirectory.path
        )

        #expect(withheldAfter > withheldBefore)
        let after = try #require(store.session(id: fixture.sessionID))
        #expect(after.subagentUsage == before.subagentUsage)
        #expect(after.subagentCount == before.subagentCount)

        // The pass that follows, with the directory readable again, is the
        // proof that the skip was a skip and not a loss: the figure comes back
        // from the transcript rather than staying stuck at what was stored.
        await engine.refreshSessions()
        let restored = try #require(store.session(id: fixture.sessionID))
        #expect(restored.subagentUsage == TokenUsage(freshInput: 1_000, cacheRead: 4_000, output: 200))
        #expect(restored.subagentCount == 1)
    }
}
