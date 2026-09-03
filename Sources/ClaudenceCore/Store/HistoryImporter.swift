import Foundation

/// Walks the transcripts already on disk and writes them into the store, so
/// the 242 MB `~/.claude/projects` corpus stops being 242 MB the database
/// cannot answer questions about.
///
/// This is not a second parser. Every byte it reads goes through
/// `TranscriptReader` and `SubagentLocator`, the same adapters the live path
/// uses, so the privacy allowlist and the cursor discipline apply exactly
/// once. What this type adds is only the walk over the filesystem and the
/// decisions about what a *historical* row means, which the live path never
/// had to make.
///
/// ## No liveness gate
///
/// Discovery of a *live* session is gated on `kill(pid, 0)` plus a matching
/// `procStart` (`SessionRegistryAdapter.isAlive`). Every session this type
/// imports has a dead PID by construction -- it is reading a file, not
/// probing a process -- so that gate is never asked. `pid` is written as `0`
/// and `procStart` as `""`: `0` is not a process id `kill` can ever answer
/// for (`SessionRegistryAdapter.isAlive` refuses any `pid <= 0` before it
/// looks at `procStart` at all), so an imported row can never be mistaken for
/// a live one even if a future reader forgets this comment. `status` is
/// written as `.completed`, which is simply true: nothing that predates this
/// process's own launch is still running, and `.completed` is what
/// `ClaudenceStore.upsert(session:)` reads as "set `ended_at`".
///
/// ## Day attribution
///
/// `TranscriptDelta.usageByDay` gives an exact per-day split of what a
/// session's own transcript spent, because every assistant record carries its
/// own `message.usage` rather than a running total. This type turns that into
/// one cumulative `usage_samples` row per day the parent transcript touched,
/// so `ClaudenceStore.recomputeRollups` -- called once at the end of the
/// whole walk -- files the session on every day it actually ran on rather
/// than only the day it started.
///
/// Subagent activity is not split by day the same way: a subagent transcript
/// produces its own `usageByDay`, but folding it into the parent's samples
/// would need the two to be merged in time order for the running total to
/// stay monotonic, which is more machinery than the one path that actually
/// needs day-accuracy -- the parent's -- justifies. The gap this leaves is
/// not a lost token: `recomputeRollups` already treats "the samples measure
/// less than the session's stored total" as ordinary, and hands the shortfall
/// to the session's last-activity day. That is the same fallback a live
/// session takes when its subagent directory cannot be listed for a pass.
///
/// ## Re-running
///
/// A cursor and its total are written together, exactly as the live path
/// insists on. `bytesParsed` in the report is measured from the same
/// cursors: the byte offset before a file is read, subtracted from the byte
/// offset after. A second run over the same files reads zero new bytes,
/// contributes zero new samples (`usageByDay` comes back empty when nothing
/// new was parsed), and writes the same totals it wrote the first time -- an
/// upsert with unchanged values nets to no rollup movement, the same way any
/// other unchanged upsert does.
///
/// Re-running for an earlier start date after clearing a range is the
/// caller's responsibility, and it needs to clear the sessions' read cursors
/// along with their rows: this type deliberately does not special-case a
/// skipped session's cursor, so a session skipped once has its cursor
/// advanced to end of file like any other read one. That is the same
/// invariant this codebase already writes down for deletion in general -- a
/// `sessions` row and its `read_cursors` row move together or not at all --
/// applied here rather than re-solved.
public struct HistoryImporter: Sendable {

    // MARK: - Report

    /// A file the importer could not finish with, and why.
    public struct Failure: Sendable, Equatable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    /// Why a session on disk was not written.
    public enum SkipReason: Sendable, Equatable {
        /// Its last activity, parsed from its own transcript, is before the
        /// import's start date.
        case beforeStartDate
    }

    public struct SkippedSession: Sendable, Equatable {
        public let sessionID: String
        public let path: String
        public let reason: SkipReason

        public init(sessionID: String, path: String, reason: SkipReason) {
            self.sessionID = sessionID
            self.path = path
            self.reason = reason
        }
    }

