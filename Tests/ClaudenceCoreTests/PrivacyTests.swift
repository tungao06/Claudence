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

        let forbidden = ["text", "thinking", "toolUseResult", "tool_result", "snapshot",
                         "attachment", "command", "content_text", "input_text"]
        for label in Self.deepLabels(of: record) {
            #expect(!forbidden.contains(label), "decoding type declares a '\(label)' property")
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
