import Foundation
import Testing

@testable import ClaudenceCore

// MARK: - Fixture

/// A throwaway `~/.claude/projects` tree, built by hand rather than through
/// `TranscriptFixture` because these tests need several sessions, and
/// sometimes several projects, under one shared `projectsDirectory` -- the
/// exact shape `HistoryImporter` walks.
private func makeProjectsRoot() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claudence-history-importer-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projects = root.appendingPathComponent("projects", isDirectory: true)
    try? FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    return projects
}

@discardableResult
private func writeTranscript(
    projectsDirectory: URL,
    sessionID: String,
    workingDirectory: String,
    lines: [String]
) -> URL {
    let projectDirectory = projectsDirectory.appendingPathComponent(
        TranscriptLocator.slug(forWorkingDirectory: workingDirectory), isDirectory: true
    )
    try? FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
    let url = projectDirectory.appendingPathComponent("\(sessionID).jsonl")
    let text = lines.map { $0 + "\n" }.joined()
    try? Data(text.utf8).write(to: url)
    return url
}

private func subagentsDirectory(projectsDirectory: URL, sessionID: String, workingDirectory: String) -> URL {
    projectsDirectory
        .appendingPathComponent(TranscriptLocator.slug(forWorkingDirectory: workingDirectory), isDirectory: true)
        .appendingPathComponent(sessionID, isDirectory: true)
        .appendingPathComponent("subagents", isDirectory: true)
}

/// Writes one subagent transcript (plus its `meta.json`, when labels are
/// given) beside a parent session, the same layout `SubagentLocator` expects.
private func writeSubagent(
    projectsDirectory: URL,
    sessionID: String,
    workingDirectory: String,
    agentID: String,
    agentType: String? = nil,
    description: String? = nil,
    lines: [String]
) {
    let directory = subagentsDirectory(
        projectsDirectory: projectsDirectory, sessionID: sessionID, workingDirectory: workingDirectory
    )
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    if let agentType, let description {
        let meta = """
            {"agentType":"\(agentType)","description":"\(description)","toolUseId":"toolu_1","spawnDepth":1}
            """
        try? Data(meta.utf8).write(to: directory.appendingPathComponent("\(agentID).meta.json"))
    }
    let text = lines.map { $0 + "\n" }.joined()
    try? Data(text.utf8).write(to: directory.appendingPathComponent("\(agentID).jsonl"))
}

/// A record shaped like a real Claude Code 2.1.257 `assistant` line. `cwd` is
/// included deliberately: `HistoryImporter` has no live registry to read a
/// working directory from, so it reads this same field from the transcript.
private func record(
    sessionID: String,
    workingDirectory: String,
    timestamp: String,
    input: Int,
    output: Int = 0,
    cacheCreation: Int = 0,
    cacheRead: Int = 0,
    model: String = "claude-sonnet-5"
) -> String {
    """
    {"parentUuid":"\(UUID().uuidString.lowercased())","isSidechain":false,"userType":"external",\
    "cwd":"\(workingDirectory)","sessionId":"\(sessionID)","version":"2.1.257","gitBranch":"main",\
    "type":"assistant","message":{"id":"msg_01Abc","type":"message","role":"assistant",\
    "model":"\(model)","content":[{"type":"text","text":"ordinary response text"}],\
    "usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreation),\
    "cache_read_input_tokens":\(cacheRead),"output_tokens":\(output),\
    "output_tokens_details":{"thinking_tokens":0},"service_tier":"standard"}},\
    "uuid":"\(UUID().uuidString.lowercased())","timestamp":"\(timestamp)"}
    """
}

/// Fixed to UTC so a day boundary in a test does not depend on the machine
/// running it.
private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func makeImporter(
    projectsDirectory: URL,
    store: ClaudenceStore,
    calendar: Calendar
) -> HistoryImporter {
    let reader = TranscriptReader(
        cursorStore: store,
        locator: TranscriptLocator(projectsDirectory: projectsDirectory),
        calendar: calendar
    )
    return HistoryImporter(projectsDirectory: projectsDirectory, store: store, reader: reader, calendar: calendar)
}

// MARK: - Tests

