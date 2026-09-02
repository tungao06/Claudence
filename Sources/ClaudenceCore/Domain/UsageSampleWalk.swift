import Foundation

/// The one walk over `usage_samples` that turns running totals into the rises
/// between them.
///
/// Three callers ask the same question of the same rows: the hourly chart
/// buckets the rises by hour, the window share buckets them by session, and
/// the rollup repair buckets them by local day. The rule they share is not
/// obvious and has been got wrong once already, so it lives here once rather
/// than in three copies that can drift apart.
///
/// It sits beside `UsageSampleRow` rather than inside `AnalyticsService`
/// because it is a fact about the rows, and because the store cannot depend on
/// the analytics layer that reads it.
enum UsageSampleWalk {

    /// Walks sample rows in store order and hands each session's rise inside
    /// `range` to `body`, as `(sessionID, sampledAt, delta)`.
    ///
    /// `body` runs for a session exactly when that session has something to
    /// difference, which is what makes "not derivable" distinguishable from
    /// "zero": a session `body` is never called for has no in-range figure,
    /// while one called with a zero delta was measurably idle.
    ///
    /// - Parameters:
    ///   - rows: from `ClaudenceStore.usageSamples(in:)`, so each session's
    ///     rows are in time order and are preceded by the last sample taken
    ///     before the range where one exists.
    ///   - range: the span whose buckets are being filled. A row outside it
    ///     still sets a floor and never opens a bucket of its own.
    ///   - sessionStarts: when each session began, used only to recognise the
    ///     one case where a first sample carries no history from before it.
    ///     Passed as the dates rather than as a pre-filtered set so the rule
    ///     that reads them stays here with the walk.
    static func enumerateIncreases(
        in rows: [UsageSampleRow],
        range: Range<Date>,
        sessionStarts: [String: Date],
        body: (_ sessionID: String, _ sampledAt: Date, _ delta: TokenUsage) -> Void
    ) {
        // A session that began inside the range is the one case where a first
        // sample carries no history from before it.
        //
        // The first sample a session ever has is a special case with two wrong
        // answers available. Counting its whole total puts every token the
        // session spent before Claudence started watching into one bucket,
        // which draws a spike that never happened; discarding it loses
        // everything the session spent before its second sample, which for a
        // short session is nearly all of it. It is counted only when the
        // session also *started* inside the range, which is the case where the
        // total genuinely belongs to the range and to no earlier bucket.
        let startedInRange = Set(
            sessionStarts.filter { range.contains($0.value) }.map(\.key)
        )

        // The highest running total each session has reached, not merely the
        // sample before this one. `usage_samples` is not monotonic, and against
        // the previous sample alone every token between the floor of a
        // regression and the level it fell from is counted a second time on the
        // way back up.
        var peak: [String: TokenUsage] = [:]
        for row in rows {
            let mark = peak[row.sessionID]
            peak[row.sessionID] = higher(mark ?? .zero, row.usage)

            let delta: TokenUsage
            if let mark {
                delta = increase(from: mark, to: row.usage)
            } else if startedInRange.contains(row.sessionID) {
                delta = row.usage
            } else {
                // The baseline row, or a session whose history predates the
                // range. Either way it establishes a floor and contributes
                // nothing of its own.
                continue
            }

            // The baseline row sits before the range and must not open a bucket
            // of its own even when it is also a session's first sample.
            guard range.contains(row.sampledAt) else { continue }
            body(row.sessionID, row.sampledAt, delta)
        }
    }

    /// The rise of a running total above the highest it has already reached,
    /// floored at zero per field.
    ///
    /// Totals only ever climb while a session lives, so a fall means the
    /// session's transcript was rotated or its cursor reset. Nothing is lost
    /// when that happens: the tokens below the mark were drawn when they were
    /// first observed. What the floor prevents is the opposite failure, of
    /// drawing them again as the counter climbs back to where it was, which is
    /// what measuring against the previous sample did. A negative bar would be
    /// a second, louder wrong answer.
    static func increase(from earlier: TokenUsage, to later: TokenUsage) -> TokenUsage {
        TokenUsage(
            freshInput: max(0, later.freshInput - earlier.freshInput),
            cacheCreation: max(0, later.cacheCreation - earlier.cacheCreation),
            cacheRead: max(0, later.cacheRead - earlier.cacheRead),
            output: max(0, later.output - earlier.output),
            thinking: max(0, later.thinking - earlier.thinking)
        )
    }

    /// The per-field maximum of two running totals.
    ///
    /// Per field rather than per total, because each field is its own
    /// cumulative counter and none of them can legitimately fall. Holding one
    /// mark against `total` would make a regression in any single field
    /// suppress the fields that kept climbing through it, and there would be no
    /// honest way to split a recovered total back across a breakdown the chart
    /// shows cache separately in.
    static func higher(_ lhs: TokenUsage, _ rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            freshInput: max(lhs.freshInput, rhs.freshInput),
            cacheCreation: max(lhs.cacheCreation, rhs.cacheCreation),
            cacheRead: max(lhs.cacheRead, rhs.cacheRead),
            output: max(lhs.output, rhs.output),
            thinking: max(lhs.thinking, rhs.thinking)
        )
    }

    /// The five component fields, so a routine that has to treat each counter
    /// separately can iterate them instead of spelling all five out.
    /// Computed rather than stored: a key path is not `Sendable`, and a
    /// static array of them is shared mutable state the compiler cannot vouch
    /// for. Building the five each time costs nothing next to the walk.
    static var fields: [WritableKeyPath<TokenUsage, Int>] {
        [\.freshInput, \.cacheCreation, \.cacheRead, \.output, \.thinking]
    }
}
