import Foundation
import Testing

@testable import ClaudenceCore

// MARK: - Fixtures

private enum Fixture {

    /// A real record captured from Claude Code 2.1.257, verbatim.
    static let realInteractive = """
    {"pid":42541,"sessionId":"6ff2ff43-cf68-4328-8c8f-0ceb6c93f768",\
    "cwd":"/Users/tungao/TungAo-Project/project/Claudence","startedAt":1788290824722,\
    "procStart":"Tue Sep  1 19:27:02 2026","version":"2.1.257","peerProtocol":1,\
    "peerFeatures":["notify_idle","reply_across_default_dirs","artifact_yield"],\
    "kind":"interactive","entrypoint":"cli","pidDomain":"darwin",\
    "messagingSocketPath":"/tmp/cc-socks/42541.sock","name":"claudence-06",\
    "nameSource":"derived","nameSince":1788290824722,"status":"busy",\
    "updatedAt":1788291241627,"statusUpdatedAt":1788291241627,\
    "bridgeSessionId":"session_01GgMv9pFHcEFgGM1D86jGZL"}
    """

    /// A real `kind == "bg"` record. Infrastructure, not a user session.
    static let realBackground = """
    {"pid":7473,"sessionId":"6e3144bd-cb4e-47c1-b0cf-3b4e5d8200b2",\
    "cwd":"/Users/tungao/TungAo-Project/Eclaim/e-claim-api-nest","startedAt":1788253416939,\
    "procStart":"Tue Sep  1 09:03:36 2026","version":"2.1.252","kind":"bg",\
    "entrypoint":"cli","name":"jobs-consolidation-reorg","jobId":"6e3144bd",\
    "status":"idle","updatedAt":1788276633462,"nameSource":"auto"}
    """

    /// The same record plus fields Claudence has never seen. Must still decode.
    static let unknownFields = """
    {"pid":9001,"sessionId":"unknown-fields","cwd":"/tmp/demo",\
    "startedAt":1788290824722,"procStart":"Tue Sep  1 19:27:02 2026",\
    "kind":"interactive","status":"busy","updatedAt":1788291241627,\
    "name":"demo","futureField":{"nested":[1,2,3]},"anotherOne":true,\
    "quotaBucket":"weekly","telemetry":null}
    """

    static let malformed = "{\"pid\":123,\"sessionId\":\"trunc"

    /// Structurally valid JSON that is missing required fields.
    static let missingRequired = "{\"pid\":124,\"kind\":\"interactive\"}"

    static func write(_ contents: String, named name: String, into dir: URL) throws {
        try contents.write(
            to: dir.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudence-registry-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true
        )
        return url
    }
}

/// A record built by hand, so status/liveness tests do not depend on fixtures.
private func record(
    pid: Int32 = 1,
    kind: String = "interactive",
    status: String? = "busy",
    startedAt: Double = 1_788_290_824_722,
    updatedAt: Double? = 1_788_291_241_627,
    name: String? = "demo"
) -> RegistryRecord {
    RegistryRecord(
        pid: pid,
        sessionId: "session-\(pid)",
        cwd: "/tmp/demo",
        startedAt: startedAt,
        procStart: "Tue Sep  1 19:27:02 2026",
        kind: kind,
        status: status,
        updatedAt: updatedAt,
        name: name,
        version: "2.1.257"
    )
}

// MARK: - Decoding

@Suite("Registry decoding")
struct RegistryDecodingTests {

    @Test("Decodes a real interactive record")
    func decodesRealRecord() throws {
        let decoded = try JSONDecoder().decode(
            RegistryRecord.self,
            from: Data(Fixture.realInteractive.utf8)
        )

        #expect(decoded.pid == 42541)
        #expect(decoded.sessionId == "6ff2ff43-cf68-4328-8c8f-0ceb6c93f768")
        #expect(decoded.cwd == "/Users/tungao/TungAo-Project/project/Claudence")
        #expect(decoded.procStart == "Tue Sep  1 19:27:02 2026")
        #expect(decoded.kind == "interactive")
        #expect(decoded.isInteractive)
        #expect(decoded.status == "busy")
        #expect(decoded.name == "claudence-06")
        #expect(decoded.version == "2.1.257")
        #expect(decoded.startedAt == 1_788_290_824_722)
        #expect(decoded.updatedAt == 1_788_291_241_627)
    }

