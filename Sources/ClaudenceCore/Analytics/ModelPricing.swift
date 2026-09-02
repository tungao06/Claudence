import Foundation

// MARK: - One model's four rates

/// The four rates a Claude request is billed at, in US dollars per million tokens.
///
/// Cache write and cache read are separate fields on purpose. They differ by
/// roughly an order of magnitude (a write costs 1.25x fresh input, a read 0.1x),
/// and collapsing them into a single "cache" rate is the single most common way
/// an estimate ends up disagreeing with the bill. See spec section 5.2.
public struct ModelPrice: Sendable, Equatable {
    /// The canonical model id these rates were recorded against.
    public let modelID: String
    public let displayName: String

    /// Uncached input tokens.
    public let freshInputPerMillion: Double
    /// Writing a prompt-cache entry, at the default 5 minute TTL.
    /// The 1 hour TTL is billed at 2x fresh input instead; the transcript does
    /// not record which TTL was used, so this table carries the 5 minute rate
    /// only and an estimate over 1 hour entries is an under-estimate.
    public let cacheWritePerMillion: Double
    /// Reading an existing prompt-cache entry.
    public let cacheReadPerMillion: Double
    /// Output tokens. Thinking tokens are billed as output and are already
    /// counted in the output figure the API reports, so `TokenUsage.thinking`
    /// is deliberately not priced again here.
    public let outputPerMillion: Double

    public init(
        modelID: String,
        displayName: String,
        freshInputPerMillion: Double,
        cacheWritePerMillion: Double,
        cacheReadPerMillion: Double,
        outputPerMillion: Double
    ) {
        self.modelID = modelID
        self.displayName = displayName
        self.freshInputPerMillion = freshInputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.outputPerMillion = outputPerMillion
    }

    /// Estimated dollars for one usage split. Never negative token counts in
    /// practice, but the arithmetic does not care.
    public func estimatedDollars(for usage: TokenUsage) -> Double {
        let millions = 1_000_000.0
        return (Double(usage.freshInput) * freshInputPerMillion
            + Double(usage.cacheCreation) * cacheWritePerMillion
            + Double(usage.cacheRead) * cacheReadPerMillion
            + Double(usage.output) * outputPerMillion) / millions
    }
}

// MARK: - Provenance

/// Where a price table came from and when. Exposed so a stale table is visible
/// in the UI rather than silently producing confident wrong numbers.
public struct PriceTableProvenance: Sendable, Equatable {
    /// Human readable origin of the figures.
    public let source: String
    /// The day the rates themselves were published/captured upstream, not the
    /// day this file was edited. Staleness is measured from here.
    public let recordedOn: Date
    /// Free text for anything the two fields above cannot carry.
    public let note: String

    public init(source: String, recordedOn: Date, note: String = "") {
        self.source = source
        self.recordedOn = recordedOn
        self.note = note
    }

    /// How old the rates are.
    public func age(asOf now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(recordedOn))
    }

    /// Default staleness horizon: 90 days. Anthropic has changed per-token
    /// pricing inside a quarter, so a table older than this is worth a warning.
    public static let staleAfter: TimeInterval = 90 * 24 * 60 * 60

    public func isStale(asOf now: Date = Date(), after horizon: TimeInterval = PriceTableProvenance.staleAfter) -> Bool {
        age(asOf: now) > horizon
    }
}

// MARK: - The table

