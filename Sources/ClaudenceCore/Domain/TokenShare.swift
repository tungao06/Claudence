import Foundation

/// One component's fraction of a `TokenUsage` total.
///
/// Three views computed this by hand off the same two numbers, each with its
/// own copy of the one rule that matters: a share of a zero total is
/// undefined, not zero, so it must come back `nil` rather than `Double.nan` or
/// a printed `0%` that looks like a real measurement. `Tooltip.swift`,
/// `SessionDetailView.swift` and `TokenBreakdownCard.swift` each guarded
/// `total > 0` and divided, three times, and a fourth call site could as
/// easily have forgotten the guard as copied it correctly. This is the one
/// place the division happens now.
extension TokenUsage {
    /// `amount` as a fraction of `total`. `nil` when `total` is zero: nothing
    /// was spent, so there is nothing to take a share of.
    ///
    /// `amount` is taken as given rather than validated against the usage's
    /// own categories, so a caller may ask for the share of any figure drawn
    /// from this total — a single category, or a sum of several — and the
    /// same guard against a zero denominator covers all of them.
    public func share(of amount: Int) -> Double? {
        guard total > 0 else { return nil }
        return Double(amount) / Double(total)
    }
}
