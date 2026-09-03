import CryptoKit
import Foundation
import Testing

@testable import ClaudenceCore

// MARK: - Fixture

/// A throwaway `~/.claude/projects` tree in a temp directory. Tests never read
/// the real `~/.claude`.
final class TranscriptFixture {
    let root: URL
    let projectsDirectory: URL
    let sessionID: String
    let workingDirectory: String
    let transcript: URL

    init(
        sessionID: String = UUID().uuidString.lowercased(),
        workingDirectory: String = "/Users/tester/TungAo-Project/project/Claudence",
        createFile: Bool = true
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudence-transcript-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        projectsDirectory = root.appendingPathComponent("projects", isDirectory: true)
        let projectDirectory = projectsDirectory.appendingPathComponent(
            TranscriptLocator.slug(forWorkingDirectory: workingDirectory),
            isDirectory: true
        )
        try? FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        transcript = projectDirectory.appendingPathComponent("\(self.sessionID).jsonl")
        if createFile {
            FileManager.default.createFile(atPath: transcript.path, contents: Data())
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Writing

    func append(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: transcript) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    /// Appends whole lines, each newline-terminated.
    func appendLines(_ lines: [String]) {
        append(lines.map { $0 + "\n" }.joined())
    }

    func write(_ text: String) {
        try? Data(text.utf8).write(to: transcript)
    }

    /// Deletes and recreates the file, which yields a new inode.
    func rotate(withLines lines: [String]) {
        try? FileManager.default.removeItem(at: transcript)
        FileManager.default.createFile(atPath: transcript.path, contents: Data())
        appendLines(lines)
    }

    var inode: UInt64 { FileStatus(path: transcript.path)?.inode ?? 0 }
    var size: UInt64 { FileStatus(path: transcript.path)?.size ?? 0 }

    // MARK: Reader

    func makeReader(store: CursorStoring) -> TranscriptReader {
        TranscriptReader(
            cursorStore: store,
            locator: TranscriptLocator(projectsDirectory: projectsDirectory)
        )
    }

    func read(with reader: TranscriptReader) -> TranscriptDelta {
        reader.readIncremental(sessionID: sessionID, workingDirectory: workingDirectory)
    }

    // MARK: Records

    /// A record shaped like a real Claude Code 2.1.257 `assistant` line,
    /// extra keys included, so the decoder is exercised against real noise.
    func assistantRecord(
        timestamp: String = "2026-08-18T07:39:02.837Z",
        model: String = "claude-sonnet-5",
        input: Int = 2,
        cacheCreation: Int = 22_018,
        cacheRead: Int = 24_858,
        output: Int = 147,
        thinking: Int = 16,
        content: String = #"[{"type":"text","text":"ordinary response text"}]"#
    ) -> String {
        """
        {"parentUuid":"\(UUID().uuidString.lowercased())","isSidechain":false,"userType":"external",\
        "cwd":"\(workingDirectory)","sessionId":"\(sessionID)","version":"2.1.257","gitBranch":"main",\
        "slug":"a-slug","entrypoint":"cli","requestId":"req_011CV","type":"assistant",\
        "message":{"id":"msg_01Abc","type":"message","role":"assistant","model":"\(model)",\
        "content":\(content),"stop_reason":"tool_use","stop_sequence":null,\
        "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreation),\
        "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),\
        "output_tokens_details":{"thinking_tokens":\(thinking)},\
        "cache_creation":{"ephemeral_5m_input_tokens":\(cacheCreation),"ephemeral_1h_input_tokens":0},\
        "server_tool_use":{"web_search_requests":0},"service_tier":"standard","speed":"fast",\
        "iterations":[{"index":0}]}},\
        "uuid":"\(UUID().uuidString.lowercased())","timestamp":"\(timestamp)"}
        """
    }

    static func toolUse(_ name: String, filePath: String? = nil, command: String? = nil) -> String {
        var input: [String] = []
        if let filePath { input.append("\"file_path\":\"\(filePath)\"") }
        if let command { input.append("\"command\":\"\(command)\"") }
        return """
        {"type":"tool_use","id":"toolu_\(UUID().uuidString.prefix(8))","name":"\(name)",\
        "input":{\(input.joined(separator: ","))}}
        """
    }
}

// MARK: - Token extraction

@Suite("Transcript reader")
struct TranscriptTests {

    @Test("Extracts token counts from a real-shaped assistant record")
    func tokenExtraction() {
        let fixture = TranscriptFixture()
        fixture.appendLines([fixture.assistantRecord()])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        #expect(delta.usage.freshInput == 2)
        #expect(delta.usage.cacheCreation == 22_018)
        #expect(delta.usage.cacheRead == 24_858)
        #expect(delta.usage.output == 147)
        #expect(delta.usage.thinking == 16)
        // Totals come from TokenUsage, never recomputed locally.
        #expect(delta.usage.billableInput == 2 + 22_018 + 24_858)
        #expect(delta.usage.total == 2 + 22_018 + 24_858 + 147)
        #expect(delta.latestModel == "claude-sonnet-5")
        #expect(delta.recordsParsed == 1)
        #expect(delta.recordsSkipped == 0)
    }

    @Test("Aggregates multiple assistant records")
    func multipleRecordsAggregate() {
        let fixture = TranscriptFixture()
        fixture.appendLines([
            fixture.assistantRecord(input: 1, cacheCreation: 10, cacheRead: 100, output: 5, thinking: 2),
            fixture.assistantRecord(input: 3, cacheCreation: 20, cacheRead: 200, output: 7, thinking: 4),
            fixture.assistantRecord(
                model: "claude-opus-5",
                input: 5, cacheCreation: 30, cacheRead: 300, output: 9, thinking: 6
            ),
        ])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        #expect(delta.usage == TokenUsage(
            freshInput: 9, cacheCreation: 60, cacheRead: 600, output: 21, thinking: 12
        ))
        #expect(delta.usage.total == 9 + 60 + 600 + 21)
        #expect(delta.recordsParsed == 3)
        // Latest model wins.
        #expect(delta.latestModel == "claude-opus-5")
    }

