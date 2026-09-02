import Foundation

// MARK: - What "context used" honestly means
//
// A context window bounds the size of ONE request's input. It is not a budget
// the session draws down over its life.
//
// `TokenUsage` on a session is cumulative: `TranscriptReader.DeltaBuilder` does
// `usage += usageBlock.tokenUsage` for every assistant record it reads, so
// `session.usage.cacheRead` is the sum of every cache read the session has ever
// billed. On a long session that figure runs to tens of millions of tokens,
// which is an order of magnitude past any published limit. Dividing it by a
// context limit produces a percentage in the thousands: a number that looks
// like a measurement and is nothing of the kind.
//
// The honest input to this calculation is the `message.usage` block of a SINGLE
// assistant record, and specifically its billable input:
//
//     input_tokens + cache_creation_input_tokens + cache_read_input_tokens
//
// which is exactly `TokenUsage.billableInput`. Those three fields partition the
// prompt that request actually sent. Output is excluded: it is not part of that
// request's input, and whatever the model wrote reappears in the next request's
// input counts, so adding it here would double-count the turn.
//
// Nothing in the current build retains a single record's usage. The parser keeps
// the running total and the store keeps the running total; the last record's own
// usage block is read, added, and discarded. So every function here takes the
// per-request figure as a parameter rather than reaching for a session total,
// and there is no convenience overload that accepts an `AISession`. Adding one
// would be adding the exact wrong number.

// MARK: - One model's limit

/// The largest input a model accepts in one request, in tokens.
///
/// The figure is the model's maximum, which for the 1M-context models is also
/// the default. It is a claim made by this table, not something any transcript
/// or API response told us, so anything derived from it is an estimate.
public struct ModelContextWindow: Sendable, Equatable {
    /// The canonical model id this limit was recorded against.
    public let modelID: String
    public let displayName: String
    /// Maximum input tokens for a single request.
    public let maximumInputTokens: Int

    public init(modelID: String, displayName: String, maximumInputTokens: Int) {
        self.modelID = modelID
        self.displayName = displayName
        self.maximumInputTokens = maximumInputTokens
    }

    /// What fraction of the window one request's input occupies.
    ///
    /// Not clamped to 1. A figure above 1 means the caller passed something
    /// other than a single request's input, and silently clamping it would hide
    /// that mistake behind a plausible-looking 100%.
    /// Nil rather than zero for a non-positive limit, matching every other
    /// undefined ratio in this module. A zero here would render as "0% used",
    /// which is a measurement, and a limit we do not have is not a measurement.
    /// No shipped entry has a non-positive limit, but the initialiser is public
    /// and does not validate, so the case is reachable from outside.
    public func fraction(ofRequestInputTokens tokens: Int) -> Double? {
        guard maximumInputTokens > 0 else { return nil }
        return Double(max(0, tokens)) / Double(maximumInputTokens)
    }
}

// MARK: - What the display can say about one session

/// The three honest readings of a session's context, as a value the view maps
/// straight onto a layout instead of rederiving from two optionals.
///
/// It is here rather than in the view for the usual reason: the choice between
/// them is arithmetic over the domain, it is the part that can be wrong, and
/// the UI target has no test bundle. The view owns the wording and nothing else.
public enum ContextReading: Sendable, Equatable {
    /// Both halves in hand: draw the meter.
    ///
    /// `fraction` is not clamped, for the reason `ModelContextWindow.fraction`
    /// gives: a figure above 1 means the caller passed something other than one
    /// request's input, and hiding that behind a tidy 100% hides a bug.
    case measured(fraction: Double, requestInputTokens: Int, maximumInputTokens: Int)

    /// The size of the last request is known and the model's limit is not.
    ///
    /// Renders the figure with no meter and no percentage. There is no guessed
    /// denominator here and there must never be one: a share of an unstated
    /// quantity is exactly the fabricated number the spec forbids.
    case amountOnly(requestInputTokens: Int)

    /// No assistant record with a usage block has been read, so there is no
    /// numerator and nothing to show at all.
    case noRequestRead
}

// MARK: - The table

