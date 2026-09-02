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

/// A subagent's accumulated total in its durable form.
///
/// This is what survives a relaunch. `AISubagent` carries the same figures plus
/// `currentActivity`, which is deliberately absent here: an activity label names
/// a file the subagent was touching, and there is no product reason to keep that
/// on disk once the process is gone. The same choice `AISession` makes.
public struct SubagentTotal: Sendable, Equatable {
    public let parentSessionID: String
    public let subagentID: String
    public var agentType: String?
    public var taskDescription: String?
    public var usage: TokenUsage
    public var recordsParsed: Int
    public var lastActivityAt: Date?
    public var spawnDepth: Int
    public var model: String?

    public init(
        parentSessionID: String,
        subagentID: String,
        agentType: String? = nil,
        taskDescription: String? = nil,
        usage: TokenUsage = .zero,
        recordsParsed: Int = 0,
        lastActivityAt: Date? = nil,
        spawnDepth: Int = 1,
        model: String? = nil
    ) {
        self.parentSessionID = parentSessionID
        self.subagentID = subagentID
        self.agentType = agentType
        self.taskDescription = taskDescription
        self.usage = usage
        self.recordsParsed = recordsParsed
        self.lastActivityAt = lastActivityAt
        self.spawnDepth = spawnDepth
        self.model = model
    }
}

extension SubagentTotal {
    /// The durable form of a tracked subagent.
    public init(_ subagent: AISubagent) {
        self.init(
            parentSessionID: subagent.parentSessionID,
            subagentID: subagent.id,
            agentType: subagent.agentType,
            taskDescription: subagent.taskDescription,
            usage: subagent.usage,
            recordsParsed: subagent.recordsParsed,
            lastActivityAt: subagent.lastActivityAt,
            spawnDepth: subagent.spawnDepth,
            model: subagent.model
        )
    }

    /// The live form. `currentActivity` comes back nil because it was never
    /// stored, the same way a session read from the store has none.
    public var subagent: AISubagent {
        AISubagent(
            id: subagentID,
            parentSessionID: parentSessionID,
            agentType: agentType,
            taskDescription: taskDescription,
            usage: usage,
            model: model,
            lastActivityAt: lastActivityAt,
            recordsParsed: recordsParsed,
            spawnDepth: spawnDepth
        )
    }
}

/// Where the tracker keeps its totals between runs.
///
/// A protocol rather than the store itself so the tracker stays testable with a
/// fake and so persistence keeps knowing nothing about the engine. `Sendable`
/// because the tracker is an actor and holds this across suspension points.
public protocol SubagentTotalStoring: Sendable {
    func subagentTotals(forSession sessionID: String) -> [SubagentTotal]
    func upsertSubagentTotal(_ total: SubagentTotal)
    func deleteSubagentTotals(forSession sessionID: String)
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
    /// Optional so the existing fakes and any caller without persistence keep
    /// working. Absent, the tracker behaves exactly as it did: correct within a
    /// run, forgetful across one.
    private let store: (any SubagentTotalStoring)?

    /// Accumulated state per subagent id, so a delta is added rather than
    /// replacing what came before.
    private var accumulated: [String: AISubagent] = [:]
    /// Which subagents belong to which parent, refreshed on each pass so a
    /// vanished session's subagents can be dropped.
    private var byParent: [String: Set<String>] = [:]
    /// Sessions whose persisted totals have already been folded in, so seeding
    /// costs one read per session per process rather than one per pass.
    private var seeded: Set<String> = []

    public init(
        locator: SubagentLocator = SubagentLocator(),
        reader: TranscriptReader,
        store: (any SubagentTotalStoring)? = nil
    ) {
        self.locator = locator
        self.reader = reader
        self.store = store
    }

