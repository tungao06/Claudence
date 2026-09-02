import Foundation

/// A subagent spawned by an interactive session.
///
/// Subagent transcripts are a fifth data source, and until this existed the
/// application under-reported tokens badly: measured on this repository's own
/// session, the parent transcript held 82.8M tokens and its subagents held
/// 77.4M, so 48% of the true total was invisible.
///
/// They are NOT in the parent transcript. `isSidechain` is false on every
/// parent record and no `agent-name` record is written. They live in a
/// directory beside the parent file:
///
/// ```
/// ~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.jsonl
/// ~/.claude/projects/<slug>/<sessionId>/subagents/agent-<id>.meta.json
/// ```
///
/// Verified against Claude Code 2.1.257.
public struct SubagentDescriptor: Sendable, Equatable, Identifiable {
    /// The `agent-<id>` stem, unique within a parent session.
    public let id: String
    public let parentSessionID: String
    /// `general-purpose`, `Explore`, and so on, from `meta.json`.
    public let agentType: String?
    /// The task description the parent gave when spawning it.
    public let taskDescription: String?
    /// The parent's `tool_use` id that created it, so a subagent can be traced
    /// back to the exact call in the parent transcript.
    public let toolUseID: String?
    /// 1 for a subagent of an interactive session. Deeper values mean a
    /// subagent spawned another.
    public let spawnDepth: Int
    public let transcriptPath: String

    public init(
        id: String,
        parentSessionID: String,
        agentType: String? = nil,
        taskDescription: String? = nil,
        toolUseID: String? = nil,
        spawnDepth: Int = 1,
        transcriptPath: String
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.agentType = agentType
        self.taskDescription = taskDescription
        self.toolUseID = toolUseID
        self.spawnDepth = spawnDepth
        self.transcriptPath = transcriptPath
    }
}

/// Finds the subagent transcripts belonging to a session.
///
/// Read-only and tolerant: a missing directory, an unreadable file, or a
/// malformed `meta.json` yields fewer descriptors, never an error. A session
/// with no subagents is the ordinary case.
public struct SubagentLocator: Sendable {
    private let projectsDirectory: URL

    public init(projectsDirectory: URL = Constants.projectsDirectory) {
        self.projectsDirectory = projectsDirectory
    }

    /// `FileManager` is not `Sendable`, so it is fetched per call rather than
    /// stored. `.default` is documented as thread-safe for these read-only
    /// queries, which is all this type does.
    private var fileManager: FileManager { .default }

    /// The directory holding a session's subagent transcripts, if it exists.
    public func directory(forSession sessionID: String, workingDirectory: String) -> URL? {
        let candidates = [
            projectsDirectory
                .appendingPathComponent(TranscriptLocator.slug(forWorkingDirectory: workingDirectory), isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
        ]
        for candidate in candidates where isDirectory(candidate) {
            return candidate
        }
        // The slug is a hint, not a guarantee. Fall back to scanning for a
        // directory named after the session, the same way the parent locator
        // falls back rather than trusting a derived path.
        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        for project in projects {
            let candidate = project
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
            if isDirectory(candidate) { return candidate }
        }
        return nil
    }

    /// Every subagent belonging to a session, or nil when the directory could
    /// not be listed at all.
    ///
    /// The distinction is load bearing. A caller that treats an empty result as
    /// "every subagent is gone" will delete their persisted totals, and a
    /// transient failure to read the directory would then look identical to a
    /// session whose subagents really did disappear. An absent directory is
    /// still an ordinary empty result, because a session with no subagents has
    /// no such directory; only a directory that exists and cannot be read is
    /// reported as unknown.
    public func listSubagents(forSession sessionID: String, workingDirectory: String) -> [SubagentDescriptor]? {
        guard let directory = directory(forSession: sessionID, workingDirectory: workingDirectory) else {
            return []
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return nil }

        let transcripts = entries.filter { $0.pathExtension == "jsonl" }

        return transcripts
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                let meta = readMeta(directory.appendingPathComponent("\(stem).meta.json"))
                return SubagentDescriptor(
                    id: stem,
                    parentSessionID: sessionID,
                    agentType: meta?.agentType,
                    taskDescription: meta?.description,
                    toolUseID: meta?.toolUseId,
                    spawnDepth: meta?.spawnDepth ?? 1,
                    transcriptPath: url.path
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// Convenience for callers that do not distinguish the two failures.
    public func subagents(forSession sessionID: String, workingDirectory: String) -> [SubagentDescriptor] {
        listSubagents(forSession: sessionID, workingDirectory: workingDirectory) ?? []
    }

    // MARK: - Internals

    private struct Meta: Decodable {
        let agentType: String?
        let description: String?
        let toolUseId: String?
        let spawnDepth: Int?
    }

    /// A malformed or absent `meta.json` costs the descriptor its labels, not
    /// its tokens: the transcript is still read and still counted.
    private func readMeta(_ url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
}