    @Test("Unknown fields are ignored, not fatal")
    func ignoresUnknownFields() throws {
        let decoded = try JSONDecoder().decode(
            RegistryRecord.self,
            from: Data(Fixture.unknownFields.utf8)
        )
        #expect(decoded.sessionId == "unknown-fields")
        #expect(decoded.isInteractive)
        #expect(decoded.name == "demo")
    }

    @Test("A bg record decodes and is not interactive")
    func decodesBackgroundRecord() throws {
        let decoded = try JSONDecoder().decode(
            RegistryRecord.self,
            from: Data(Fixture.realBackground.utf8)
        )
        #expect(decoded.kind == "bg")
        #expect(decoded.isInteractive == false)
        #expect(decoded.status == "idle")
    }

    @Test("displayName falls back to the cwd leaf")
    func displayNameFallback() {
        #expect(record(name: nil).displayName == "demo")
        #expect(record(name: "").displayName == "demo")
        #expect(record(name: "claudence-06").displayName == "claudence-06")
    }
}

// MARK: - Epoch milliseconds

@Suite("Epoch milliseconds")
struct EpochMillisecondTests {

    @Test("startedAt is milliseconds, not seconds")
    func startedAtConversion() throws {
        let decoded = try JSONDecoder().decode(
            RegistryRecord.self,
            from: Data(Fixture.realInteractive.utf8)
        )
        #expect(decoded.startedAtDate.timeIntervalSince1970 == 1_788_290_824.722)
        #expect(decoded.lastActivityDate.timeIntervalSince1970 == 1_788_291_241.627)
    }

    @Test("Round trips through Date")
    func roundTrip() {
        let date = Date(epochMilliseconds: 1_788_290_824_722)
        #expect(date.epochMilliseconds == 1_788_290_824_722)
    }

    @Test("lastActivityDate falls back to startedAt when updatedAt is absent")
    func fallsBackToStartedAt() {
        let r = record(updatedAt: nil)
        #expect(r.lastActivityDate == r.startedAtDate)
    }
}

// MARK: - Status mapping

