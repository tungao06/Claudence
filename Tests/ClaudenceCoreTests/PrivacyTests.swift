import CryptoKit
import Foundation
import Testing

@testable import ClaudenceCore

/// The privacy contract of spec section 3.1 is enforced here, not by discipline.
/// Every test in this suite fails if the transcript pipeline ever carries
/// prompt text, response text, thinking, a tool result, a file-history payload,
/// an attachment payload, or a raw command string.
@Suite("Privacy contract")
struct PrivacyTests {

    // Distinctive strings that exist nowhere else in the codebase.
    static let promptText = "SENTINEL-PROMPT-TEXT-7f3a91c4"
    static let responseText = "SENTINEL-RESPONSE-TEXT-2b6e40da"
    static let thinkingText = "SENTINEL-THINKING-TEXT-91cc07be"
    static let toolResultText = "SENTINEL-TOOL-RESULT-5d1fa8e2"
    static let attachmentText = "SENTINEL-ATTACHMENT-c0de4417"
    static let snapshotText = "SENTINEL-FILE-HISTORY-a7b2ee39"
    static let command = "export AWS_SECRET_ACCESS_KEY=SENTINEL-COMMAND-3e8d5b17 && npm run deploy"

    static var allSentinels: [String] {
        [promptText, responseText, thinkingText, toolResultText, attachmentText, snapshotText, command,
         "SENTINEL-COMMAND-3e8d5b17", "AWS_SECRET_ACCESS_KEY"]
    }

    /// Expected digest, computed independently of the implementation.
    static var expectedCommandDigest: String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Property labels no decoding type may declare. One definition, used by
    /// every test in this suite that inspects labels rather than values.
    ///
    /// This applies to the decoding surface only. `TokenUsage` legitimately has
    /// a `thinking` property holding a token count, which section 3.1 permits
    /// under `message.usage.*`, so a domain value graph is checked against its
    /// own permitted field paths below rather than against this list.
    static let forbiddenLabels = [
        "text", "thinking", "toolUseResult", "tool_result", "snapshot",
        "attachment", "command", "content_text", "input_text",
    ]

    // MARK: - Subagent field paths
    //
    // Section 3.1, as amended on 2026-09-02, permits the four fields
    // `SubagentLocator.Meta` decodes from `agent-<id>.meta.json`: `agentType`,
    // `description`, `toolUseId` and `spawnDepth`. `description` reaches the
    // domain as `taskDescription` and the database as `task_description`.
    // The sets below spell out every field these two types may carry, so a
    // field added to either fails here and has to be argued into the allowlist
    // rather than arriving with it.

    static let permittedSubagentPaths: Set<String> = [
        "id",
        "parentSessionID",
        "agentType",
        "taskDescription",
        "usage.freshInput",
        "usage.cacheCreation",
        "usage.cacheRead",
        "usage.output",
        "usage.thinking",
        "currentActivity.verb",
        "currentActivity.subject",
        "model",
        "lastActivityAt",
        "recordsParsed",
        "spawnDepth",
    ]

    static let permittedSubagentTotalPaths: Set<String> = [
        "parentSessionID",
        "subagentID",
        "agentType",
        "taskDescription",
        "usage.freshInput",
        "usage.cacheCreation",
        "usage.cacheRead",
        "usage.output",
        "usage.thinking",
        "recordsParsed",
        "lastActivityAt",
        "spawnDepth",
        "model",
    ]

    /// Markers, one per field that can hold a string, so a walk that skips a
    /// field is visible as a missing marker rather than as a silent pass.
    static let markerID = "MARKER-SUBAGENT-ID-4a1c9f"
    static let markerParent = "MARKER-PARENT-SESSION-8f2071"
    static let markerAgentType = "MARKER-AGENT-TYPE-13bd6e"
    static let markerTask = "MARKER-TASK-DESCRIPTION-77e5c2"
    static let markerModel = "MARKER-MODEL-c30a48"
    static let markerVerb = "MARKER-ACTIVITY-VERB-5b91d0"
    static let markerSubject = "MARKER-ACTIVITY-SUBJECT-e604af"

    static var subagentMarkers: [String] {
        [markerID, markerParent, markerAgentType, markerTask, markerModel, markerVerb, markerSubject]
    }

    static let markedUsage = TokenUsage(
        freshInput: 11, cacheCreation: 22, cacheRead: 33, output: 44, thinking: 55
    )
    static let markedTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