/// A per-model price table with a documented matching rule.
///
/// ## Matching rule
///
/// `price(for:)` normalises the incoming id, then resolves in this order:
///
/// 1. **Exact match** on the normalised id.
/// 2. **Snapshot fallback**: `<known id>-<snapshot>` resolves to `<known id>`,
///    where `<snapshot>` is a date (4-10 digits, e.g. `20260101`), a `v<n>`
///    version, or the literal `latest`. Longest known id wins, so
///    `claude-opus-4-8-20260101` picks Opus 4.8 and never Opus 4.
///
/// The suffix must *look like a snapshot*. A hypothetical `claude-sonnet-5-1`
/// (a Sonnet 5.1) therefore does **not** inherit Sonnet 5's rates: it is a
/// different model, and guessing its price is exactly the failure mode spec
/// section 9.4 forbids. Anything unmatched returns nil.
///
/// Normalisation handles the platform id shapes: lowercasing, a Bedrock
/// `anthropic.` / `us.anthropic.` prefix, a Bedrock `-v1:0` suffix, and the
/// Vertex `@20251101` version separator.
public struct ModelPricing: Sendable, Equatable {
    public let entries: [ModelPrice]
    public let provenance: PriceTableProvenance

    public init(entries: [ModelPrice], provenance: PriceTableProvenance) {
        self.entries = entries
        self.provenance = provenance
    }

    // MARK: Lookup

    /// The rates for a model id, or nil when the table does not cover it.
    ///
    /// Nil is never a default and never an average. A caller that cannot price
    /// a model must say so.
    public func price(for rawModelID: String?) -> ModelPrice? {
        guard let rawModelID else { return nil }
        let id = Self.normalize(rawModelID)
        guard !id.isEmpty else { return nil }

        if let exact = entries.first(where: { $0.modelID == id }) { return exact }

        // Longest known id first, so a more specific family wins.
        for entry in entries.sorted(by: { $0.modelID.count > $1.modelID.count }) {
            let key = entry.modelID
            guard id.hasPrefix(key + "-") else { continue }
            let suffix = String(id.dropFirst(key.count + 1))
            if Self.isSnapshotSuffix(suffix) { return entry }
        }
        return nil
    }

    public func covers(_ rawModelID: String?) -> Bool { price(for: rawModelID) != nil }

    /// Model ids this table prices, sorted.
    public var knownModelIDs: [String] { entries.map(\.modelID).sorted() }

    // MARK: Normalisation

    static func normalize(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Bedrock: "us.anthropic.claude-sonnet-5-20260101-v1:0"
        if let range = id.range(of: "anthropic.") {
            id = String(id[range.upperBound...])
        }
        // Bedrock version suffix: "-v1:0"
        if let colon = id.lastIndex(of: ":"),
           let dash = id.range(of: "-v", options: .backwards),
           dash.lowerBound < colon {
            let between = id[id.index(dash.lowerBound, offsetBy: 2)..<colon]
            let after = id[id.index(after: colon)...]
            if !between.isEmpty, between.allSatisfy(\.isNumber), !after.isEmpty, after.allSatisfy(\.isNumber) {
                id = String(id[id.startIndex..<dash.lowerBound])
            }
        }
        // Vertex: "claude-opus-4-5@20251101" -> "claude-opus-4-5-20251101"
        if let at = id.firstIndex(of: "@") {
            id = String(id[id.startIndex..<at]) + "-" + String(id[id.index(after: at)...])
        }
        return id
    }