@Suite("Status mapping", .serialized)
struct StatusMappingTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var recent: Date { Self.now.addingTimeInterval(-1) }
    private var stale: Date {
        Self.now.addingTimeInterval(-Constants.Watch.idleThreshold - 1)
    }

    @Test("busy while recent is running")
    func busyRecent() {
        #expect(
            SessionRegistryAdapter.mapStatus("busy", lastActivityAt: recent, now: Self.now)
                == .running
        )
    }

    @Test("busy stays running even when updatedAt has gone stale")
    func busyStale() {
        // Measured: Claude Code only moves `updatedAt` on a status transition,
        // so a genuinely busy session carries a minutes-old timestamp. Gating
        // `busy` on the idle threshold reported a working session as idle.
        // A crashed session that left `busy` behind is removed by the liveness
        // filter instead.
        #expect(
            SessionRegistryAdapter.mapStatus("busy", lastActivityAt: stale, now: Self.now)
                == .running
        )
    }

    @Test("idle is idle regardless of recency")
    func idleStatus() {
        #expect(
            SessionRegistryAdapter.mapStatus("idle", lastActivityAt: recent, now: Self.now)
                == .idle
        )
        #expect(
            SessionRegistryAdapter.mapStatus("idle", lastActivityAt: stale, now: Self.now)
                == .idle
        )
    }

    @Test("waiting maps to waiting, not through the recency fallback")
    func waitingStatus() {
        #expect(
            SessionRegistryAdapter.mapStatus("waiting", lastActivityAt: recent, now: Self.now)
                == .waiting
        )
        #expect(
            SessionRegistryAdapter.mapStatus(
                "waiting_for_input", lastActivityAt: recent, now: Self.now
            ) == .waiting
        )
    }

    @Test("waiting stays waiting even when updatedAt has gone stale")
    func waitingStale() {
        // The regression. `waiting` was unmapped, so it fell through to the
        // recency fallback and a session that had been blocked on the user for
        // longer than the idle threshold was displayed as Idle. Captured on
        // Claude Code 2.1.258: one session went busy -> waiting -> busy -> idle,
        // and `updatedAt` only moves on the transition, so a real waiting
        // session is stale by construction.
        #expect(
            SessionRegistryAdapter.mapStatus("waiting", lastActivityAt: stale, now: Self.now)
                == .waiting
        )
        #expect(
            SessionRegistryAdapter.mapStatus("waiting", lastActivityAt: stale, now: Self.now)
                != .idle
        )
    }

    @Test("waiting is derivable, permission and error are not")
    func waitingIsDerivable() {
        #expect(SessionStatus.waiting.isDerivable)
        #expect(!SessionStatus.permission.isDerivable)
        #expect(!SessionStatus.error.isDerivable)
    }

    @Test("Terminal spellings map to completed")
    func completedStatus() {
        for raw in ["completed", "done", "exited", "closed", "finished"] {
            #expect(
                SessionRegistryAdapter.mapStatus(raw, lastActivityAt: recent, now: Self.now)
                    == .completed
            )
        }
    }

    @Test("An unknown value falls back on the idle threshold")
    func unknownFallback() {
        #expect(
            SessionRegistryAdapter.mapStatus(
                "quantum_entangled", lastActivityAt: recent, now: Self.now
            ) == .running
        )
        #expect(
            SessionRegistryAdapter.mapStatus(
                "quantum_entangled", lastActivityAt: stale, now: Self.now
            ) == .idle
        )
    }

    @Test("A missing status falls back on the idle threshold")
    func missingStatus() {
        #expect(
            SessionRegistryAdapter.mapStatus(nil, lastActivityAt: recent, now: Self.now)
                == .running
        )
        #expect(
            SessionRegistryAdapter.mapStatus(nil, lastActivityAt: stale, now: Self.now)
                == .idle
        )
    }

    @Test("Exactly at the idle threshold counts as idle")
    func thresholdBoundary() {
        let boundary = Self.now.addingTimeInterval(-Constants.Watch.idleThreshold)
        let justInside = boundary.addingTimeInterval(0.001)
        #expect(
            SessionRegistryAdapter.mapStatus(
                "never_seen_before", lastActivityAt: boundary, now: Self.now
            ) == .idle
        )
        #expect(
            SessionRegistryAdapter.mapStatus(
                "never_seen_before", lastActivityAt: justInside, now: Self.now
            ) == .running
        )
    }

    @Test("Every mapped state is derivable today")
    func onlyDerivableStates() {
        for raw in ["busy", "idle", "completed", "waiting", "who_knows", ""] {
            let mapped = SessionRegistryAdapter.mapStatus(
                raw, lastActivityAt: recent, now: Self.now
            )
            #expect(mapped.isDerivable, "\(raw) mapped to a non-derivable state")
        }
    }

    @Test("Distinct raw status values are recorded for the M1 survey")
    func recordsObservedValues() {
        SessionRegistryAdapter.resetObservedStatusValues()
        SessionRegistryAdapter.mapStatus("busy", lastActivityAt: recent, now: Self.now)
        SessionRegistryAdapter.mapStatus("BUSY", lastActivityAt: recent, now: Self.now)
        SessionRegistryAdapter.mapStatus("idle", lastActivityAt: recent, now: Self.now)
        SessionRegistryAdapter.mapStatus("brand_new", lastActivityAt: recent, now: Self.now)
        SessionRegistryAdapter.mapStatus(nil, lastActivityAt: recent, now: Self.now)
        SessionRegistryAdapter.mapStatus("", lastActivityAt: recent, now: Self.now)

        let observed = SessionRegistryAdapter.observedStatusValues
        #expect(observed == ["busy", "idle", "brand_new"])
        #expect(SessionRegistryAdapter.observedStatusValuesInOrder
            == ["busy", "idle", "brand_new"])
        SessionRegistryAdapter.resetObservedStatusValues()
    }
}

// MARK: - Liveness

@Suite("Liveness")
struct LivenessTests {

    @Test("procStart of a live process is readable and matches")
    func ownProcessMatches() throws {
        let pid = getpid()
        let start = try #require(SessionRegistryAdapter.processStartTime(pid: pid))
        let formatted = SessionRegistryAdapter.formatProcStart(start)
        #expect(SessionRegistryAdapter.processExists(pid: pid))
        #expect(SessionRegistryAdapter.isAlive(pid: pid, procStart: formatted))
    }

    @Test("formatProcStart produces the ctime layout Claude Code writes")
    func ctimeLayout() {
        // 1788290822 == Tue Sep  1 19:27:02 2026 UTC, verified against a real file.
        let date = Date(timeIntervalSince1970: 1_788_290_822)
        #expect(SessionRegistryAdapter.formatProcStart(date) == "Tue Sep  1 19:27:02 2026")
    }