    static func markedSubagent() -> AISubagent {
        AISubagent(
            id: markerID,
            parentSessionID: markerParent,
            agentType: markerAgentType,
            taskDescription: markerTask,
            usage: markedUsage,
            currentActivity: Activity(verb: markerVerb, subject: markerSubject),
            model: markerModel,
            lastActivityAt: markedTimestamp,
            recordsParsed: 7,
            spawnDepth: 2
        )
    }

    /// A transcript in which every forbidden field carries a sentinel.
    private func loadedFixture() -> TranscriptFixture {
        let fixture = TranscriptFixture()
        let content = """
        [{"type":"text","text":"\(Self.responseText)"},\
        {"type":"thinking","thinking":"\(Self.thinkingText)","signature":"sig"},\
        \(TranscriptFixture.toolUse("Read", filePath: "/repo/Sources/App/Menu.swift")),\
        \(TranscriptFixture.toolUse("Bash", command: Self.command))]
        """
        fixture.appendLines([
            """
            {"type":"user","sessionId":"\(fixture.sessionID)","message":{"role":"user",\
            "content":[{"type":"text","text":"\(Self.promptText)"}]},\
            "toolUseResult":{"stdout":"\(Self.toolResultText)","stderr":""}}
            """,
            """
            {"type":"user","sessionId":"\(fixture.sessionID)","message":{"role":"user",\
            "content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"\(Self.toolResultText)"}]}}
            """,
            """
            {"type":"attachment","sessionId":"\(fixture.sessionID)",\
            "attachment":{"type":"file","content":"\(Self.attachmentText)"}}
            """,
            """
            {"type":"file-history-snapshot","sessionId":"\(fixture.sessionID)",\
            "snapshot":{"trackedFileBackups":{"/repo/a.swift":"\(Self.snapshotText)"}}}
            """,
            """
            {"type":"file-history-delta","sessionId":"\(fixture.sessionID)",\
            "backup":{"patch":"\(Self.snapshotText)"}}
            """,
            fixture.assistantRecord(content: content),
        ])
        return fixture
    }

    // MARK: - The delta carries no sentinel

    @Test("No forbidden text reaches the emitted delta")
    func deltaCarriesNoSentinel() {
        let fixture = loadedFixture()
        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        // The delta did its job, so absence is not absence of parsing.
        #expect(delta.recordsParsed == 1)
        #expect(delta.usage.total > 0)
        #expect(delta.latestActivity != nil)

        // Everything the delta holds, rendered exhaustively.
        let haystack = Self.deepDescription(of: delta)
        for sentinel in Self.allSentinels {
            #expect(!haystack.contains(sentinel), "delta leaked \(sentinel)")
        }

        // And the individual fields the UI actually renders.
        let rendered = [
            delta.latestActivity?.verb,
            delta.latestActivity?.subject,
            delta.latestActivity?.display,
            delta.latestModel,
        ].compactMap { $0 }
        for field in rendered {
            for sentinel in Self.allSentinels {
                #expect(!field.contains(sentinel), "field '\(field)' leaked \(sentinel)")
            }
        }
    }

    @Test("The Bash activity is exactly 'Running a command'")
    func bashActivityIsGeneric() {
        let fixture = loadedFixture()
        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        let activity = try! #require(delta.latestActivity)
        #expect(activity.verb == "Running")
        #expect(activity.subject == "a command")
        #expect(activity.display == "Running a command")

        // Also directly, independent of the reader.
        #expect(ActivityMapper.activity(toolName: "Bash").display == "Running a command")
    }

    // MARK: - The command exists only as a digest

    @Test("A command is represented only as a 64-character lowercase hex SHA256")
    func commandIsOnlyEverADigest() throws {
        let json = TranscriptFixture.toolUse("Bash", command: Self.command)
        let block = try JSONDecoder().decode(TranscriptContentBlock.self, from: Data(json.utf8))
        let input = try #require(block.input)

        let digest = try #require(input.commandSHA256)
        #expect(digest == Self.expectedCommandDigest)
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(!digest.contains(Self.command))

        // Nothing in the decoded object graph resembles the raw command.
        let dump = Self.deepDescription(of: block)
        for sentinel in Self.allSentinels {
            #expect(!dump.contains(sentinel), "decoded tool_use leaked \(sentinel)")
        }
        // The allowlisted digest is present, so the check above is meaningful.
        #expect(dump.contains(Self.expectedCommandDigest))
    }

