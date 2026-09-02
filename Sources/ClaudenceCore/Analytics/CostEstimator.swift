import Foundation

// MARK: - A partial, labelled estimate

/// The result of pricing a set of sessions.
///
/// Carries the dollar figure **and** the part of the usage it could not price,
/// so a caller can render "estimated $4.12, 2 of 5 sessions unpriced" instead of
/// quietly under-reporting. Spec section 9.2: cost is estimated only, always
/// labelled, and a model absent from the table yields "Cost unavailable", never
/// zero and never an average.
public struct CostEstimate: Sendable, Equatable {
    /// Dollars for the portion that could be priced. This is a lower bound
    /// whenever `unpricedSessions > 0`.
    public let pricedDollars: Double
    /// Sessions whose model was in the price table.
    public let pricedSessions: Int
    /// Sessions whose model was missing or unknown. Their tokens are still
    /// reported in `unpricedUsage`; they are never dropped.
    public let unpricedSessions: Int
    /// Tokens belonging to the unpriced sessions.
    public let unpricedUsage: TokenUsage
    /// Distinct model ids that could not be priced, sorted. Sessions with no
    /// model recorded at all contribute to `unpricedSessions` but not here.
    public let unpricedModels: [String]

    public init(
        pricedDollars: Double = 0,
        pricedSessions: Int = 0,
        unpricedSessions: Int = 0,
        unpricedUsage: TokenUsage = .zero,
        unpricedModels: [String] = []
    ) {
        self.pricedDollars = pricedDollars
        self.pricedSessions = pricedSessions
        self.unpricedSessions = unpricedSessions
        self.unpricedUsage = unpricedUsage
        self.unpricedModels = unpricedModels
    }

    public static let zero = CostEstimate()

    public var totalSessions: Int { pricedSessions + unpricedSessions }

    /// Whether every session in the input could be priced.
    public var isComplete: Bool { unpricedSessions == 0 }

    /// The figure to display, or nil when nothing at all could be priced.
    ///
    /// Nil is the honest answer for "five sessions, none of them priceable":
    /// $0.00 would be a lie. Zero sessions priced *and none unpriced* is a
    /// genuine zero, so an empty input estimates $0.00 completely.
    public var estimatedDollars: Double? {
        if pricedSessions == 0 && unpricedSessions > 0 { return nil }
        return pricedDollars
    }

    /// A caveat the UI can render next to the figure, or nil when there is
    /// nothing to disclose.
    public var gapDescription: String? {
        guard unpricedSessions > 0 else { return nil }
        return "\(unpricedSessions) of \(totalSessions) sessions unpriced"
    }

    public static func + (lhs: CostEstimate, rhs: CostEstimate) -> CostEstimate {
        CostEstimate(
            pricedDollars: lhs.pricedDollars + rhs.pricedDollars,
            pricedSessions: lhs.pricedSessions + rhs.pricedSessions,
            unpricedSessions: lhs.unpricedSessions + rhs.unpricedSessions,
            unpricedUsage: lhs.unpricedUsage + rhs.unpricedUsage,
            unpricedModels: Array(Set(lhs.unpricedModels).union(rhs.unpricedModels)).sorted()
        )
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
        var unpricedUsage = TokenUsage.zero
        var unpricedModels = Set<String>()

        for session in sessions {
            if let price = pricing.price(for: session.model) {
                dollars += price.estimatedDollars(for: session.usage)
                priced += 1
            } else {
                unpriced += 1
                unpricedUsage += session.usage
                if let model = session.model, !model.isEmpty { unpricedModels.insert(model) }
            }
        }

        return CostEstimate(
            pricedDollars: dollars,
            pricedSessions: priced,
            unpricedSessions: unpriced,
            unpricedUsage: unpricedUsage,
            unpricedModels: unpricedModels.sorted()
        )
    }
}