    /// A suffix that denotes a dated or versioned snapshot of the same model,
    /// rather than a different model in the same family.
    static func isSnapshotSuffix(_ suffix: String) -> Bool {
        if suffix == "latest" { return true }
        if suffix.count >= 4, suffix.count <= 10, suffix.allSatisfy(\.isNumber) { return true }
        if suffix.hasPrefix("v") {
            let rest = suffix.dropFirst()
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
        return false
    }

    // MARK: The shipped table

    /// Rates as published by Anthropic, in US dollars per million tokens.
    ///
    /// Fresh input and output are the published per-model rates. Cache write is
    /// the published 5 minute multiplier of 1.25x fresh input; cache read is the
    /// published 0.1x multiplier, except on Claude Fable 5.1 where the published
    /// rate is $0.25/MTok (0.025x) and on Claude Fable 5 / Mythos 5 where it is
    /// $1.00/MTok.
    ///
    /// Deliberately absent, because a rate is not documented for them and a
    /// plausible guess is worse than an honest gap (spec 9.4):
    ///
    /// - `claude-mythos-5-1` — same $10/$50 as Fable 5.1, but whether it shares
    ///   Fable 5.1's 0.025x cache-read rate is unresolved upstream.
    /// - every model older than the list below (Claude 3.x, 4.0, 4.1, 4.5) —
    ///   not carried in the source table.
    ///
    /// Partner-operated platforms (Amazon Bedrock, Google Vertex AI) bill at
    /// their own rates. Normalisation maps their ids onto these entries, so an
    /// estimate for a Bedrock or Vertex session is a first-party estimate.
    public static let current = ModelPricing(
        entries: [
            ModelPrice(
                modelID: "claude-fable-5-1", displayName: "Claude Fable 5.1",
                freshInputPerMillion: 10.00, cacheWritePerMillion: 12.50,
                cacheReadPerMillion: 0.25, outputPerMillion: 50.00
            ),
            ModelPrice(
                modelID: "claude-fable-5", displayName: "Claude Fable 5",
                freshInputPerMillion: 10.00, cacheWritePerMillion: 12.50,
                cacheReadPerMillion: 1.00, outputPerMillion: 50.00
            ),
            ModelPrice(
                modelID: "claude-mythos-5", displayName: "Claude Mythos 5",
                freshInputPerMillion: 10.00, cacheWritePerMillion: 12.50,
                cacheReadPerMillion: 1.00, outputPerMillion: 50.00
            ),
            ModelPrice(
                modelID: "claude-opus-5", displayName: "Claude Opus 5",
                freshInputPerMillion: 5.00, cacheWritePerMillion: 6.25,
                cacheReadPerMillion: 0.50, outputPerMillion: 25.00
            ),
            ModelPrice(
                modelID: "claude-opus-4-8", displayName: "Claude Opus 4.8",
                freshInputPerMillion: 5.00, cacheWritePerMillion: 6.25,
                cacheReadPerMillion: 0.50, outputPerMillion: 25.00
            ),
            ModelPrice(
                modelID: "claude-opus-4-7", displayName: "Claude Opus 4.7",
                freshInputPerMillion: 5.00, cacheWritePerMillion: 6.25,
                cacheReadPerMillion: 0.50, outputPerMillion: 25.00
            ),
            ModelPrice(
                modelID: "claude-opus-4-6", displayName: "Claude Opus 4.6",
                freshInputPerMillion: 5.00, cacheWritePerMillion: 6.25,
                cacheReadPerMillion: 0.50, outputPerMillion: 25.00
            ),
            ModelPrice(
                modelID: "claude-sonnet-5", displayName: "Claude Sonnet 5",
                freshInputPerMillion: 2.00, cacheWritePerMillion: 2.50,
                cacheReadPerMillion: 0.20, outputPerMillion: 10.00
            ),
            ModelPrice(
                modelID: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6",
                freshInputPerMillion: 3.00, cacheWritePerMillion: 3.75,
                cacheReadPerMillion: 0.30, outputPerMillion: 15.00
            ),
            ModelPrice(
                modelID: "claude-haiku-4-5", displayName: "Claude Haiku 4.5",
                freshInputPerMillion: 1.00, cacheWritePerMillion: 1.25,
                cacheReadPerMillion: 0.10, outputPerMillion: 5.00
            ),
        ],
        provenance: PriceTableProvenance(
            source: "Anthropic published API pricing, via the bundled claude-api skill "
                + "(model table plus the documented cache multipliers: write 1.25x fresh "
                + "input at the 5 minute TTL, read 0.1x, with the per-model exceptions noted)",
            recordedOn: Date(timeIntervalSince1970: 1_782_259_200), // 2026-06-24, the upstream table's cache date
            note: "First-party Claude API rates. Bedrock and Vertex bill separately. "
                + "1 hour cache writes are 2x fresh input and are not represented."
        )
    )
}