    @Test("A session that used two models splits between them, and the split sums to the session total")
    func usageByModelSplitsAndSumsToTotal() {
        let fixture = TranscriptFixture()
        fixture.appendLines([
            fixture.assistantRecord(input: 1, cacheCreation: 10, cacheRead: 100, output: 5, thinking: 2),
            fixture.assistantRecord(input: 3, cacheCreation: 20, cacheRead: 200, output: 7, thinking: 4),
            fixture.assistantRecord(
                model: "claude-opus-5",
                input: 5, cacheCreation: 30, cacheRead: 300, output: 9, thinking: 6
            ),
        ])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        #expect(delta.usageByModel["claude-sonnet-5"] == TokenUsage(
            freshInput: 4, cacheCreation: 30, cacheRead: 300, output: 12, thinking: 6
        ))
        #expect(delta.usageByModel["claude-opus-5"] == TokenUsage(
            freshInput: 5, cacheCreation: 30, cacheRead: 300, output: 9, thinking: 6
        ))
        // Two buckets, no third. Never computed independently of `usage`.
        #expect(delta.usageByModel.count == 2)
        let summed = delta.usageByModel.values.reduce(TokenUsage.zero, +)
        #expect(summed == delta.usage)
    }

    @Test("A record with no model is counted under the unknown bucket, and the total still reconciles")
    func usageByModelCountsMissingModelAsUnknown() {
        let fixture = TranscriptFixture()
        fixture.appendLines([
            fixture.assistantRecord(model: "claude-sonnet-5", input: 1, cacheCreation: 0, cacheRead: 0, output: 2, thinking: 0),
            // An empty `model` field is the closest a real record gets to
            // absent: the JSON key is always present in a real transcript,
            // but its value can be empty on malformed or very old lines.
            fixture.assistantRecord(model: "", input: 9, cacheCreation: 0, cacheRead: 0, output: 3, thinking: 0),
        ])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        #expect(delta.usageByModel["claude-sonnet-5"] == TokenUsage(freshInput: 1, output: 2))
        #expect(delta.usageByModel[ModelAttribution.unknown] == TokenUsage(freshInput: 9, output: 3))
        let summed = delta.usageByModel.values.reduce(TokenUsage.zero, +)
        #expect(summed == delta.usage)
        #expect(delta.usage == TokenUsage(freshInput: 10, output: 5))
    }

    // MARK: - Incremental tailing

    @Test("A second read after appending returns only the new tokens")
    func secondReadReturnsOnlyNewTokens() {
        let fixture = TranscriptFixture()
        let store = TranscriptMemoryCursorStore()
        let reader = fixture.makeReader(store: store)

        fixture.appendLines([fixture.assistantRecord(input: 100, cacheCreation: 0, cacheRead: 0, output: 10, thinking: 0)])
        let first = fixture.read(with: reader)
        #expect(first.usage.total == 110)
        #expect(first.recordsParsed == 1)

        let afterFirst = store.cursor(forSession: fixture.sessionID)
        #expect(afterFirst?.byteOffset == fixture.size)
        #expect(afterFirst?.inode == fixture.inode)

        // No new bytes at all.
        let idle = fixture.read(with: reader)
        #expect(idle == .empty)

        fixture.appendLines([fixture.assistantRecord(input: 7, cacheCreation: 0, cacheRead: 0, output: 3, thinking: 0)])
        let second = fixture.read(with: reader)

        #expect(second.usage.total == 10)
        #expect(second.usage.freshInput == 7)
        #expect(second.recordsParsed == 1)
        #expect(store.cursor(forSession: fixture.sessionID)?.byteOffset == fixture.size)
    }

    @Test("A changed inode resets the offset and the file is re-read from zero")
    func inodeChangeResetsOffset() {
        let fixture = TranscriptFixture()
        let store = TranscriptMemoryCursorStore()
        let reader = fixture.makeReader(store: store)

        fixture.appendLines([fixture.assistantRecord(input: 50, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0)])
        _ = fixture.read(with: reader)
        let firstInode = store.cursor(forSession: fixture.sessionID)?.inode

        fixture.rotate(withLines: [
            fixture.assistantRecord(input: 11, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
            fixture.assistantRecord(input: 22, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
        ])
        #expect(fixture.inode != firstInode)

        let delta = fixture.read(with: reader)

        // Both records of the rotated file, not just the tail past the old offset.
        #expect(delta.usage.freshInput == 33)
        #expect(delta.recordsParsed == 2)
        #expect(store.cursor(forSession: fixture.sessionID)?.inode == fixture.inode)
        #expect(store.cursor(forSession: fixture.sessionID)?.byteOffset == fixture.size)
    }

    @Test("A truncated file restarts at zero")
    func truncationRestartsAtZero() {
        let fixture = TranscriptFixture()
        let store = TranscriptMemoryCursorStore()
        let reader = fixture.makeReader(store: store)

        fixture.appendLines([
            fixture.assistantRecord(input: 5, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
            fixture.assistantRecord(input: 5, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
        ])
        _ = fixture.read(with: reader)

        // Same inode, smaller file.
        fixture.write(fixture.assistantRecord(input: 1, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0) + "\n")
        let delta = fixture.read(with: reader)

        #expect(delta.usage.freshInput == 1)
        #expect(delta.recordsParsed == 1)
    }

    @Test("A partial trailing line is not consumed and is picked up once complete")
    func partialTrailingLineIsNotConsumed() {
        let fixture = TranscriptFixture()
        let store = TranscriptMemoryCursorStore()
        let reader = fixture.makeReader(store: store)

        let complete = fixture.assistantRecord(input: 4, cacheCreation: 0, cacheRead: 0, output: 1, thinking: 0)
        let pending = fixture.assistantRecord(input: 9, cacheCreation: 0, cacheRead: 0, output: 2, thinking: 0)
        let split = pending.index(pending.startIndex, offsetBy: pending.count / 2)

        fixture.appendLines([complete])
        fixture.append(String(pending[..<split]))  // write in progress, no newline

        let first = fixture.read(with: reader)
        #expect(first.usage.total == 5)
        #expect(first.recordsParsed == 1)
        #expect(first.recordsSkipped == 0)

        let offset = store.cursor(forSession: fixture.sessionID)?.byteOffset ?? 0
        #expect(offset == UInt64(complete.utf8.count + 1))
        #expect(offset < fixture.size)

        // The writer finishes the line.
        fixture.append(String(pending[split...]) + "\n")
        let second = fixture.read(with: reader)

        #expect(second.usage.total == 11)
        #expect(second.recordsParsed == 1)
        #expect(second.recordsSkipped == 0)
        #expect(store.cursor(forSession: fixture.sessionID)?.byteOffset == fixture.size)
    }

    // MARK: - Robustness

    @Test("Malformed lines are skipped and counted, never fatal")
    func malformedLinesAreSkipped() {
        let fixture = TranscriptFixture()
        fixture.appendLines([
            fixture.assistantRecord(input: 1, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
            "{ this is not json",
            "",
            "\u{0}\u{1}garbage",
            #"{"type":"assistant","message":"not an object"}"#,
            fixture.assistantRecord(input: 2, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
        ])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        #expect(delta.usage.freshInput == 3)
        #expect(delta.recordsSkipped == 2)
        // The `message` string record still classifies as assistant and decodes,
        // it just carries no usage.
        #expect(delta.recordsParsed == 3)
    }

    @Test("Non-assistant record types contribute nothing")
    func nonAssistantRecordsContributeNothing() {
        let fixture = TranscriptFixture()
        fixture.appendLines([
            #"{"type":"user","sessionId":"x","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"toolUseResult":{"stdout":"output"}}"#,
            #"{"type":"system","subtype":"local_command","content":"ran something"}"#,
            #"{"type":"attachment","attachment":{"type":"file","content":"file body"}}"#,
            #"{"type":"mode","mode":"default"}"#,
            #"{"type":"permission-mode","permissionMode":"acceptEdits"}"#,
            #"{"type":"last-prompt","lastPrompt":"a prompt"}"#,
            #"{"type":"ai-title","aiTitle":"A title"}"#,
            #"{"type":"file-history-snapshot","snapshot":{"trackedFileBackups":{"a.swift":"body"}}}"#,
            #"{"type":"file-history-delta","backup":{"patch":"@@ -1 +1 @@"}}"#,
            #"{"type":"queue-operation","operation":"add"}"#,
        ])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        #expect(delta.usage == .zero)
        #expect(delta.latestActivity == nil)
        #expect(delta.latestModel == nil)
        #expect(delta.latestTimestamp == nil)
        #expect(delta.recordsParsed == 0)
        #expect(delta.recordsSkipped == 0)
    }

    @Test("A missing transcript yields an empty delta")
    func missingFileYieldsEmpty() {
        let fixture = TranscriptFixture(createFile: false)
        let reader = fixture.makeReader(store: TranscriptMemoryCursorStore())
        #expect(fixture.read(with: reader) == .empty)
        // And an unknown session in an existing tree.
        #expect(reader.readIncremental(sessionID: "no-such-session", workingDirectory: fixture.workingDirectory) == .empty)
    }

    // MARK: - Timestamps

    @Test("ISO8601 with fractional seconds parses")
    func fractionalSecondsTimestamp() {
        let fixture = TranscriptFixture()
        fixture.appendLines([fixture.assistantRecord(timestamp: "2026-08-18T07:39:02.837Z")])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 18
        components.hour = 7; components.minute = 39; components.second = 2
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let expected = calendar.date(from: components)!.addingTimeInterval(0.837)

        let parsed = try! #require(delta.latestTimestamp)
        #expect(abs(parsed.timeIntervalSince(expected)) < 0.002)
    }

    @Test("ISO8601 without fractional seconds still parses")
    func wholeSecondsTimestamp() {
        #expect(TranscriptTimestamp.parse("2026-08-18T07:39:02Z") != nil)
        #expect(TranscriptTimestamp.parse("2026-08-18T07:39:02.837Z") != nil)
        #expect(TranscriptTimestamp.parse("not a date") == nil)
        #expect(TranscriptTimestamp.parse(nil) == nil)
    }

    // MARK: - Activity

    @Test("The delta reports the last tool use of the newly read records")
    func activityIsLastToolUse() {
        let fixture = TranscriptFixture()
        fixture.appendLines([
            fixture.assistantRecord(content: "[\(TranscriptFixture.toolUse("Read", filePath: "/a/b/package.json"))]"),
            fixture.assistantRecord(content: """
            [{"type":"text","text":"some prose"},\
            \(TranscriptFixture.toolUse("Grep")),\
            \(TranscriptFixture.toolUse("Edit", filePath: "/repo/Sources/UI/Menu.tsx"))]
            """),
        ])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        #expect(delta.latestActivity == Activity(verb: ActivityMapper.Verb.editing, subject: .untranslated("Menu.tsx")))
        #expect(delta.latestActivity?.display == "Editing Menu.tsx")
    }

    @Test("The delta carries the git branch of the newest record that names one")
    func gitBranchIsCarried() {
        let fixture = TranscriptFixture()
        fixture.appendLines([fixture.assistantRecord()])

        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        // The field was decoded and then dropped on the floor for three
        // milestones, so the session row rendered a path where the design shows
        // `path · branch`. It is on the allowlist: a branch name is a label the
        // tool wrote, not content a person or a model produced.
        #expect(delta.gitBranch == "main")
    }

    @Test("Tool names map to human phrasing")
    func activityMapping() {
        #expect(ActivityMapper.activity(toolName: "Read", filePath: "/x/y/package.json")
            == Activity(verb: ActivityMapper.Verb.reading, subject: .untranslated("package.json")))
        #expect(ActivityMapper.activity(toolName: "Edit", filePath: "/x/src/Menu.tsx")
            == Activity(verb: ActivityMapper.Verb.editing, subject: .untranslated("Menu.tsx")))
        #expect(ActivityMapper.activity(toolName: "Write", filePath: "/x/src/New.swift")
            == Activity(verb: ActivityMapper.Verb.editing, subject: .untranslated("New.swift")))
        #expect(ActivityMapper.activity(toolName: "Grep") == Activity(verb: ActivityMapper.Verb.searching, subject: ActivityMapper.Subject.codebase))
        #expect(ActivityMapper.activity(toolName: "Glob") == Activity(verb: ActivityMapper.Verb.searching, subject: ActivityMapper.Subject.codebase))
        #expect(ActivityMapper.activity(toolName: "Bash") == Activity(verb: ActivityMapper.Verb.running, subject: ActivityMapper.Subject.command))
        #expect(ActivityMapper.activity(toolName: "WebFetch") == Activity(verb: ActivityMapper.Verb.searching, subject: ActivityMapper.Subject.web))
        #expect(ActivityMapper.activity(toolName: "WebSearch") == Activity(verb: ActivityMapper.Verb.searching, subject: ActivityMapper.Subject.web))
        #expect(ActivityMapper.activity(toolName: "Task") == Activity(verb: ActivityMapper.Verb.running, subject: ActivityMapper.Subject.subagent))
        #expect(ActivityMapper.activity(toolName: "TodoWrite") == Activity(verb: ActivityMapper.Verb.planning, subject: nil))
        #expect(ActivityMapper.activity(toolName: "TodoWrite").display == "Planning")
        #expect(ActivityMapper.activity(toolName: "SomeFutureTool") == Activity(verb: ActivityMapper.Verb.running, subject: .untranslated("SomeFutureTool")))
        // A file path is reduced to its basename.
        #expect(ActivityMapper.activity(toolName: "Read", filePath: "a.txt")
            == Activity(verb: ActivityMapper.Verb.reading, subject: .untranslated("a.txt")))
        #expect(ActivityMapper.activity(toolName: "Read", filePath: nil).subject == nil)
    }

    // MARK: - Location

    @Test("The locator falls back to scanning when the slug does not round-trip")
    func locatorFallsBackToScan() {
        // The session's cwd derives one slug; the file actually lives under another.
        let fixture = TranscriptFixture(workingDirectory: "/Users/tester/odd.dir/project")
        fixture.appendLines([fixture.assistantRecord(input: 12, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0)])

        let elsewhere = fixture.projectsDirectory.appendingPathComponent("-Users-tester-odd-dir-project", isDirectory: true)
        try! FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = elsewhere.appendingPathComponent("\(fixture.sessionID).jsonl")
        try! FileManager.default.moveItem(at: fixture.transcript, to: moved)

        let locator = TranscriptLocator(projectsDirectory: fixture.projectsDirectory)
        let located = locator.locate(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        // /var is a symlink to /private/var on macOS, so compare resolved paths.
        #expect(located?.resolvingSymlinksInPath() == moved.resolvingSymlinksInPath())

        let reader = TranscriptReader(cursorStore: TranscriptMemoryCursorStore(), locator: locator)
        let delta = reader.readIncremental(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory)
        #expect(delta.usage.freshInput == 12)
    }

    @Test("The slug is the working directory with slashes replaced")
    func slugDerivation() {
        #expect(TranscriptLocator.slug(forWorkingDirectory: "/Users/tungao/TungAo-Project/project/Claudence")
            == "-Users-tungao-TungAo-Project-project-Claudence")
    }

    @Test("A file naming a different session is rejected")
    func contradictedSessionIsRejected() {
        let fixture = TranscriptFixture()
        // Write records that belong to some other session entirely.
        let other = TranscriptFixture(sessionID: "11111111-2222-3333-4444-555555555555")
        fixture.write(other.assistantRecord() + "\n")

        let locator = TranscriptLocator(projectsDirectory: fixture.projectsDirectory)
        #expect(locator.locate(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory) == nil)
    }

    // MARK: - Performance

    @Test("Re-scanning a 12 MB transcript with no new bytes stays under 50 ms")
    func rescanIsCheapWhenNothingWasAppended() {
        let fixture = TranscriptFixture()
        let store = TranscriptMemoryCursorStore()
        let reader = fixture.makeReader(store: store)

        // ~12 MB of realistic records: a long text block plus a tool use.
        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 150)
        var bytes = 0
        var batch: [String] = []
        while bytes < 12 * 1024 * 1024 {
            let record = fixture.assistantRecord(
                input: 1, cacheCreation: 2, cacheRead: 3, output: 4, thinking: 1,
                content: """
                [{"type":"text","text":"\(filler)"},\
                \(TranscriptFixture.toolUse("Read", filePath: "/repo/Sources/App/Main.swift"))]
                """
            )
            batch.append(record)
            bytes += record.utf8.count + 1
            if batch.count == 200 {
                fixture.appendLines(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        fixture.appendLines(batch)
        #expect(fixture.size > 12 * 1024 * 1024)

        let coldStart = Date()
        let cold = fixture.read(with: reader)
        let coldElapsed = Date().timeIntervalSince(coldStart)
        #expect(cold.recordsParsed > 0)
        #expect(store.cursor(forSession: fixture.sessionID)?.byteOffset == fixture.size)

        // The re-scan must not read the file at all: a stat decides it.
        var worst: TimeInterval = 0
        for _ in 0..<5 {
            let start = Date()
            let delta = fixture.read(with: reader)
            worst = max(worst, Date().timeIntervalSince(start))
            #expect(delta == .empty)
        }

        print("""
        [perf] transcript \(fixture.size) bytes, \(cold.recordsParsed) records: \
        cold read \(Int(coldElapsed * 1000)) ms, idle re-scan \(String(format: "%.3f", worst * 1000)) ms
        """)
        #expect(worst < 0.050)
    }

    @Test("Re-scanning the largest transcript actually seen on this machine (19.9 MB) still stays under 50 ms")
    func rescanIsCheapAtTheRealWorstCaseSize() {
        // 9.12: the 12 MB fixture above was picked before anyone measured the
        // real corpus. `find ~/.claude/projects -name '*.jsonl' | xargs ls -la`
        // on this machine turned up a 19.9 MB transcript, so that is the number
        // the budget has to hold against, not the fixture's own.
        let fixture = TranscriptFixture()
        let store = TranscriptMemoryCursorStore()
        let reader = fixture.makeReader(store: store)

        let filler = String(repeating: "lorem ipsum dolor sit amet ", count: 150)
        var bytes = 0
        var batch: [String] = []
        let target = 20 * 1024 * 1024 - Int(0.1 * 1024 * 1024)  // ~19.9 MB
        while bytes < target {
            let record = fixture.assistantRecord(
                input: 1, cacheCreation: 2, cacheRead: 3, output: 4, thinking: 1,
                content: """
                [{"type":"text","text":"\(filler)"},\
                \(TranscriptFixture.toolUse("Read", filePath: "/repo/Sources/App/Main.swift"))]
                """
            )
            batch.append(record)
            bytes += record.utf8.count + 1
            if batch.count == 200 {
                fixture.appendLines(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        fixture.appendLines(batch)
        #expect(fixture.size > UInt64(target))

        let coldStart = Date()
        let cold = fixture.read(with: reader)
        let coldElapsed = Date().timeIntervalSince(coldStart)
        #expect(cold.recordsParsed > 0)

        // Cold parse cost is not the budget under test -- it happens once, in
        // `HistoryImporter`, off any hot path -- but it is worth a number
        // rather than a shrug, since it is new work this milestone adds.
        print("""
        [perf] 19.9 MB cold import-style parse: \(cold.recordsParsed) records in \
        \(Int(coldElapsed * 1000)) ms
        """)

        // The budget this line actually enforces: once a transcript has been
        // read to the end, noticing that nothing new arrived costs one `stat`
        // and never opens the file. That is independent of file size by
        // construction, so the real 19.9 MB file has to hold the same 50 ms
        // line the 12 MB fixture does -- reported honestly below rather than
        // widened to fit if it did not.
        var worst: TimeInterval = 0
        for _ in 0..<5 {
            let start = Date()
            let delta = fixture.read(with: reader)
            worst = max(worst, Date().timeIntervalSince(start))
            #expect(delta == .empty)
        }

        print("""
        [perf] 19.9 MB transcript \(fixture.size) bytes, \(cold.recordsParsed) records: \
        idle re-scan \(String(format: "%.3f", worst * 1000)) ms (budget 50 ms, \
        \(worst < 0.050 ? "within budget" : "OVER BUDGET"))
        """)
        #expect(worst < 0.050)
    }
}

// MARK: - The cursor read itself

/// A cursor store whose read fails on demand, with health pinned at
/// `.degraded` the way an earlier unrelated failure leaves it. That is the
/// condition a health transition cannot see through, so only the store's count
/// of unanswered queries separates a failed read from an absent cursor.
private final class FailingCursorStore: CursorStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cursors: [String: ReadCursor] = [:]
    private var _failingKeys: Set<String> = []
    private var _unanswered: UInt64 = 0
    private var _saves = 0

    var failingKeys: Set<String> {
        get {
            lock.lock(); defer { lock.unlock() }
            return _failingKeys
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _failingKeys = newValue
        }
    }

    /// How many cursors were written. A pass that opened no file writes none.
    var saves: Int {
        lock.lock(); defer { lock.unlock() }
        return _saves
    }

    /// The stored cursor whether or not reads are failing, so a test can see
    /// that a skipped pass left the offset exactly where it was.
    func stored(_ key: String) -> ReadCursor? {
        lock.lock(); defer { lock.unlock() }
        return cursors[key]
    }

    var health: StoreHealth { .degraded(reason: "an earlier unrelated failure") }

    var unansweredQueries: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _unanswered
    }

    func cursor(forSession sessionID: String) -> ReadCursor? {
        lock.lock()
        let failing = _failingKeys.contains(sessionID)
        if failing { _unanswered &+= 1 }
        let stored = cursors[sessionID]
        lock.unlock()
        // A failed read and a key never written return the same nil, exactly
        // as in the real store.
        return failing ? nil : stored
    }

    func saveCursor(_ cursor: ReadCursor, forSession sessionID: String) {
        lock.lock(); defer { lock.unlock() }
        cursors[sessionID] = cursor
        _saves += 1
    }
}

@Suite("A cursor read that does not answer")
struct CursorOutcomeTests {

    @Test("Nothing is read, parsed, or persisted, and the next pass resumes")
    func failedCursorReadReadsNothing() {
        let fixture = TranscriptFixture()
        let store = FailingCursorStore()
        let reader = fixture.makeReader(store: store)

        fixture.appendLines([
            fixture.assistantRecord(input: 50, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0)
        ])
        let first = fixture.read(with: reader)
        #expect(first.outcome == .read)
        #expect(first.usage.freshInput == 50)
        let offset = store.stored(fixture.sessionID)?.byteOffset
        let savesAfterFirst = store.saves
        #expect((offset ?? 0) > 0)

        fixture.appendLines([
            fixture.assistantRecord(input: 7, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0)
        ])
        store.failingKeys = [fixture.sessionID]
        let blocked = fixture.read(with: reader)

        // Not `.empty`: an empty delta is a real reading of a file that has not
        // grown, and this one is a refusal to take a reading at all.
        #expect(blocked == .cursorUnavailable)
        #expect(blocked.outcome == .cursorUnavailable)
        #expect(blocked.usage == .zero)
        #expect(blocked.recordsParsed == 0)
        // The file was never opened, so no cursor was written and the offset is
        // exactly where the answering pass left it.
        #expect(store.saves == savesAfterFirst)
        #expect(store.stored(fixture.sessionID)?.byteOffset == offset)

        store.failingKeys = []
        let resumed = fixture.read(with: reader)

        // The appended record alone. Starting at zero would report 57 here and
        // hand the caller a total it has already counted.
        #expect(resumed.outcome == .read)
        #expect(resumed.usage.freshInput == 7)
        #expect(resumed.recordsParsed == 1)
        #expect(store.stored(fixture.sessionID)?.byteOffset == fixture.size)
    }

    @Test("A rotation after a skipped pass still restarts at zero")
    func rotationAfterSkippedPassStillResetsOffset() {
        let fixture = TranscriptFixture()
        let store = FailingCursorStore()
        let reader = fixture.makeReader(store: store)

        fixture.appendLines([
            fixture.assistantRecord(input: 50, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0)
        ])
        _ = fixture.read(with: reader)
        let firstInode = store.stored(fixture.sessionID)?.inode

        // One pass that could not read the cursor, then the file rotates. The
        // skip must not have taught the reader to distrust a real answer: a
        // changed inode is still a rotation and still restarts at zero.
        store.failingKeys = [fixture.sessionID]
        #expect(fixture.read(with: reader).outcome == .cursorUnavailable)
        store.failingKeys = []

        fixture.rotate(withLines: [
            fixture.assistantRecord(input: 11, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
            fixture.assistantRecord(input: 22, cacheCreation: 0, cacheRead: 0, output: 0, thinking: 0),
        ])
        #expect(fixture.inode != firstInode)

        let delta = fixture.read(with: reader)

        // Both records of the rotated file, not the tail past the old offset.
        #expect(delta.outcome == .read)
        #expect(delta.usage.freshInput == 33)
        #expect(delta.recordsParsed == 2)
        #expect(store.stored(fixture.sessionID)?.inode == fixture.inode)
        #expect(store.stored(fixture.sessionID)?.byteOffset == fixture.size)
    }
}
