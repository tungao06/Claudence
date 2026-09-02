import Foundation

/// Idle cost is the product's whole point, so the pipeline counts itself.
///
/// Every stage that can run without a user asking for anything increments a
/// counter here. `Claudence --diagnose --counters` runs the real watcher and
/// engine headless for a while and prints these, which is how the idle CPU
/// question gets answered with numbers instead of a guess. See spec section 13.
///
/// Increments are a lock plus an add. At the rates these stages actually run
/// (single-digit events per minute) the counters are free; they are always on
/// so a report can be produced from a running app without a special build.
public final class EngineCounters: @unchecked Sendable {

    public static let shared = EngineCounters()

    /// One immutable reading. Deltas are taken by subtracting two of these.
    public struct Reading: Sendable, Equatable {
        public var fsEventCallbacks = 0
        public var debouncedRefreshes = 0
        public var sessionRefreshes = 0
        public var snapshotPublishes = 0
        public var suppressedPublishes = 0
        public var discoveries = 0
        public var livenessChecks = 0
        public var livenessCacheHits = 0
        public var transcriptReads = 0
        public var transcriptReadsWithData = 0
        public var usageFetches = 0
        /// Sessions left untouched for a pass because the store did not answer
        /// the read that seeds their accumulated total. Expected to be zero; a
        /// non-zero value is a store fault made visible rather than a silent
        /// skip.
        public var skippedUnseededSessions = 0
        /// Sessions whose subagents were left untouched for a pass because the
        /// store did not answer the read that seeds their totals. Counted apart
        /// from `skippedUnseededSessions` because the two skips are different
        /// faults with different consequences: that one freezes the whole
        /// session row, this one leaves the parent read normally while its
        /// subagent figure is withheld. Summed into one number, a diagnostic
        /// report could not say which half of the pipeline the store is
        /// failing.
        public var skippedUnseededSubagents = 0
        /// Sessions left untouched for a pass because the store did not answer
        /// the read that says where the transcript reader left off. A cursor
        /// taken as zero re-scans a file whose records are already counted, so
        /// this skip prevents an overcount where the two above prevent an
        /// undercount. Expected to be zero.
        public var skippedUnreadCursors = 0
        /// The same skip on a subagent's own cursor, counted apart for the
        /// same reason the seeds are: one number could not say which half of
        /// the pipeline the store is failing.
        public var skippedUnreadSubagentCursors = 0

        public init() {}
    }

    private let lock = NSLock()
    private var reading = Reading()

    private init() {}

    public var snapshot: Reading {
        lock.lock(); defer { lock.unlock() }
        return reading
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        reading = Reading()
    }

    // MARK: - Increments

    func countFSEventCallback() { bump { $0.fsEventCallbacks += 1 } }
    func countDebouncedRefresh() { bump { $0.debouncedRefreshes += 1 } }
    func countSessionRefresh() { bump { $0.sessionRefreshes += 1 } }
    func countSnapshotPublish() { bump { $0.snapshotPublishes += 1 } }
    func countSuppressedPublish() { bump { $0.suppressedPublishes += 1 } }
    func countDiscovery() { bump { $0.discoveries += 1 } }
    func countLivenessCheck() { bump { $0.livenessChecks += 1 } }
    func countLivenessCacheHit() { bump { $0.livenessCacheHits += 1 } }
    func countTranscriptRead(withData: Bool) {
        bump {
            $0.transcriptReads += 1
            if withData { $0.transcriptReadsWithData += 1 }
        }
    }
    func countUsageFetch() { bump { $0.usageFetches += 1 } }
    func countSkippedUnseededSession() { bump { $0.skippedUnseededSessions += 1 } }
    func countSkippedUnseededSubagents() { bump { $0.skippedUnseededSubagents += 1 } }
    func countSkippedUnreadCursor() { bump { $0.skippedUnreadCursors += 1 } }
    func countSkippedUnreadSubagentCursor() { bump { $0.skippedUnreadSubagentCursors += 1 } }

    private func bump(_ mutate: (inout Reading) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&reading)
    }
}

// MARK: - Reporting

extension EngineCounters.Reading {
    /// Field-by-field difference, for "what happened during this window".
    public func delta(since earlier: EngineCounters.Reading) -> EngineCounters.Reading {
        var result = EngineCounters.Reading()
        result.fsEventCallbacks = fsEventCallbacks - earlier.fsEventCallbacks
        result.debouncedRefreshes = debouncedRefreshes - earlier.debouncedRefreshes
        result.sessionRefreshes = sessionRefreshes - earlier.sessionRefreshes
        result.snapshotPublishes = snapshotPublishes - earlier.snapshotPublishes
        result.suppressedPublishes = suppressedPublishes - earlier.suppressedPublishes
        result.discoveries = discoveries - earlier.discoveries
        result.livenessChecks = livenessChecks - earlier.livenessChecks
        result.livenessCacheHits = livenessCacheHits - earlier.livenessCacheHits
        result.transcriptReads = transcriptReads - earlier.transcriptReads
        result.transcriptReadsWithData = transcriptReadsWithData - earlier.transcriptReadsWithData
        result.usageFetches = usageFetches - earlier.usageFetches
        result.skippedUnseededSessions = skippedUnseededSessions - earlier.skippedUnseededSessions
        result.skippedUnseededSubagents = skippedUnseededSubagents - earlier.skippedUnseededSubagents
        result.skippedUnreadCursors = skippedUnreadCursors - earlier.skippedUnreadCursors
        result.skippedUnreadSubagentCursors =
            skippedUnreadSubagentCursors - earlier.skippedUnreadSubagentCursors
        return result
    }

    /// Ordered for printing: name, count, and rate over `seconds`.
    public func lines(over seconds: TimeInterval) -> [String] {
        let span = max(seconds, 0.001)
        let rows: [(String, Int)] = [
            ("fsevent callbacks", fsEventCallbacks),
            ("debounced refreshes", debouncedRefreshes),
            ("session refreshes", sessionRefreshes),
            ("discoveries", discoveries),
            ("liveness checks", livenessChecks),
            ("liveness cache hits", livenessCacheHits),
            ("transcript reads", transcriptReads),
            ("  with new data", transcriptReadsWithData),
            ("snapshot publishes", snapshotPublishes),
            ("suppressed publishes", suppressedPublishes),
            ("usage fetches", usageFetches),
            ("skipped unseeded", skippedUnseededSessions),
            ("  subagent seeds", skippedUnseededSubagents),
            ("skipped cursors", skippedUnreadCursors),
            ("  subagent cursors", skippedUnreadSubagentCursors),
        ]
        return rows.map { name, count in
            let padded = name.padding(toLength: 22, withPad: " ", startingAt: 0)
            return String(format: "  %@ %6d   %6.2f/s", padded, count, Double(count) / span)
        }
    }
}