    @Test("procStart parses as UTC ctime")
    func parsesUTC() throws {
        let parsed = try #require(
            SessionRegistryAdapter.parseProcStart("Tue Sep  1 19:27:02 2026")
        )
        #expect(parsed.timeIntervalSince1970 == 1_788_290_822)
    }

    @Test("A live pid with the wrong procStart is dead")
    func mismatchedProcStartIsDead() {
        // The critical rule: kill(pid, 0) alone would say alive here.
        #expect(SessionRegistryAdapter.processExists(pid: getpid()))
        #expect(
            SessionRegistryAdapter.isAlive(
                pid: getpid(), procStart: "Tue Sep  1 19:27:02 2026"
            ) == false
        )
    }

    @Test("An unparseable procStart is conservatively dead")
    func unparseableProcStartIsDead() {
        #expect(SessionRegistryAdapter.isAlive(pid: getpid(), procStart: "not a date") == false)
        #expect(SessionRegistryAdapter.isAlive(pid: getpid(), procStart: "") == false)
    }

    @Test("A pid that cannot exist is dead")
    func impossiblePidIsDead() {
        #expect(SessionRegistryAdapter.isAlive(pid: 0, procStart: "Tue Sep  1 19:27:02 2026") == false)
        #expect(SessionRegistryAdapter.isAlive(pid: -1, procStart: "Tue Sep  1 19:27:02 2026") == false)
        #expect(SessionRegistryAdapter.processStartTime(pid: 999_999) == nil)
    }
}

// MARK: - Discovery

@Suite("Discovery")
struct DiscoveryTests {

    @Test("A nonexistent directory yields no sessions and does not throw")
    func nonexistentDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudence-does-not-exist-\(UUID().uuidString)")
        let adapter = SessionRegistryAdapter(directory: missing, livenessCheck: { _ in true })
        #expect(adapter.discover().isEmpty)
        #expect(adapter.loadRecords().isEmpty)
    }

    @Test("An empty directory yields no sessions")
    func emptyDirectory() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let adapter = SessionRegistryAdapter(directory: dir, livenessCheck: { _ in true })
        #expect(adapter.discover().isEmpty)
    }

    @Test("A file path instead of a directory yields no sessions")
    func directoryIsAFile() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("notadir")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let adapter = SessionRegistryAdapter(directory: file, livenessCheck: { _ in true })
        #expect(adapter.discover().isEmpty)
    }

    @Test("Non-interactive kinds are filtered out")
    func filtersNonInteractive() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.write(Fixture.realInteractive, named: "42541.json", into: dir)
        try Fixture.write(Fixture.realBackground, named: "7473.json", into: dir)

        let adapter = SessionRegistryAdapter(directory: dir, livenessCheck: { _ in true })
        let sessions = adapter.discover()

        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == 42541)
        #expect(adapter.loadRecords().count == 2)
    }

    @Test("Malformed files are skipped silently and counted")
    func skipsMalformed() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.write(Fixture.realInteractive, named: "42541.json", into: dir)
        try Fixture.write(Fixture.malformed, named: "111.json", into: dir)
        try Fixture.write(Fixture.missingRequired, named: "112.json", into: dir)
        try Fixture.write("", named: "113.json", into: dir)
        try Fixture.write("not json at all", named: "114.json", into: dir)
        // Non-.json siblings (Claude Code writes .key files here) are ignored.
        try Fixture.write("binary-ish", named: "42541.abc.key", into: dir)

        let adapter = SessionRegistryAdapter(directory: dir, livenessCheck: { _ in true })
        let sessions = adapter.discover()

        #expect(sessions.count == 1)
        #expect(adapter.malformedFileCount == 4)
    }

    @Test("Dead processes never produce a session and files are not deleted")
    func reapsStaleWithoutDeleting() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.write(Fixture.realInteractive, named: "42541.json", into: dir)

        let adapter = SessionRegistryAdapter(directory: dir, livenessCheck: { _ in false })
        #expect(adapter.discover().isEmpty)
        // The files belong to Claude Code. Ignored, never removed.
        #expect(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("42541.json").path
            )
        )
    }

    @Test("A live record maps onto AISession correctly")
    func mapsToSession() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.write(Fixture.realInteractive, named: "42541.json", into: dir)

        let now = Date(timeIntervalSince1970: 1_788_291_251)  // 10s after updatedAt
        let adapter = SessionRegistryAdapter(
            directory: dir,
            livenessCheck: { _ in true },
            clock: { now }
        )
        let session = try #require(adapter.discover().first)

        #expect(session.id == "6ff2ff43-cf68-4328-8c8f-0ceb6c93f768")
        #expect(session.pid == 42541)
        #expect(session.procStart == "Tue Sep  1 19:27:02 2026")
        #expect(session.projectName == "claudence-06")
        #expect(session.workingDirectory == "/Users/tungao/TungAo-Project/project/Claudence")
        #expect(session.status == .running)
        #expect(session.startedAt.timeIntervalSince1970 == 1_788_290_824.722)
        #expect(session.lastActivityAt.timeIntervalSince1970 == 1_788_291_241.627)
        #expect(session.usage == .zero)
        #expect(session.model == nil)
        #expect(session.currentActivity == nil)
        #expect(session.claudeCodeVersion == "2.1.257")
    }

    @Test("Sessions come back ordered by start time")
    func sortedByStart() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Fixture.write(Fixture.realInteractive, named: "42541.json", into: dir)
        try Fixture.write(Fixture.unknownFields, named: "9001.json", into: dir)

        let adapter = SessionRegistryAdapter(directory: dir, livenessCheck: { _ in true })
        let sessions = adapter.discover()
        #expect(sessions.count == 2)
        #expect(sessions[0].startedAt <= sessions[1].startedAt)
    }

    @Test("sourceName is set for degraded-state messages")
    func sourceName() {
        #expect(SessionRegistryAdapter().sourceName == "Session registry")
    }

    @Test("Defaults to the real sessions directory without touching it")
    func defaultDirectory() {
        #expect(SessionRegistryAdapter().directory == Constants.sessionsDirectory)
    }
}