    /// What one call to `importHistory(startingFrom:)` found.
    ///
    /// Every count here is about what was *read*, not what changed: a second,
    /// idempotent run over the same files reports the same `sessionsImported`
    /// and `subagentFilesRead` it did the first time, with `bytesParsed` at
    /// zero. An import that cannot tell the difference between "already
    /// current" and "never happened" is not trustworthy, so both are counted
    /// the same way here rather than one being silently dropped.
    public struct Report: Sendable, Equatable {
        public var projectsSeen = 0
        public var sessionsImported = 0
        public var sessionsSkipped: [SkippedSession] = []
        public var subagentFilesRead = 0
        public var bytesParsed: UInt64 = 0
        public var failures: [Failure] = []

        public init(
            projectsSeen: Int = 0,
            sessionsImported: Int = 0,
            sessionsSkipped: [SkippedSession] = [],
            subagentFilesRead: Int = 0,
            bytesParsed: UInt64 = 0,
            failures: [Failure] = []
        ) {
            self.projectsSeen = projectsSeen
            self.sessionsImported = sessionsImported
            self.sessionsSkipped = sessionsSkipped
            self.subagentFilesRead = subagentFilesRead
            self.bytesParsed = bytesParsed
            self.failures = failures
        }
    }

    // MARK: - Dependencies

    private let projectsDirectory: URL
    private let store: any ClaudenceStoring & SubagentTotalStoring
    private let reader: TranscriptReader
    private let subagentLocator: SubagentLocator
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - projectsDirectory: `~/.claude/projects` by default. Overridden in
    ///     tests so nothing ever walks the real directory.
    ///   - store: written to exactly through `ClaudenceStoring` and
    ///     `SubagentTotalStoring`, the same seam the engine and the subagent
    ///     tracker use. Must be the same store `reader` was built with --
    ///     `bytesParsed` is measured by reading this store's own cursors
    ///     before and after each file, so a mismatched pair would make that
    ///     figure meaningless without affecting correctness anywhere else.
    ///   - reader: the live path's own `TranscriptReader`, so a cursor this
    ///     importer writes and one the engine writes are the same kind of
    ///     fact.
    ///   - calendar: only for reconstructing a `Date` inside a day string
    ///     `TranscriptDelta.usageByDay` already bucketed by; must match the
    ///     calendar `reader` and `store` were given, or a day's sample could
    ///     be stamped just outside the day it is meant to represent.
    ///   - now: injected so a test controls what "no timestamp could be
    ///     found anywhere in this file" falls back to.
    public init(
        projectsDirectory: URL = Constants.projectsDirectory,
        store: any ClaudenceStoring & SubagentTotalStoring,
        reader: TranscriptReader,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.projectsDirectory = projectsDirectory
        self.store = store
        self.reader = reader
        self.subagentLocator = SubagentLocator(projectsDirectory: projectsDirectory)
        self.calendar = calendar
        self.now = now
    }

    // MARK: - Import

    /// Walks every `<slug>/<sessionId>.jsonl` under the projects directory and
    /// imports each one whose last activity is at or after `startDate`.
    ///
    /// An absent projects directory is the ordinary "Claude Code has never
    /// run here" state, not a failure: it comes back as an empty report.
    public func importHistory(startingFrom startDate: Date) -> Report {
        var report = Report()
        let fileManager = FileManager.default

        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return report
        }

        var importedAnything = false

        for project in projects.sorted(by: { $0.path < $1.path }) where isDirectory(project, fileManager: fileManager) {
            report.projectsSeen += 1
            guard let entries = try? fileManager.contentsOfDirectory(
                at: project,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                report.failures.append(Failure(path: project.path, reason: "cannot list project directory"))
                continue
            }

            let transcripts = entries.filter { $0.pathExtension == "jsonl" }
            for transcript in transcripts.sorted(by: { $0.path < $1.path }) {
                if importSession(at: transcript, startDate: startDate, into: &report) {
                    importedAnything = true
                }
            }
        }

        // The incremental write inside `upsert(session:)` files a session's
        // whole spend on the day it started; only the repair splits it across
        // every day `usageByDay` recorded a sample for. Skipped when nothing
        // was written, so an import that only confirms it has nothing left to
        // do does not pay for a full rebuild.
        if importedAnything {
            store.recomputeRollups()
        }

