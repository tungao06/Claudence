import Foundation

// MARK: - What can be gated

/// A capability Claudence already has, named so a paid tier could gate it
/// later without inventing a new seam at that point.
///
/// Every case corresponds to code that exists today, not a feature on a
/// roadmap:
///
/// - `.dashboardAnalytics` — `AnalyticsService`: project breakdown, day over
///   day, and the hourly/daily series behind the dashboard.
/// - `.costEstimation` — `CostEstimator`: the per-model dollar estimate,
///   always labelled "Estimated", never a fabricated number for an unpriced
///   model.
/// - `.usageProjection` — `UsageProjector` and `BurnAttribution`: the
///   percent-per-minute exhaustion projection for a usage window, landed
///   2026-09-03.
/// - `.notifications` — `EventDeriver` plus `NotificationBridge`: usage
///   threshold and session lifecycle notifications through
///   `UNUserNotificationCenter`.
/// - `.subagentTracking` — `SubagentTracker`: per-subagent token totals and
///   task descriptions, read under the privacy allowlist.
/// - `.historyImport` — `HistoryImporter`: the one-time import of transcript
///   history already on disk into the store's daily rollups.
///
/// Adding a case is the same kind of amendment as adding a field to the
/// privacy allowlist: it names a capability that already shipped, not one
/// this file is trying to justify into existence.
public enum Feature: String, Sendable, CaseIterable {
    case dashboardAnalytics
    case costEstimation
    case usageProjection
    case notifications
    case subagentTracking
    case historyImport
}

// MARK: - The seam

/// Answers whether the running build grants a `Feature`.
///
/// ## Why this seam exists when `AIProviderType` was deleted for the opposite reason
///
/// `AIProviderType` was a seam with one implementation and no planned second;
/// PLAN.md 9.10e removes it because Claude Code is the only provider this
/// project will ever support, and a case for `codex` or `geminiCLI` that
/// nothing will ever construct is a claim the code makes that the product
/// does not. Judged by that same test, `Entitlement` looks identical: one
/// implementation, no second one under construction.
///
/// The difference is not "this one might be useful" — that argument does not
/// survive the `AIProviderType` precedent and this comment is not going to
/// pretend otherwise. The difference is where the amendment has to happen.
/// The privacy contract in CLAUDE.md is exact about outbound requests: two
/// today, both on the usage path, and "a licence check, if one is ever built,
/// is the third outbound request and this document is amended before it is
/// written, not after." A provider seam has no comparable document to
/// violate by being added carelessly — a second `AIProviderType` case is just
/// more code. A licence check is a new fact for a document that currently
/// makes a closed, countable claim, and that claim needs a place to attach
/// *before* anyone reaches for `URLSession` to build one. `Entitlement`
/// is that place: `FullEntitlement` makes the current truth ("everything is
/// on, nothing is checked") a type the compiler can see, so the day someone
/// adds a second implementation that calls out to a server, the diff is
/// visibly "a new `Entitlement` conformance" next to "the privacy contract's
/// request count changed from two to three" — a precondition on the change
/// rather than a paragraph someone has to remember to go write afterward.
///
/// If that argument does not hold — if a comment in the licence-checking
/// implementation would have done the same job without this file existing
/// today — then this seam is exactly the thing 9.10e just deleted a copy of,
/// and should be deleted too rather than kept out of hope.
public protocol Entitlement: Sendable {
    /// True when `feature` is available in this build. Must return
    /// synchronously and must not perform I/O: no file access, no network
    /// request, no Keychain read. A future implementation that needs to ask
    /// a server is a new outbound request and an amendment to the privacy
    /// contract before it is written.
    func isGranted(_ feature: Feature) -> Bool
}

/// The only implementation that ships. Every `Feature` is granted,
/// unconditionally, with no state and no I/O — there is nothing to configure
/// because there is no second tier yet to withhold anything for.
public struct FullEntitlement: Entitlement {
    public init() {}

    public func isGranted(_ feature: Feature) -> Bool {
        true
    }
}