// MARK: - Watcher

@Suite("Registry watcher")
struct RegistryWatcherTests {

    @Test("Debounce duration converts to seconds")
    func debounceSeconds() {
        #expect(RegistryWatcher.seconds(from: .milliseconds(250)) == 0.25)
        #expect(RegistryWatcher.seconds(from: .seconds(2)) == 2)
    }

    @Test("Falls back to the nearest existing ancestor")
    func nearestAncestor() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let deep = dir
            .appendingPathComponent("never")
            .appendingPathComponent("created")
        #expect(RegistryWatcher.nearestExistingDirectory(from: deep) == dir.path)
        #expect(RegistryWatcher.nearestExistingDirectory(from: dir) == dir.path)
    }

    @Test("Starts and stops cleanly on an existing directory")
    func startStop() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watcher = RegistryWatcher(directory: dir)

        #expect(watcher.isWatching == false)
        // Hoisted out of #expect: the macro's decomposition drops @Sendable.
        let started = watcher.start(onChange: {})
        #expect(started)
        #expect(watcher.isWatching)
        #expect(watcher.effectiveWatchedPath != nil)

        watcher.stop()
        #expect(watcher.isWatching == false)
        watcher.stop()  // idempotent
        #expect(watcher.isWatching == false)
    }

    @Test("Starts even when the sessions directory does not exist yet")
    func startsWithoutDirectory() throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("sessions")

        let watcher = RegistryWatcher(directory: missing)
        let started = watcher.start(onChange: {})
        #expect(started)
        #expect(watcher.effectiveWatchedPath == dir.path)
        watcher.stop()
    }

    @Test("Delivers a debounced callback when the directory changes", .timeLimit(.minutes(1)))
    func firesOnChange() async throws {
        let dir = try Fixture.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let signal = Signal()
        let watcher = RegistryWatcher(directory: dir, debounce: .milliseconds(50))
        let started = watcher.start(onChange: { await signal.fire() })
        #expect(started)
        defer { watcher.stop() }

        // Let FSEvents attach before mutating.
        try await Task.sleep(for: .milliseconds(300))
        for i in 0..<5 {
            try Fixture.write(Fixture.realInteractive, named: "burst-\(i).json", into: dir)
        }

        #expect(await signal.wait(timeout: .seconds(10)))
        // The burst collapsed rather than firing once per write.
        let fires = await signal.count
        #expect(fires >= 1)
        #expect(fires <= 3)
    }
}

/// Minimal async signal for the watcher test.
private actor Signal {
    private var fired = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var count: Int { fired }

    func fire() {
        fired += 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func wait(timeout: Duration) async -> Bool {
        if fired > 0 { return true }
        let waited: Void? = await withTaskGroup(of: Void?.self) { group in
            group.addTask { [self] in
                await withCheckedContinuation { c in
                    Task { await self.enqueue(c) }
                }
                return ()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first: Void? = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        return waited != nil || fired > 0
    }

    private func enqueue(_ c: CheckedContinuation<Void, Never>) {
        if fired > 0 { c.resume(); return }
        waiters.append(c)
    }
}