/// A per-model context-limit table, matched by the same rule as `ModelPricing`.
///
/// ## Matching rule
///
/// Deliberately identical to the price table's, and implemented by calling
/// `ModelPricing.normalize` and `ModelPricing.isSnapshotSuffix` rather than by
/// copying them. Two tables keyed on model id that disagreed about which ids
/// they cover would be a bug nobody would find quickly: a session could be
/// priced and not sized, or the reverse, for no reason a user could see.
///
/// So: exact match on the normalised id, then a snapshot fallback where
/// `<known id>-<snapshot>` resolves to `<known id>` and the longest known id
/// wins. Anything unmatched returns nil.
///
/// ## Provenance
///
/// Shares `PriceTableProvenance` with the price table for the same reason: the
/// two tables come from the same cached source on the same date, and the
/// staleness rule that applies to a published rate applies to a published
/// limit. A table older than the horizon is disclosed, not silently trusted.
public struct ContextWindowTable: Sendable, Equatable {
    public let entries: [ModelContextWindow]
    public let provenance: PriceTableProvenance

    public init(entries: [ModelContextWindow], provenance: PriceTableProvenance) {
        self.entries = entries
        self.provenance = provenance
    }

    // MARK: Lookup

    /// The context limit for a model id, or nil when the table does not cover it.
    ///
    /// Nil is never a default. It is not the largest known window, not the
    /// smallest, and not an average of the two. A caller that cannot size a
    /// model renders `Context window unavailable`, per `PLAN-UI.md` decision 1.
    public func window(for rawModelID: String?) -> ModelContextWindow? {
        guard let rawModelID else { return nil }
        let id = ModelPricing.normalize(rawModelID)
        guard !id.isEmpty else { return nil }

        if let exact = entries.first(where: { $0.modelID == id }) { return exact }

        if let long = longContextWindow(forNormalizedID: id) { return long }

        // Longest known id first, so a more specific family wins.
        for entry in entries.sorted(by: { $0.modelID.count > $1.modelID.count }) {
            let key = entry.modelID
            guard id.hasPrefix(key + "-") else { continue }
            let suffix = String(id.dropFirst(key.count + 1))
            if ModelPricing.isSnapshotSuffix(suffix) { return entry }
        }
        return nil
    }

    /// The marker Claude Code appends to name a model's 1M-context variant, as
    /// it appears in a model id: `claude-opus-5[1m]`.
    ///
    /// Lowercase, because `ModelPricing.normalize` has already lowercased the id
    /// by the time this is compared.
    static let longContextMarker = "[1m]"

    /// The window the marker states, in tokens. Decimal, like the table above.
    static let longContextTokens = 1_000_000

    /// The window a `[1m]`-marked id states about itself, or nil when the id
    /// carries no marker.
    ///
    /// This is the one entry in this file that is not a row of the table, and it
    /// is still not a guess: the suffix is the published name of the model's
    /// 1M-context variant, so reading it is a read of the id. That is why it
    /// applies even when the base model has no entry here. `claude-mythos-5` is
    /// deliberately unsized above because the source states no window for it,
    /// but `claude-mythos-5[1m]` states its own, and honouring one while
    /// refusing the other would be arbitrary.
    ///
    /// Only this exact marker is read. A different bracketed suffix states
    /// nothing this build knows how to interpret and resolves to nil, per the
    /// rule that an honest gap beats a plausible number.
    private func longContextWindow(forNormalizedID id: String) -> ModelContextWindow? {
        guard id.hasSuffix(Self.longContextMarker) else { return nil }
        let base = String(id.dropLast(Self.longContextMarker.count))
        guard !base.isEmpty else { return nil }

        // The base's own entry supplies a readable name when there is one; the
        // limit comes from the marker either way, never from the base entry.
        let name = window(for: base)?.displayName ?? base
        return ModelContextWindow(
            modelID: id,
            displayName: "\(name) (1M context)",
            maximumInputTokens: Self.longContextTokens
        )
    }

    public func covers(_ rawModelID: String?) -> Bool { window(for: rawModelID) != nil }

    /// Model ids this table sizes, sorted.
    public var knownModelIDs: [String] { entries.map(\.modelID).sorted() }

    // MARK: The used side

    /// What fraction of a model's context window one request's input occupies,
    /// or nil when the model is not in the table or its limit is unusable.
    ///
    /// - Parameter requestInputTokens: the billable input of a **single**
    ///   assistant record, never a session or daily total. See the note at the
    ///   top of this file for why the distinction is load-bearing.
    public func fractionUsed(requestInputTokens: Int, model: String?) -> Double? {
        // Flattened deliberately: both "no such model" and "no usable limit"
        // are the same answer to the caller, which is that there is no figure.
        window(for: model).flatMap { $0.fraction(ofRequestInputTokens: requestInputTokens) }
    }