@Suite("History importer")
struct HistoryImporterTests {

    @Test("a session spanning three local days lands on three days")
    func threeDaySessionLandsOnThreeDays() throws {
        let projects = makeProjectsRoot()
        let sessionID = UUID().uuidString.lowercased()
        let workingDirectory = "/Users/tester/three-day-project"
        writeTranscript(
            projectsDirectory: projects, sessionID: sessionID, workingDirectory: workingDirectory,
            lines: [
                record(sessionID: sessionID, workingDirectory: workingDirectory,
                       timestamp: "2026-01-05T09:00:00.000Z", input: 100),
                record(sessionID: sessionID, workingDirectory: workingDirectory,
                       timestamp: "2026-01-06T09:00:00.000Z", input: 200),
                record(sessionID: sessionID, workingDirectory: workingDirectory,
                       timestamp: "2026-01-07T09:00:00.000Z", input: 300),
            ]
        )

        let calendar = utcCalendar()
        let store = ClaudenceStore(url: nil, calendar: calendar)
        let importer = makeImporter(projectsDirectory: projects, store: store, calendar: calendar)

        let report = importer.importHistory(startingFrom: Date(timeIntervalSince1970: 0))
        #expect(report.sessionsImported == 1)
        #expect(report.failures.isEmpty)
        #expect(report.sessionsSkipped.isEmpty)

        // One cumulative sample per day actually touched, not one per session.
        let samples = store.usageSamples(sessionID: sessionID)
        #expect(samples.count == 3)
        #expect(samples.map { $0.usage.freshInput } == [100, 300, 600])
        #expect(samples.map { store.dayString(for: $0.sampledAt) } == ["2026-01-05", "2026-01-06", "2026-01-07"])

        let session = try #require(store.session(id: sessionID))
        #expect(session.usage.freshInput == 600)
        // Never observed live: a dead pid, an honestly empty procStart, and a
        // status that says the session is over.
        #expect(session.pid == 0)
        #expect(session.procStart == "")
        #expect(session.status == .completed)
        #expect(session.workingDirectory == workingDirectory)
    }

    @Test("a second run changes nothing")
    func secondRunChangesNothing() throws {
        let projects = makeProjectsRoot()
        let sessionID = UUID().uuidString.lowercased()
        let workingDirectory = "/Users/tester/idempotent-project"
        writeTranscript(
            projectsDirectory: projects, sessionID: sessionID, workingDirectory: workingDirectory,
            lines: [
                record(sessionID: sessionID, workingDirectory: workingDirectory,
                       timestamp: "2026-05-01T09:00:00.000Z", input: 10, output: 1),
                record(sessionID: sessionID, workingDirectory: workingDirectory,
                       timestamp: "2026-05-02T09:00:00.000Z", input: 20, output: 2),
            ]
        )

        let calendar = utcCalendar()
        let store = ClaudenceStore(url: nil, calendar: calendar)
        let importer = makeImporter(projectsDirectory: projects, store: store, calendar: calendar)

        let first = importer.importHistory(startingFrom: Date(timeIntervalSince1970: 0))
        #expect(first.sessionsImported == 1)
        #expect(first.bytesParsed > 0)
        let sessionAfterFirst = try #require(store.session(id: sessionID))
        #expect(store.usageSamples(sessionID: sessionID).count == 2)

        let second = importer.importHistory(startingFrom: Date(timeIntervalSince1970: 0))
        #expect(second.sessionsImported == 1)
        #expect(second.bytesParsed == 0)
        let sessionAfterSecond = try #require(store.session(id: sessionID))

        #expect(sessionAfterSecond == sessionAfterFirst)
        #expect(store.usageSamples(sessionID: sessionID).count == 2)
    }