    @Test("Absent or empty commands produce no digest")
    func noCommandNoDigest() throws {
        let json = TranscriptFixture.toolUse("Read", filePath: "/repo/a.swift")
        let block = try JSONDecoder().decode(TranscriptContentBlock.self, from: Data(json.utf8))
        #expect(block.input?.commandSHA256 == nil)
        #expect(block.input?.filePath == "/repo/a.swift")
    }

    // MARK: - The decoding surface has no forbidden property

    @Test("The decoded record graph holds no forbidden field")
    func decodedRecordHoldsNothingForbidden() throws {
        let fixture = TranscriptFixture()
        let line = fixture.assistantRecord(content: """
        [{"type":"text","text":"\(Self.responseText)"},\
        {"type":"thinking","thinking":"\(Self.thinkingText)","signature":"sig"},\
        \(TranscriptFixture.toolUse("Bash", command: Self.command))]
        """)
        let record = try JSONDecoder().decode(TranscriptRecord.self, from: Data(line.utf8))

        let dump = Self.deepDescription(of: record)
        for sentinel in Self.allSentinels {
            #expect(!dump.contains(sentinel), "decoded record leaked \(sentinel)")
        }

        // Allowlisted data did survive, so the assertion above is not vacuous.
        #expect(record.message?.usage?.tokenUsage.total ?? 0 > 0)
        #expect(record.message?.model == "claude-sonnet-5")
        #expect(record.message?.content?.count == 3)
        #expect(dump.contains("claude-sonnet-5"))
    }

    @Test("No property named for a forbidden field exists on the decoding types")
    func decodingTypesDeclareNoForbiddenProperty() throws {
        let line = TranscriptFixture().assistantRecord(content: """
        [{"type":"text","text":"\(Self.responseText)"},\
        \(TranscriptFixture.toolUse("Bash", command: Self.command))]
        """)
        let record = try JSONDecoder().decode(TranscriptRecord.self, from: Data(line.utf8))

        for label in Self.deepLabels(of: record) {
            #expect(!Self.forbiddenLabels.contains(label), "decoding type declares a '\(label)' property")
        }
    }

    // MARK: - A tail read of the same file leaks nothing either

    @Test("Incremental reads never leak, however the file is chunked")
    func incrementalReadsNeverLeak() {
        let fixture = loadedFixture()
        let store = TranscriptMemoryCursorStore()
        // A tiny chunk size forces sentinels to straddle chunk boundaries.
        let reader = TranscriptReader(
            cursorStore: store,
            locator: TranscriptLocator(projectsDirectory: fixture.projectsDirectory),
            chunkSize: 64
        )

        var deltas: [TranscriptDelta] = []
        deltas.append(reader.readIncremental(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory))
        fixture.appendLines([fixture.assistantRecord(content: """
        [{"type":"text","text":"\(Self.promptText)"},\
        \(TranscriptFixture.toolUse("Bash", command: Self.command))]
        """)])
        deltas.append(reader.readIncremental(sessionID: fixture.sessionID, workingDirectory: fixture.workingDirectory))

        #expect(deltas[0].recordsParsed == 1)
        #expect(deltas[1].recordsParsed == 1)
        for delta in deltas {
            let haystack = Self.deepDescription(of: delta)
            for sentinel in Self.allSentinels {
                #expect(!haystack.contains(sentinel), "delta leaked \(sentinel)")
            }
        }
    }

    // MARK: - The newest request block is walked on purpose

    @Test("The delta's lastRequestUsage is populated, so the leak check reaches it")
    func lastRequestUsageIsReachedDeliberately() throws {
        let fixture = loadedFixture()
        let delta = fixture.read(with: fixture.makeReader(store: TranscriptMemoryCursorStore()))

        // Added after the rest of this suite was written. It was reached only
        // incidentally, by a walk over a delta that happened to carry one; a
        // fixture that stopped populating it would have made the leak check
        // vacuous for this field without failing anything. Now it is stated.
        let request = try #require(delta.lastRequestUsage, "fixture must populate lastRequestUsage")
        #expect(request.total > 0)

        let paths = Set(Self.deepFieldPaths(of: delta))
        #expect(paths.contains("lastRequestUsage.freshInput"))
        #expect(paths.contains("lastRequestUsage.cacheRead"))
        #expect(paths.contains("lastRequestUsage.output"))

        // It holds counts and nothing else.
        let dump = Self.deepDescription(of: request)
        for sentinel in Self.allSentinels {
            #expect(!dump.contains(sentinel), "lastRequestUsage leaked \(sentinel)")
        }
    }

