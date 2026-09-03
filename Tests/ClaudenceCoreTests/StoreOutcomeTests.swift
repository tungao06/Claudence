import Foundation
import Testing

@testable import ClaudenceCore

/// Whether a read answered is the signal three separate callers rest on: the
/// engine's seed, the subagent tracker's seed, and every analytics figure that
/// would otherwise print a failed read as a zero. The question this suite asks
/// is whether one caller can be told the wrong thing because another caller's
/// query failed at the same moment.
@Suite("Reads report their own outcome")
struct StoreOutcomeTests {

    /// The store-wide counter is shared, so a failing query on any thread used
    /// to land between another thread's two reads and turn an answered read
    /// into an unanswered one. In the engine that costs a skipped pass; in
    /// analytics it prints `Usage unavailable` over a figure the store
    /// returned. The per-thread count cannot be reached by another thread's
    /// failure at all.
    @Test("a failure on another thread never makes an answered read look unanswered")
    func concurrentFailureDoesNotPoisonAnotherThreadsRead() async throws {
        let store = ClaudenceStore(url: nil)
        // One table is removed so a specific query fails while the rest of the
        // store keeps answering, which is what a single bad statement looks
        // like from outside.
        try #require(store.connection != nil)
        try store.connection?.execute("DROP TABLE subagent_totals", [])

        let session = AISession(
            id: "one",
            pid: 4242,
            procStart: "Tue Sep  1 19:27:02 2026",
            projectName: "Claudence",
            workingDirectory: "/Users/tester/project/Claudence",
            status: .running,
            startedAt: Date(),
            lastActivityAt: Date(),
            usage: TokenUsage(freshInput: 10, output: 1)
        )
        store.upsert(session: session)

        // A background thread failing continuously for the whole test.
        let keepFailing = ManagedAtomicFlag()
        let failing = Thread {
            while keepFailing.isSet {
                _ = store.subagentTotals(forSession: "one")
            }
        }
        failing.start()
        defer { keepFailing.clear() }

        // The foreground reads, bracketed exactly as the engine and the
        // analytics layer bracket theirs.
        var misreported = 0
        for _ in 0..<500 {
            let before = store.unansweredQueriesOnThisThread
            let total = store.dailyTotals(days: 1)
            let answered = store.unansweredQueriesOnThisThread == before
            if !total.isEmpty && !answered { misreported += 1 }
        }
        keepFailing.clear()

        #expect(misreported == 0)
        // The store-wide count still sees the failures, which is what a
        // diagnostic report is for.
        #expect(store.unansweredQueries > 0)
    }

    /// The other half: a failure on this thread must still be reported, or the
    /// per-thread count would have made every read look answered and defeated
    /// the whole mechanism.
    @Test("a failure on this thread is still reported to the caller that made it")
    func ownFailureIsReported() throws {
        let store = ClaudenceStore(url: nil)
        try #require(store.connection != nil)
        try store.connection?.execute("DROP TABLE subagent_totals", [])

        let before = store.unansweredQueriesOnThisThread
        _ = store.subagentTotals(forSession: "one")
        #expect(store.unansweredQueriesOnThisThread > before)
    }
}

/// A flag two threads can share without importing an atomics package.
private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        value = false
    }
}