    @Test("a file that cannot be read appears in the report and does not stop the rest")
    func unreadableFileDoesNotStopTheRest() throws {
        let projects = makeProjectsRoot()
        let workingDirectory = "/Users/tester/unreadable-project"

        let readableID = UUID().uuidString.lowercased()
        writeTranscript(
            projectsDirectory: projects, sessionID: readableID, workingDirectory: workingDirectory,
            lines: [record(sessionID: readableID, workingDirectory: workingDirectory,
                            timestamp: "2026-03-01T09:00:00.000Z", input: 20, output: 2)]
        )

        let unreadableID = UUID().uuidString.lowercased()
        let unreadableURL = writeTranscript(
            projectsDirectory: projects, sessionID: unreadableID, workingDirectory: workingDirectory,
            lines: [record(sessionID: unreadableID, workingDirectory: workingDirectory,
                            timestamp: "2026-03-01T09:10:00.000Z", input: 30, output: 3)]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadableURL.path) }

        let calendar = utcCalendar()
        let store = ClaudenceStore(url: nil, calendar: calendar)
        let importer = makeImporter(projectsDirectory: projects, store: store, calendar: calendar)

        let report = importer.importHistory(startingFrom: Date(timeIntervalSince1970: 0))

        #expect(report.sessionsImported == 1)
        #expect(report.failures.count == 1)
        #expect(report.failures.first.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() }
                == unreadableURL.resolvingSymlinksInPath())
        #expect(store.session(id: readableID) != nil)
        #expect(store.session(id: unreadableID) == nil)
    }

    @Test("a session older than the start date is skipped and said to be skipped")
    func sessionOlderThanStartDateIsSkipped() throws {
        let projects = makeProjectsRoot()
        let workingDirectory = "/Users/tester/old-project"

        let oldID = UUID().uuidString.lowercased()
        writeTranscript(
            projectsDirectory: projects, sessionID: oldID, workingDirectory: workingDirectory,
            lines: [record(sessionID: oldID, workingDirectory: workingDirectory,
                            timestamp: "2020-01-01T09:00:00.000Z", input: 40, output: 4)]
        )
        let newID = UUID().uuidString.lowercased()
        writeTranscript(
            projectsDirectory: projects, sessionID: newID, workingDirectory: workingDirectory,
            lines: [record(sessionID: newID, workingDirectory: workingDirectory,
                            timestamp: "2026-04-01T09:00:00.000Z", input: 60, output: 6)]
        )

        let calendar = utcCalendar()
        let store = ClaudenceStore(url: nil, calendar: calendar)
        let importer = makeImporter(projectsDirectory: projects, store: store, calendar: calendar)

        let startDate = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let report = importer.importHistory(startingFrom: startDate)

        #expect(report.sessionsImported == 1)
        #expect(report.sessionsSkipped.count == 1)
        #expect(report.sessionsSkipped.first?.sessionID == oldID)
        #expect(report.sessionsSkipped.first?.reason == .beforeStartDate)
        #expect(store.session(id: oldID) == nil)
        #expect(store.session(id: newID) != nil)
    }

    @Test("subagent totals are imported and the combined figure matches parent plus subagents")
    func subagentTotalsAreImportedAndCombine() throws {
        let projects = makeProjectsRoot()
        let sessionID = UUID().uuidString.lowercased()
        let workingDirectory = "/Users/tester/subagent-project"
        writeTranscript(
            projectsDirectory: projects, sessionID: sessionID, workingDirectory: workingDirectory,
            lines: [record(sessionID: sessionID, workingDirectory: workingDirectory,
                            timestamp: "2026-02-01T09:00:00.000Z", input: 100, output: 10)]
        )
        writeSubagent(
            projectsDirectory: projects, sessionID: sessionID, workingDirectory: workingDirectory,
            agentID: "agent-a", agentType: "Explore", description: "map the store",
            lines: [record(sessionID: sessionID, workingDirectory: workingDirectory,
                            timestamp: "2026-02-01T09:05:00.000Z", input: 50, output: 5)]
        )

        let calendar = utcCalendar()
        let store = ClaudenceStore(url: nil, calendar: calendar)
        let importer = makeImporter(projectsDirectory: projects, store: store, calendar: calendar)

        let report = importer.importHistory(startingFrom: Date(timeIntervalSince1970: 0))
        #expect(report.sessionsImported == 1)
        #expect(report.subagentFilesRead == 1)
        #expect(report.failures.isEmpty)

        let session = try #require(store.session(id: sessionID))
        #expect(session.usage == TokenUsage(freshInput: 100, output: 10))
        #expect(session.subagentUsage == TokenUsage(freshInput: 50, output: 5))
        #expect(session.subagentCount == 1)
        #expect(session.combinedUsage == TokenUsage(freshInput: 150, output: 15))

        let subagentRows = store.subagentTotals(forSession: sessionID)
        #expect(subagentRows.count == 1)
        #expect(subagentRows.first?.usage == TokenUsage(freshInput: 50, output: 5))
        #expect(subagentRows.first?.agentType == "Explore")
        #expect(subagentRows.first?.taskDescription == "map the store")
    }

    @Test("an import populates the per-model split, parent and subagent both")
    func importPopulatesModelSplit() throws {
        let projects = makeProjectsRoot()
        let sessionID = UUID().uuidString.lowercased()
        let workingDirectory = "/Users/tester/model-split-project"
        writeTranscript(
            projectsDirectory: projects, sessionID: sessionID, workingDirectory: workingDirectory,
            lines: [
                record(sessionID: sessionID, workingDirectory: workingDirectory,
                       timestamp: "2026-02-01T09:00:00.000Z", input: 100, output: 10, model: "claude-sonnet-5"),
                record(sessionID: sessionID, workingDirectory: workingDirectory,
                       timestamp: "2026-02-01T09:01:00.000Z", input: 60, output: 6, model: "claude-opus-5"),
            ]
        )
        writeSubagent(
            projectsDirectory: projects, sessionID: sessionID, workingDirectory: workingDirectory,
            agentID: "agent-a", agentType: "Explore", description: "map the store",
            lines: [record(sessionID: sessionID, workingDirectory: workingDirectory,
                            timestamp: "2026-02-01T09:05:00.000Z", input: 50, output: 5, model: "claude-haiku-4-5")]
        )

        let calendar = utcCalendar()
        let store = ClaudenceStore(url: nil, calendar: calendar)
        let importer = makeImporter(projectsDirectory: projects, store: store, calendar: calendar)

        let report = importer.importHistory(startingFrom: Date(timeIntervalSince1970: 0))
        #expect(report.sessionsImported == 1)
        #expect(report.failures.isEmpty)

        let session = try #require(store.session(id: sessionID))
        #expect(session.usageByModel["claude-sonnet-5"] == TokenUsage(freshInput: 100, output: 10))
        #expect(session.usageByModel["claude-opus-5"] == TokenUsage(freshInput: 60, output: 6))
        #expect(session.subagentUsageByModel["claude-haiku-4-5"] == TokenUsage(freshInput: 50, output: 5))

        // The parent split sums to the parent total, the combined split to
        // the combined total -- the same reconciliation the live path keeps.
        let parentSummed = session.usageByModel.values.reduce(TokenUsage.zero, +)
        #expect(parentSummed == session.usage)
        let combinedSummed = session.combinedUsageByModel.values.reduce(TokenUsage.zero, +)
        #expect(combinedSummed == session.combinedUsage)

        let report30d = store.monthlyTotals(since: Date(timeIntervalSince1970: 0))
        let project = try #require(report30d.rows.first { $0.projectName == "model-split-project" })
        #expect(project.usageByModel["claude-sonnet-5"] == TokenUsage(freshInput: 100, output: 10))
        #expect(project.usageByModel["claude-opus-5"] == TokenUsage(freshInput: 60, output: 6))
        #expect(project.usageByModel["claude-haiku-4-5"] == TokenUsage(freshInput: 50, output: 5))
        #expect(project.usage == session.combinedUsage)
    }

    @Test("an absent projects directory is an ordinary empty report, not a failure")
    func absentProjectsDirectoryIsOrdinary() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("claudence-history-importer-tests-missing-\(UUID().uuidString)", isDirectory: true)
        let calendar = utcCalendar()
        let store = ClaudenceStore(url: nil, calendar: calendar)
        let importer = makeImporter(projectsDirectory: missing, store: store, calendar: calendar)

        let report = importer.importHistory(startingFrom: Date(timeIntervalSince1970: 0))
        #expect(report == HistoryImporter.Report())
    }
}