    /// Reads new records for every subagent of a session and returns the full
    /// current set, newest activity first.
    public func refresh(sessionID: String, workingDirectory: String) -> [AISubagent] {
        seedIfNeeded(sessionID: sessionID)

        let listing = locator.listSubagents(forSession: sessionID, workingDirectory: workingDirectory)
        let descriptors = listing ?? []
        // Nil means the directory could not be listed, which is not the same
        // fact as "this session has no subagents" and must not drive a delete.
        let directoryWasRead = listing != nil
        var ids: Set<String> = []

        for descriptor in descriptors {
            ids.insert(descriptor.id)
            let delta = reader.readIncremental(
                atPath: descriptor.transcriptPath,
                cursorKey: Self.cursorKey(for: descriptor)
            )

            // The descriptor is the authority on labels and the accumulator on
            // figures. A `meta.json` that has gone unreadable this pass leaves
            // the labels already held rather than blanking them.
            let previous = accumulated[descriptor.id]
            var current = AISubagent(
                id: descriptor.id,
                parentSessionID: descriptor.parentSessionID,
                agentType: descriptor.agentType ?? previous?.agentType,
                taskDescription: descriptor.taskDescription ?? previous?.taskDescription,
                usage: previous?.usage ?? .zero,
                currentActivity: previous?.currentActivity,
                model: previous?.model,
                lastActivityAt: previous?.lastActivityAt,
                recordsParsed: previous?.recordsParsed ?? 0,
                spawnDepth: descriptor.spawnDepth
            )
            // A delta that parsed nothing and carried nothing leaves the total
            // exactly where it was, so writing it back would cost a statement
            // on every filesystem event and buy nothing. Same reason the engine
            // skips an unchanged session upsert.
            let changed = delta.recordsParsed > 0 || delta.usage != .zero

            current.usage += delta.usage
            current.recordsParsed += delta.recordsParsed
            if let activity = delta.latestActivity { current.currentActivity = activity }
            if let model = delta.latestModel { current.model = model }
            if let stamp = delta.latestTimestamp {
                current.lastActivityAt = max(stamp, current.lastActivityAt ?? stamp)
            }
            accumulated[descriptor.id] = current

            if changed { store?.upsertSubagentTotal(SubagentTotal(current)) }
        }

        // A subagent that disappeared from disk drops its accumulator, so a
        // reused id cannot inherit a stale total.
        //
        // Guarded on the directory having actually been read. `subagents` used
        // to return an empty array both for a session with no subagents and for
        // a directory it could not read, and this branch treats empty as "they
        // all vanished". One unreadable pass, from a rename or a permissions
        // blip, therefore deleted every persisted total and reset the
        // accumulators to zero against cursors already at end of file.
        if directoryWasRead, let previous = byParent[sessionID] {
            let stale = previous.subtracting(ids)
            if !stale.isEmpty {
                for id in stale { accumulated[id] = nil }
                // Its row goes for the same reason. The store deletes by
                // session, so the survivors are written back rather than
                // removed one at a time: a vanished transcript is rare, and a
                // per-subagent delete would widen the seam the integrator has
                // to implement for no gain on the hot path.
                if let store {
                    store.deleteSubagentTotals(forSession: sessionID)
                    for id in ids {
                        if let live = accumulated[id] { store.upsertSubagentTotal(SubagentTotal(live)) }
                    }
                }
            }
        }
        byParent[sessionID] = ids

        return ids
            .compactMap { accumulated[$0] }
            .sorted { ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast) }
    }

    /// Drops the in-memory state for a session's subagents. Called when the
    /// session itself ends.
    ///
    /// The persisted rows deliberately stay. They pair with the read cursors,
    /// and nothing deletes a cursor: dropping one half leaves a transcript
    /// resumable at byte N with a total of zero, so a session brought back with
    /// `claude --resume` counts only what is appended afterwards. The engine
    /// then writes that collapsed figure to the session row and `applyRollup`
    /// subtracts the old combined total and adds the small one, so the day's
    /// rollup drops by everything the subagents had spent. `recomputeRollups`
    /// cannot repair it, because the session row was overwritten too.
    ///
    /// This mirrors what already happens on the parent side, where `markEnded`
    /// keeps the session row and `seedIfNeeded` reads it back. The asymmetry
    /// was the bug.
    ///
    /// A recycled id cannot inherit these totals: a subagent id is namespaced
    /// by its parent session id, and a parent session id is a UUID from Claude
    /// Code rather than a pid.
    public func forget(sessionID: String) {
        seeded.remove(sessionID)
        guard let ids = byParent.removeValue(forKey: sessionID) else { return }
        for id in ids { accumulated[id] = nil }
    }

    /// Folds a session's persisted totals into the accumulators, once.
    ///
    /// The read cursors are durable, so a subagent transcript resumes at the
    /// byte offset it reached last run. Without this, every token written
    /// before that offset is lost from the live figure: the delta is added to
    /// zero rather than to what it continues.
    ///
    /// Seeded ids join `byParent` as well, so a subagent whose transcript is
    /// gone is detected as stale on this very pass instead of lingering.
    private func seedIfNeeded(sessionID: String) {
        guard let store, seeded.insert(sessionID).inserted else { return }
        let totals = store.subagentTotals(forSession: sessionID)
        guard !totals.isEmpty else { return }

        var ids = byParent[sessionID] ?? []
        for total in totals {
            ids.insert(total.subagentID)
            // Anything already in memory was accumulated this run and is at
            // least as current as the row it was written from.
            if accumulated[total.subagentID] == nil {
                accumulated[total.subagentID] = total.subagent
            }
        }
        byParent[sessionID] = ids
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