    // MARK: - The subagent types carry nothing outside the allowlist

    @Test("An AISubagent's value graph is exactly the amended allowlist")
    func subagentGraphIsExactlyTheAllowlist() {
        let subagent = Self.markedSubagent()

        let paths = Set(Self.deepFieldPaths(of: subagent))
        #expect(paths == Self.permittedSubagentPaths,
                "unexpected \(paths.subtracting(Self.permittedSubagentPaths)), missing \(Self.permittedSubagentPaths.subtracting(paths))")

        // The walk really did reach every field, so the comparison above is a
        // statement about the type and not about a walk that stopped early.
        let dump = Self.deepDescription(of: subagent)
        for marker in Self.subagentMarkers {
            #expect(dump.contains(marker), "the walk never reached \(marker)")
        }
        for sentinel in Self.allSentinels {
            #expect(!dump.contains(sentinel), "subagent leaked \(sentinel)")
        }
    }

    @Test("A SubagentTotal's value graph is exactly the amended allowlist")
    func subagentTotalGraphIsExactlyTheAllowlist() {
        let total = SubagentTotal(Self.markedSubagent())

        let paths = Set(Self.deepFieldPaths(of: total))
        #expect(paths == Self.permittedSubagentTotalPaths,
                "unexpected \(paths.subtracting(Self.permittedSubagentTotalPaths)), missing \(Self.permittedSubagentTotalPaths.subtracting(paths))")

        // Every marker except the activity, which the durable form drops on
        // purpose: an activity label names a file, and there is no reason to
        // keep that on disk once the subagent is gone.
        let dump = Self.deepDescription(of: total)
        for marker in [Self.markerID, Self.markerParent, Self.markerAgentType,
                       Self.markerTask, Self.markerModel] {
            #expect(dump.contains(marker), "the walk never reached \(marker)")
        }
        #expect(!dump.contains(Self.markerVerb))
        #expect(!dump.contains(Self.markerSubject))
        for sentinel in Self.allSentinels {
            #expect(!dump.contains(sentinel), "subagent total leaked \(sentinel)")
        }
    }

    @Test("A SubagentTotal read back from SQLite is still exactly the allowlist")
    func persistedSubagentTotalIsExactlyTheAllowlist() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudencePrivacy", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ClaudenceStore(url: directory.appendingPathComponent("claudence.db"))
        let written = SubagentTotal(Self.markedSubagent())
        store.upsertSubagentTotal(written)

        let read = try #require(store.subagentTotals(forSession: Self.markerParent).first)

        // The persisted shape, not only the in-memory one. A column added to
        // `subagent_totals` and surfaced on this type fails here too.
        let paths = Set(Self.deepFieldPaths(of: read))
        #expect(paths == Self.permittedSubagentTotalPaths,
                "unexpected \(paths.subtracting(Self.permittedSubagentTotalPaths)), missing \(Self.permittedSubagentTotalPaths.subtracting(paths))")

        #expect(read.subagentID == Self.markerID)
        #expect(read.agentType == Self.markerAgentType)
        #expect(read.taskDescription == Self.markerTask)
        #expect(read.model == Self.markerModel)
        #expect(read.usage == Self.markedUsage)
        #expect(read.recordsParsed == 7)
        #expect(read.spawnDepth == 2)

        let dump = Self.deepDescription(of: read)
        for sentinel in Self.allSentinels {
            #expect(!dump.contains(sentinel), "persisted total leaked \(sentinel)")
        }
    }

    // MARK: - Reflection helpers

    /// Renders every stored property, recursively, so a leak anywhere in the
    /// value graph is visible as text.
    static func deepDescription(of value: Any, depth: Int = 0) -> String {
        guard depth < 12 else { return "" }
        let mirror = Mirror(reflecting: value)
        if mirror.children.isEmpty { return String(describing: value) }
        return mirror.children
            .map { "\($0.label ?? "_")=\(deepDescription(of: $0.value, depth: depth + 1))" }
            .joined(separator: " ")
    }

    /// Every field in the value graph, as a dotted path from the root.
    ///
    /// Optionals are transparent, so a field reads the same whether it holds a
    /// value or nil, and a nil field is still listed rather than vanishing.
    /// `Date` is a leaf: its single stored property is an implementation
    /// detail of Foundation and naming it in an allowlist would say nothing.
    static func deepFieldPaths(of value: Any, prefix: String = "", depth: Int = 0) -> [String] {
        guard depth < 12 else { return [] }
        if value is Date { return prefix.isEmpty ? [] : [prefix] }
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else { return prefix.isEmpty ? [] : [prefix] }
            return deepFieldPaths(of: child.value, prefix: prefix, depth: depth + 1)
        }
        if mirror.children.isEmpty { return prefix.isEmpty ? [] : [prefix] }
        return mirror.children.flatMap { child -> [String] in
            let label = child.label ?? "_"
            let path = prefix.isEmpty ? label : "\(prefix).\(label)"
            return deepFieldPaths(of: child.value, prefix: path, depth: depth + 1)
        }
    }

    // MARK: - The account file

    /// `~/.claude.json` is the most sensitive file this application opens: the
    /// user's email address, full name, organisation name, account UUID and
    /// every project path they have ever worked in sit two keys away from the
    /// two fields `AccountPlanReader` is allowed to read. The narrowness of that
    /// decoder is the entire safeguard, so it is a test rather than a comment.
    @Test("the plan reader carries nothing out of the account file but the tier")
    func accountPlanReaderReadsOnlyTheTier() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(".claude.json")
        let secrets = [
            "SENTINEL-EMAIL-4a91c7de@example.com",
            "SENTINEL-FULLNAME-0b3e88fa",
            "SENTINEL-ORGNAME-77dc21ab",
            "SENTINEL-UUID-5e0fa943",
            "/Users/sentinel/SENTINEL-PROJECT-PATH-1c9b6e20",
        ]
        let document = """
            {
              "oauthAccount": {
                "emailAddress": "\(secrets[0])",
                "fullName": "\(secrets[1])",
                "displayName": "\(secrets[1])",
                "organizationName": "\(secrets[2])",
                "accountUuid": "\(secrets[3])",
                "organizationUuid": "\(secrets[3])",
                "organizationType": "claude_max",
                "organizationRateLimitTier": "default_claude_max_5x",
                "organizationRole": "admin",
                "billingType": "stripe_subscription"
              },
              "projects": { "\(secrets[4])": { "history": ["\(secrets[0])"] } }
            }
            """
        try Data(document.utf8).write(to: url)

        let plan = try #require(AccountPlanReader.read(from: url))
        #expect(plan.displayName == "Max 5x")

        // Nothing from the file may reach the value, by field or by content.
        let fields = PrivacyTests.deepFieldPaths(of: plan).map { "\($0)" }
        for secret in secrets {
            #expect(!fields.contains { $0.contains(secret) })
        }
        // And the value has exactly one field, so a later addition to
        // `AccountPlan` has to come past this test.
        #expect(PrivacyTests.deepLabels(of: plan) == ["displayName"])
    }

    @Test("an unrecognised tier produces no plan rather than a guess")
    func accountPlanRefusesToGuess() {
        #expect(AccountPlanReader.plan(organizationType: nil, rateLimitTier: nil) == nil)
        #expect(
            AccountPlanReader.plan(
                organizationType: "claude_something_new",
                rateLimitTier: "default_claude_something_new_9x"
            ) == nil
        )
    }

    @Test("the multiplier comes from the rate limit tier, which is the only place it appears")
    func accountPlanReadsTheMultiplier() {
        #expect(
            AccountPlanReader.plan(
                organizationType: "claude_max", rateLimitTier: "default_claude_max_20x"
            )?.displayName == "Max 20x"
        )
        // A tier with no multiplier still names the plan: "Max" is true.
        #expect(
            AccountPlanReader.plan(
                organizationType: "claude_max", rateLimitTier: "default_claude_max"
            )?.displayName == "Max"
        )
        #expect(
            AccountPlanReader.plan(
                organizationType: "claude_pro", rateLimitTier: nil
            )?.displayName == "Pro"
        )
    }

    /// Every property label in the value graph.
    static func deepLabels(of value: Any, depth: Int = 0) -> [String] {
        guard depth < 12 else { return [] }
        let mirror = Mirror(reflecting: value)
        return mirror.children.flatMap { child -> [String] in
            var labels: [String] = []
            if let label = child.label, !label.hasPrefix("_"), Int(label) == nil {
                labels.append(label)
            }
            labels.append(contentsOf: deepLabels(of: child.value, depth: depth + 1))
            return labels
        }
    }
}