        return report
    }

    // MARK: - One session

    /// - Returns: whether anything was written for this session.
    private func importSession(at transcriptURL: URL, startDate: Date, into report: inout Report) -> Bool {
        let sessionID = transcriptURL.deletingPathExtension().lastPathComponent
        let path = transcriptURL.path

        guard FileManager.default.isReadableFile(atPath: path) else {
            report.failures.append(Failure(path: path, reason: "not readable"))
            return false
        }

        let existing = store.session(id: sessionID)
        let before = store.cursor(forSession: sessionID)?.byteOffset ?? 0
        let delta = reader.readIncremental(atPath: path, cursorKey: sessionID)

        guard delta.outcome == .read else {
            report.failures.append(Failure(path: path, reason: "cursor store did not answer"))
            return false
        }

        let after = store.cursor(forSession: sessionID)?.byteOffset ?? before
        if after > before { report.bytesParsed += after - before }

        let startedAt = existing?.startedAt ?? delta.earliestTimestamp ?? now()
        let lastActivityAt = max(
            existing?.lastActivityAt ?? .distantPast,
            delta.latestTimestamp ?? existing?.lastActivityAt ?? startedAt
        )

        guard lastActivityAt >= startDate else {
            report.sessionsSkipped.append(SkippedSession(sessionID: sessionID, path: path, reason: .beforeStartDate))
            return false
        }

        let workingDirectory = delta.workingDirectory ?? existing?.workingDirectory
            // The transcript never recorded its own `cwd` (seen on very old
            // files). The slug is not reversible -- it replaced every `/`
            // with `-` -- so the project directory's own name is kept as an
            // honest last resort rather than a guessed path.
            ?? transcriptURL.deletingLastPathComponent().lastPathComponent
        let projectName = existing?.projectName ?? HistoryImporter.projectName(forWorkingDirectory: workingDirectory)

        let usage = (existing?.usage ?? .zero) + delta.usage
        // Exact, the same way `usage` above is: `delta.usageByModel` is a sum
        // of real records' own model fields, not a guess, and folding it onto
        // whatever was already stored is the same additive rule the scalar
        // total follows.
        let usageByModel = mergeUsageByModel(existing?.usageByModel ?? [:], delta.usageByModel)

        let (subagentUsage, subagentCount, subagentUsageByModel) = importSubagents(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            existing: existing,
            into: &report
        )

        let session = AISession(
            id: sessionID,
            pid: 0,
            procStart: "",
            projectName: projectName,
            workingDirectory: workingDirectory,
            status: .completed,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            usage: usage,
            subagentUsage: subagentUsage,
            subagentCount: subagentCount,
            usageByModel: usageByModel,
            subagentUsageByModel: subagentUsageByModel,
            model: delta.latestModel ?? existing?.model,
            claudeCodeVersion: existing?.claudeCodeVersion
        )
        store.upsert(session: session)

        writeDaySamples(sessionID: sessionID, delta: delta, baselineBeforeThisRun: existing?.combinedUsage ?? .zero)

        report.sessionsImported += 1
        return true
    }

    /// Reads every subagent transcript belonging to a session and returns the
    /// measured total, the same "measured, not accumulated blind" rule
    /// `SubagentTracker.refresh` follows: the figure is the sum of what was
    /// just read, not last run's figure plus a delta, so a subagent whose
    /// file vanished between two imports cannot leave a stale total behind.
    private func importSubagents(
        sessionID: String,
        workingDirectory: String,
        existing: AISession?,
        into report: inout Report
    ) -> (usage: TokenUsage, count: Int, usageByModel: [String: TokenUsage]) {
        guard let descriptors = subagentLocator.listSubagents(
            forSession: sessionID,
            workingDirectory: workingDirectory
        ) else {
            let directory = subagentLocator.directory(forSession: sessionID, workingDirectory: workingDirectory)
            report.failures.append(
                Failure(path: directory?.path ?? "\(workingDirectory)/subagents", reason: "cannot list subagent directory")
            )
            return (
                existing?.subagentUsage ?? .zero,
                existing?.subagentCount ?? 0,
                existing?.subagentUsageByModel ?? [:]
            )
        }
        guard !descriptors.isEmpty else { return (.zero, 0, [:]) }

        let existingTotals = Dictionary(
            uniqueKeysWithValues: store.subagentTotals(forSession: sessionID).map { ($0.subagentID, $0) }
        )

        var measured = TokenUsage.zero
        var measuredByModel: [String: TokenUsage] = [:]
        for descriptor in descriptors {
            let previous = existingTotals[descriptor.id]
            let before = store.cursor(forSession: SubagentTracker.cursorKey(for: descriptor))?.byteOffset ?? 0
            let delta = reader.readIncremental(
                atPath: descriptor.transcriptPath,
                cursorKey: SubagentTracker.cursorKey(for: descriptor)
            )

            guard delta.outcome == .read else {
                report.failures.append(Failure(path: descriptor.transcriptPath, reason: "cursor store did not answer"))
                // The last known figure for this one subagent still counts
                // toward the session's measured total; only its own file
                // failed to answer this pass.
                if let previous {
                    measured += previous.usage
                    measuredByModel = mergeUsageByModel(measuredByModel, previous.usageByModel)
                }
                continue
            }

            let after = store.cursor(forSession: SubagentTracker.cursorKey(for: descriptor))?.byteOffset ?? before
            if after > before { report.bytesParsed += after - before }
            report.subagentFilesRead += 1

            let usage = (previous?.usage ?? .zero) + delta.usage
            let usageByModel = mergeUsageByModel(previous?.usageByModel ?? [:], delta.usageByModel)
            let total = SubagentTotal(
                parentSessionID: sessionID,
                subagentID: descriptor.id,
                agentType: descriptor.agentType ?? previous?.agentType,
                taskDescription: descriptor.taskDescription ?? previous?.taskDescription,
                usage: usage,
                usageByModel: usageByModel,
                recordsParsed: (previous?.recordsParsed ?? 0) + delta.recordsParsed,
                lastActivityAt: [previous?.lastActivityAt, delta.latestTimestamp].compactMap { $0 }.max(),
                model: delta.latestModel ?? previous?.model
            )
            store.upsertSubagentTotal(total)
            measured += usage
            measuredByModel = mergeUsageByModel(measuredByModel, usageByModel)
        }

        return (measured, descriptors.count, measuredByModel)
    }

    /// One cumulative `usage_samples` row per local day `delta.usageByDay`
    /// recorded, so a session that ran past midnight is split across every
    /// day it touched rather than filed only on the day it started. See the
    /// type doc for why this uses the parent transcript's own split and
    /// leaves subagent activity to `recomputeRollups`'s existing shortfall
    /// handling.
    private func writeDaySamples(sessionID: String, delta: TranscriptDelta, baselineBeforeThisRun: TokenUsage) {
        guard !delta.usageByDay.isEmpty else { return }
        // Guaranteed non-nil here: `usageByDay` is only ever populated from a
        // record that also set `latestTimestamp`, in the same pass.
        let latest = delta.latestTimestamp ?? now()

        var running = baselineBeforeThisRun
        for day in delta.usageByDay.keys.sorted() {
            running += delta.usageByDay[day] ?? .zero
            let stamp = referenceInstant(forDay: day) ?? latest
            store.recordUsageSample(sessionID: sessionID, usage: running, at: stamp)
        }
    }

    /// A `Date` guaranteed to fall on `day` (a `ClaudenceStore.dayString`
    /// value) under this importer's own calendar, so the sample lands back on
    /// the same day it was bucketed under. Midday rather than midnight,
    /// clear of the boundary a daylight-saving transition could otherwise
    /// push a midnight instant across.
    private func referenceInstant(forDay day: String) -> Date? {
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = dayOfMonth
        components.hour = 12
        return calendar.date(from: components)
    }

    /// `name` when the registry supplied one; imported rows have no registry,
    /// so this always takes the fallback `RegistryRecord.displayName` uses:
    /// the last path component of the working directory.
    private static func projectName(forWorkingDirectory workingDirectory: String) -> String {
        let leaf = (workingDirectory as NSString).lastPathComponent
        return leaf.isEmpty ? workingDirectory : leaf
    }

    private func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }
}
