import Foundation
import Testing

@testable import ClaudenceCore

/// The live-only preference turns persistence off while the app runs, which
/// means one `ClaudenceStore` has to be able to point somewhere else without
/// the objects holding it being rebuilt. These tests are about the two ways
/// that goes wrong: a cursor left behind, and a write that still reaches the
/// file the user asked the app to stop using.
@Suite("Changing where the store writes")
struct StoreModeTests {

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceStoreMode", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSession(id: String, usage: TokenUsage) -> AISession {
        AISession(
            id: id,
            pid: 4242,
            procStart: "Tue Sep  1 19:27:02 2026",
            projectName: "Claudence",
            workingDirectory: "/Users/tester/project/Claudence",
            status: .running,
            startedAt: Date(),
            lastActivityAt: Date(),
            usage: usage
        )
    }

    /// The whole reason `reopen` exists rather than a swap of two stores. A
    /// database that answers "no cursor" sends `TranscriptReader` back to byte
    /// 0, and the engine then adds a transcript to an accumulator that already
    /// holds it: the double count stage 1 spent four commits removing, brought
    /// back by a preference.
    @Test("reopening carries every read cursor across")
    func reopenCarriesCursors() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))

        store.saveCursor(ReadCursor(path: "/a.jsonl", inode: 11, byteOffset: 4_096), forSession: "one")
        store.saveCursor(ReadCursor(path: "/b.jsonl", inode: 12, byteOffset: 8_192), forSession: "two")

        #expect(store.reopen(url: nil) == .healthy)

        #expect(store.cursor(forSession: "one") == ReadCursor(path: "/a.jsonl", inode: 11, byteOffset: 4_096))
        #expect(store.cursor(forSession: "two") == ReadCursor(path: "/b.jsonl", inode: 12, byteOffset: 8_192))
    }

    /// The same fact from the reader's end, which is where the cost would land.
    @Test("a transcript resumes rather than re-reading after the mode changes")
    func readerResumesAcrossReopen() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = directory.appendingPathComponent("projects", isDirectory: true)
        let workingDirectory = "/Users/tester/project/Claudence"
        let sessionID = UUID().uuidString.lowercased()
        let slug = TranscriptLocator.slug(forWorkingDirectory: workingDirectory)
        let sessionDirectory = projects.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let transcript = sessionDirectory.appendingPathComponent("\(sessionID).jsonl")

        func record(input: Int) -> String {
            """
            {"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"\(workingDirectory)",\
            "sessionId":"\(sessionID)","version":"2.1.257","type":"assistant",\
            "message":{"id":"msg_01Abc","type":"message","role":"assistant","model":"claude-sonnet-5",\
            "content":[{"type":"text","text":"ordinary response text"}],\
            "usage":{"input_tokens":\(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,\
            "output_tokens":10,"output_tokens_details":{"thinking_tokens":0},"service_tier":"standard"}},\
            "uuid":"\(UUID().uuidString.lowercased())","timestamp":"2026-09-03T07:39:02.837Z"}
            """
        }

        try Data((record(input: 100) + "\n").utf8).write(to: transcript)

        let store = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))
        let reader = TranscriptReader(
            cursorStore: store,
            locator: TranscriptLocator(projectsDirectory: projects)
        )
        let first = reader.readIncremental(sessionID: sessionID, workingDirectory: workingDirectory)
        #expect(first.usage.freshInput == 100)

        // The user turns the mode on mid-run.
        store.reopen(url: nil)

        // One new record arrives afterwards.
        if let handle = try? FileHandle(forWritingTo: transcript) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((record(input: 7) + "\n").utf8))
            try? handle.close()
        }

        let second = reader.readIncremental(sessionID: sessionID, workingDirectory: workingDirectory)
        // 7, not 107: the first record was already counted and must not arrive
        // a second time because the database underneath changed.
        #expect(second.usage.freshInput == 7)
        #expect(second.recordsParsed == 1)
    }

    /// The promise the setting makes. Once the store is in memory, the file the
    /// user asked it to stop using stops changing.
    @Test("nothing reaches the file after the store moves into memory")
    func fileStopsChangingAfterReopen() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("claudence.db")
        let store = ClaudenceStore(url: databaseURL)
        store.upsert(session: makeSession(id: "before", usage: TokenUsage(freshInput: 10, output: 1)))

        store.reopen(url: nil)
        let sizeAfterReopen = FileStatus(path: databaseURL.path)?.size

        store.upsert(session: makeSession(id: "after", usage: TokenUsage(freshInput: 999, output: 99)))
        store.recordUsageSample(sessionID: "after", usage: TokenUsage(freshInput: 999, output: 99), at: Date())

        #expect(FileStatus(path: databaseURL.path)?.size == sizeAfterReopen)

        // The in-memory database answers, so the interface keeps working.
        #expect(store.session(id: "after")?.usage.freshInput == 999)
        // And it starts empty: the rows written before the switch stayed on disk.
        #expect(store.session(id: "before") == nil)
    }

    /// Switching back has to be as safe as switching away, including finding
    /// the rows that were there before.
    @Test("reopening the file again restores what it held")
    func reopeningFileRestoresRows() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("claudence.db")
        let store = ClaudenceStore(url: databaseURL)
        store.upsert(session: makeSession(id: "kept", usage: TokenUsage(freshInput: 10, output: 1)))

        store.reopen(url: nil)
        #expect(store.session(id: "kept") == nil)

        #expect(store.reopen(url: databaseURL) == .healthy)
        #expect(store.session(id: "kept")?.usage.freshInput == 10)
    }

    @Test("the stored data summary counts what is really there")
    func summaryCountsRows() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("claudence.db")
        let store = ClaudenceStore(url: databaseURL)
        #expect(store.storedDataSummary().isEmpty)

        store.upsert(session: makeSession(id: "one", usage: TokenUsage(freshInput: 10, output: 1)))
        store.recordUsageSample(sessionID: "one", usage: TokenUsage(freshInput: 10, output: 1), at: Date())
        store.saveCursor(ReadCursor(path: "/a.jsonl", inode: 11, byteOffset: 4_096), forSession: "one")

        let summary = store.storedDataSummary()
        #expect(summary.sessions == 1)
        #expect(summary.usageSamples == 1)
        #expect(summary.rollupDays == 1)
        #expect(summary.fileURL == databaseURL)
        #expect((summary.fileSizeBytes ?? 0) > 0)
        #expect(!summary.isEmpty)
    }

    /// Deleting takes the cursors with the rows. Keeping a cursor at byte N
    /// beside a total of zero is the undercount this codebase already shipped
    /// once, and a delete button is no place to reintroduce it.
    @Test("deleting stored data empties every table, cursors included")
    func deleteEmptiesEverything() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))
        store.upsert(session: makeSession(id: "one", usage: TokenUsage(freshInput: 10, output: 1)))
        store.recordUsageSample(sessionID: "one", usage: TokenUsage(freshInput: 10, output: 1), at: Date())
        store.saveCursor(ReadCursor(path: "/a.jsonl", inode: 11, byteOffset: 4_096), forSession: "one")

        store.deleteStoredData()

        #expect(store.storedDataSummary().isEmpty)
        #expect(store.session(id: "one") == nil)
        #expect(store.cursor(forSession: "one") == nil)
        #expect(store.allCursors().isEmpty)
        #expect(store.dailyTotals(days: 7).isEmpty)
    }

    @Test("removing the stored file takes its write-ahead siblings with it")
    func removingFileTakesSiblings() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("claudence.db")
        let store = ClaudenceStore(url: databaseURL)
        store.upsert(session: makeSession(id: "one", usage: TokenUsage(freshInput: 10, output: 1)))
        store.reopen(url: nil)

        #expect(ClaudenceStore.removeStoredFile(at: databaseURL).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path + "-shm"))
    }
}
