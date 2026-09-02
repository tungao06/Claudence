import Foundation

/// A subagent as the interface sees it.
public struct AISubagent: Sendable, Equatable, Identifiable {
    public let id: String
    public let parentSessionID: String
    public let agentType: String?
    /// The task the parent gave it. Comes from `meta.json`, which is written by
    /// Claude Code, not from any message content.
    public let taskDescription: String?
    public var usage: TokenUsage
    public var currentActivity: Activity?
    public var model: String?
    public var lastActivityAt: Date?
    public var recordsParsed: Int
    public let spawnDepth: Int

    public init(
        id: String,
        parentSessionID: String,
        agentType: String? = nil,
        taskDescription: String? = nil,
        usage: TokenUsage = .zero,
        currentActivity: Activity? = nil,
        model: String? = nil,
        lastActivityAt: Date? = nil,
        recordsParsed: Int = 0,
        spawnDepth: Int = 1
    ) {
        self.id = id
        self.parentSessionID = parentSessionID
        self.agentType = agentType
        self.taskDescription = taskDescription
        self.usage = usage
        self.currentActivity = currentActivity
        self.model = model
        self.lastActivityAt = lastActivityAt
        self.recordsParsed = recordsParsed
        self.spawnDepth = spawnDepth
    }

    /// A subagent has no process of its own. It is finished when its transcript
    /// has stopped growing; the caller decides the staleness horizon.
    public func isActive(now: Date = Date(), idleAfter: TimeInterval = 120) -> Bool {
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince(lastActivityAt) < idleAfter
    }

    /// Share of a parent total, as a fraction. Nil when the parent total is
    /// zero, because a share of nothing is not zero, it is undefined.
    public func share(ofParentTotal total: Int) -> Double? {
        guard total > 0 else { return nil }
        return Double(usage.total) / Double(total)
    }
}

/// Reads every subagent transcript belonging to a session and accumulates them.
///
/// This exists because the parent transcript does not contain subagent records
/// at all. Measured on this repository's own session: 82.8M tokens in the parent
/// and 77.4M across its subagents, so without this the application reported
/// slightly over half of what was actually spent.
///
/// Accumulation is incremental, using the same `(path, inode, byteOffset)`
/// cursor discipline as the parent reader. Cursor keys are namespaced by
/// subagent id so they cannot collide with a session id.
public actor SubagentTracker {
    private let locator: SubagentLocator
    private let reader: TranscriptReader

    /// Accumulated state per subagent id, so a delta is added rather than
    /// replacing what came before.
    private var accumulated: [String: AISubagent] = [:]
    /// Which subagents belong to which parent, refreshed on each pass so a
    /// vanished session's subagents can be dropped.
    private var byParent: [String: Set<String>] = [:]

    public init(locator: SubagentLocator = SubagentLocator(), reader: TranscriptReader) {
        self.locator = locator
        self.reader = reader
    }

    /// Reads new records for every subagent of a session and returns the full
    /// current set, newest activity first.
    public func refresh(sessionID: String, workingDirectory: String) -> [AISubagent] {
        let descriptors = locator.subagents(forSession: sessionID, workingDirectory: workingDirectory)
        var ids: Set<String> = []

        for descriptor in descriptors {
            ids.insert(descriptor.id)
            let delta = reader.readIncremental(
                atPath: descriptor.transcriptPath,
                cursorKey: Self.cursorKey(for: descriptor)
            )

            var current = accumulated[descriptor.id] ?? AISubagent(
                id: descriptor.id,
                parentSessionID: descriptor.parentSessionID,
                agentType: descriptor.agentType,
                taskDescription: descriptor.taskDescription,
                spawnDepth: descriptor.spawnDepth
            )
            current.usage += delta.usage
            current.recordsParsed += delta.recordsParsed
            if let activity = delta.latestActivity { current.currentActivity = activity }
            if let model = delta.latestModel { current.model = model }
            if let stamp = delta.latestTimestamp {
                current.lastActivityAt = max(stamp, current.lastActivityAt ?? stamp)
            }
            accumulated[descriptor.id] = current
        }

        // A subagent that disappeared from disk drops its accumulator, so a
        // reused id cannot inherit a stale total.
        if let previous = byParent[sessionID] {
            for stale in previous.subtracting(ids) { accumulated[stale] = nil }
        }
        byParent[sessionID] = ids

        return ids
            .compactMap { accumulated[$0] }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    /// Drops everything known about a session's subagents. Called when the
    /// session itself ends.
    public func forget(sessionID: String) {
        guard let ids = byParent.removeValue(forKey: sessionID) else { return }
        for id in ids { accumulated[id] = nil }
    }

    public func subagents(forSession sessionID: String) -> [AISubagent] {
        (byParent[sessionID] ?? []).compactMap { accumulated[$0] }
    }

    /// Namespaced so a subagent's stored offset can never be mistaken for the
    /// parent session's own cursor.
    static func cursorKey(for descriptor: SubagentDescriptor) -> String {
        "subagent:\(descriptor.parentSessionID):\(descriptor.id)"
    }
}
