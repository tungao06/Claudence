import Foundation

// MARK: - A partial, labelled estimate

/// The result of pricing a set of sessions.
///
/// Carries the dollar figure **and** the count of what it could not price, so a
/// caller can render "estimated $4.12, 2 sessions unpriced" instead of quietly
/// under-reporting. Spec section 9.2: cost is estimated only, always labelled,
/// and a model absent from the table yields "Cost unavailable", never zero and
/// never an average.
public struct CostEstimate: Sendable, Equatable {
    /// Dollars for the portion that could be priced. This is a lower bound
    /// whenever `unpricedSessions > 0`.
    public let pricedDollars: Double
    /// Sessions whose model was in the price table.
    public let pricedSessions: Int
    /// Sessions whose model was missing or unknown.
    public let unpricedSessions: Int

    public init(
        pricedDollars: Double = 0,
        pricedSessions: Int = 0,
        unpricedSessions: Int = 0
    ) {
        self.pricedDollars = pricedDollars
        self.pricedSessions = pricedSessions
        self.unpricedSessions = unpricedSessions
    }

    /// The figure to display, or nil when nothing at all could be priced.
    ///
    /// Nil is the honest answer for "five sessions, none of them priceable":
    /// $0.00 would be a lie. Zero sessions priced *and none unpriced* is a
    /// genuine zero, so an empty input estimates $0.00 completely.
    public var estimatedDollars: Double? {
        if pricedSessions == 0 && unpricedSessions > 0 { return nil }
        return pricedDollars
    }
}

// MARK: - Estimator

/// Prices token usage against a `ModelPricing` table.
///
/// Every number this type returns is an estimate: the transcript records tokens
/// after the fact, the 5 minute versus 1 hour cache TTL is not recorded, and the
/// table itself has a recorded-on date. Nothing here is a billing amount.
public struct CostEstimator: Sendable {
    public let pricing: ModelPricing

    public init(pricing: ModelPricing = .current) {
        self.pricing = pricing
    }

    /// Provenance of the rates behind every estimate this instance produces.
    public var provenance: PriceTableProvenance { pricing.provenance }

    /// Estimated dollars for one usage split, or nil when the model has no
    /// price. Never falls back to a default or an average rate.
    public func estimate(usage: TokenUsage, model: String?) -> Double? {
        guard let price = pricing.price(for: model) else { return nil }
        return price.estimatedDollars(for: usage)
    }

    /// Estimated dollars across sessions, honest about what it could not price.
    public func estimate(sessions: [AISession]) -> CostEstimate {
        var dollars = 0.0
        var priced = 0
        var unpriced = 0

        // `combinedUsage`, not `usage`: a subagent's tokens are billed to the
        // same account as its parent's, and measured here they are around half
        // of a working session's true total. Pricing them at the parent's rate
        // is an approximation — a subagent may have run on a different model,
        // and the transcript does not say which at the point this is summed —
        // but a figure that is approximately right beats one that is precisely
        // half. This is why the figure is labelled Estimated everywhere it is
        // shown, and why the unpriced portion is reported rather than hidden.
        for session in sessions {
            if let price = pricing.price(for: session.model) {
                dollars += price.estimatedDollars(for: session.combinedUsage)
                priced += 1
            } else {
                unpriced += 1
            }
        }

        return CostEstimate(
            pricedDollars: dollars,
            pricedSessions: priced,
            unpricedSessions: unpriced
        )
    }
}