    /// The same figure from a usage block.
    ///
    /// - Parameter requestUsage: the usage of a **single** assistant record.
    ///   `billableInput` is the part that occupies context; `output` is excluded
    ///   because it is not part of that request's input.
    ///
    /// Passing a cumulative session total here is a caller error that the
    /// arithmetic cannot detect, which is why the parameter is named for one
    /// request and no `AISession` overload exists.
    public func fractionUsed(requestUsage: TokenUsage, model: String?) -> Double? {
        fractionUsed(requestInputTokens: requestUsage.billableInput, model: model)
    }

    // MARK: What the display can honestly say

    /// Which of the three context readings the available facts support.
    ///
    /// The display used to have two states, meter or nothing, which collapsed
    /// two unrelated gaps into one sentence. Missing the numerator and missing
    /// the denominator are not the same situation: without a request read there
    /// is nothing to say, but with one in hand and no limit there is still a
    /// measured figure, and refusing to print it hides a fact the reader has.
    ///
    /// - Parameter requestUsage: the usage of a **single** assistant record, or
    ///   nil when none has been read. Never a session or daily total.
    /// - Parameter model: the session's model id, or nil when none was recorded.
    public func reading(requestUsage: TokenUsage?, model: String?) -> ContextReading {
        guard let requestUsage else { return .noRequestRead }
        let tokens = requestUsage.billableInput

        // A window with an unusable limit takes the amount-only branch for the
        // same reason `fractionUsed` returns nil for it: 0% is a measurement,
        // and this is not one.
        guard let window = window(for: model),
              let fraction = window.fraction(ofRequestInputTokens: tokens)
        else {
            return .amountOnly(requestInputTokens: tokens)
        }
        return .measured(
            fraction: fraction,
            requestInputTokens: tokens,
            maximumInputTokens: window.maximumInputTokens
        )
    }

    // MARK: The shipped table

    /// Context windows as published by Anthropic, in tokens.
    ///
    /// `1M` in the source table is 1,000,000 tokens and `200K` is 200,000; the
    /// figures are decimal, not binary.
    ///
    /// Deliberately absent, because the source does not state a window for them
    /// and a plausible guess is worse than an honest gap (spec 9.4):
    ///
    /// - `claude-mythos-5` — the source's model table lists Claude Mythos 5.1
    ///   but not its predecessor, and inheriting 5.1's window would be an
    ///   assumption, not a reading. `ModelPricing` prices this model, so a
    ///   session on it costs an estimate and sizes as unavailable. That
    ///   asymmetry is correct: two tables, two independent claims.
    /// - every model older than the list below — not carried in the source.
    ///
    /// `claude-mythos-5-1` is sized here although `ModelPricing` does not price
    /// it, for the mirror-image reason: the source states its window plainly and
    /// leaves only its cache-read rate unresolved.
    ///
    /// Partner-operated platforms (Amazon Bedrock, Google Vertex AI) may expose
    /// different limits. Normalisation maps their ids onto these entries, so a
    /// figure for a Bedrock or Vertex session is a first-party estimate.
    public static let current = ContextWindowTable(
        entries: [
            ModelContextWindow(modelID: "claude-fable-5-1", displayName: "Claude Fable 5.1", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-mythos-5-1", displayName: "Claude Mythos 5.1", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-fable-5", displayName: "Claude Fable 5", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-opus-5", displayName: "Claude Opus 5", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-opus-4-8", displayName: "Claude Opus 4.8", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-opus-4-7", displayName: "Claude Opus 4.7", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-opus-4-6", displayName: "Claude Opus 4.6", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-sonnet-5", displayName: "Claude Sonnet 5", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", maximumInputTokens: 1_000_000),
            ModelContextWindow(modelID: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", maximumInputTokens: 200_000),
        ],
        provenance: PriceTableProvenance(
            source: "Anthropic published model table, via the bundled claude-api skill "
                + "(the Context column of its Current Models table)",
            recordedOn: Date(timeIntervalSince1970: 1_782_259_200), // 2026-06-24, the upstream table's cache date
            note: "First-party Claude API limits. Bedrock and Vertex may differ. "
                + "The figure is the model's maximum input, which on the 1M models is also the default."
        )
    )
}
