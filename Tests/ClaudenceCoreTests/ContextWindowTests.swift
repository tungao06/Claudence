import Foundation
import Testing
@testable import ClaudenceCore

// MARK: - Lookup

@Test("an exact model id resolves to its published context window")
func exactContextLookup() {
    let table = ContextWindowTable.current
    #expect(table.window(for: "claude-opus-5")?.maximumInputTokens == 1_000_000)
    #expect(table.window(for: "claude-sonnet-5")?.maximumInputTokens == 1_000_000)
    #expect(table.window(for: "claude-haiku-4-5")?.maximumInputTokens == 200_000)
    #expect(table.window(for: "claude-haiku-4-5")?.displayName == "Claude Haiku 4.5")
}

@Test("context lookup normalises exactly as the price table does")
func contextLookupSharesPriceNormalisation() {
    let table = ContextWindowTable.current
    #expect(table.window(for: "claude-sonnet-5-20260101")?.modelID == "claude-sonnet-5")
    #expect(table.window(for: "claude-opus-4-8-20260101")?.modelID == "claude-opus-4-8")
    #expect(table.window(for: "CLAUDE-OPUS-5")?.modelID == "claude-opus-5")
    #expect(table.window(for: "claude-opus-4-6@20251101")?.modelID == "claude-opus-4-6")
    #expect(table.window(for: "us.anthropic.claude-sonnet-5-20260101-v1:0")?.modelID == "claude-sonnet-5")
    #expect(table.window(for: "claude-opus-5-latest")?.modelID == "claude-opus-5")
    // A different model in the same family is not a snapshot of it.
    #expect(table.window(for: "claude-sonnet-5-1") == nil)
}

@Test("an unknown model yields nil, never the largest or smallest known window")
func unknownModelHasNoContextWindow() {
    let table = ContextWindowTable.current
    #expect(table.window(for: "gpt-5") == nil)
    #expect(table.window(for: "claude-sonnet-3-7") == nil)
    #expect(table.window(for: "") == nil)
    #expect(table.window(for: nil) == nil)
    #expect(table.covers("claude-opus-5"))
    #expect(table.covers("something-else") == false)

    // Deliberately absent: the source states no window for Mythos 5, and
    // inheriting 5.1's would be a guess. The price table does price it, so the
    // two tables covering different sets is intended, not drift.
    #expect(table.window(for: "claude-mythos-5") == nil)
    #expect(ModelPricing.current.covers("claude-mythos-5"))
    #expect(table.covers("claude-mythos-5-1"))
    #expect(ModelPricing.current.covers("claude-mythos-5-1") == false)
}

@Test("every sized model is a distinct claim, not one default applied everywhere")
func contextTableIsNotASingleDefault() {
    let table = ContextWindowTable.current
    let limits = Set(table.entries.map(\.maximumInputTokens))
    #expect(limits.count > 1)
    #expect(table.entries.allSatisfy { $0.maximumInputTokens > 0 })
    #expect(table.knownModelIDs == table.knownModelIDs.sorted())
    #expect(Set(table.knownModelIDs).count == table.entries.count)
}

// MARK: - Provenance

@Test("the context table exposes its provenance so a stale table is visible")
func contextTableProvenanceIsVisible() {
    let provenance = ContextWindowTable.current.provenance
    #expect(provenance.source.isEmpty == false)
    #expect(provenance.isStale(asOf: provenance.recordedOn) == false)

    let wellPast = provenance.recordedOn.addingTimeInterval(PriceTableProvenance.staleAfter + 1)
    #expect(provenance.isStale(asOf: wellPast))

    // Same source and capture date as the price table, so a caller that shows
    // one staleness warning is not hiding a second, different one.
    #expect(provenance.recordedOn == ModelPricing.current.provenance.recordedOn)
}

// MARK: - The used side

@Test("a request's billable input is the figure measured against the window")
func fractionUsedCountsBillableInputOnly() throws {
    let table = ContextWindowTable.current
    // One record's usage block: 200k of prompt, of which most came from cache.
    let record = TokenUsage(
        freshInput: 20_000, cacheCreation: 30_000, cacheRead: 150_000, output: 4_000)
    #expect(record.billableInput == 200_000)

    let fraction = try #require(table.fractionUsed(requestUsage: record, model: "claude-opus-5"))
    #expect(abs(fraction - 0.2) < 0.000_001)

    // Output is excluded: it is not part of this request's input. Including it
    // would have given 0.204.
    let withOutputCounted = Double(record.total) / 1_000_000
    #expect(abs(fraction - withOutputCounted) > 0.003)

    // The integer entry point agrees with the usage entry point.
    #expect(table.fractionUsed(requestInputTokens: 200_000, model: "claude-opus-5") == fraction)
}

@Test("the same request is a much larger share of a smaller window")
func fractionUsedScalesWithTheModelsWindow() throws {
    let table = ContextWindowTable.current
    let record = TokenUsage(freshInput: 100_000)

    let opus = try #require(table.fractionUsed(requestUsage: record, model: "claude-opus-5"))
    let haiku = try #require(table.fractionUsed(requestUsage: record, model: "claude-haiku-4-5"))
    #expect(abs(opus - 0.1) < 0.000_001)
    #expect(abs(haiku - 0.5) < 0.000_001)
}

@Test("an unknown model has no fraction, and zero input is a real zero")
func fractionUsedIsNilForAnUnknownModel() {
    let table = ContextWindowTable.current
    #expect(table.fractionUsed(requestUsage: TokenUsage(freshInput: 1_000), model: "gpt-5") == nil)
    #expect(table.fractionUsed(requestInputTokens: 1_000, model: nil) == nil)
    #expect(table.fractionUsed(requestInputTokens: 0, model: "claude-opus-5") == 0)
}

@Test("an over-limit figure is reported as over-limit, not clamped to 100%")
func fractionUsedIsNotClamped() throws {
    let table = ContextWindowTable.current
    // What a cumulative session total looks like when misused as a request
    // size: the caller sees an obviously wrong 8000% instead of a plausible
    // 100% that would hide the mistake.
    let cumulative = TokenUsage(freshInput: 800_000, cacheRead: 79_200_000)
    let fraction = try #require(table.fractionUsed(requestUsage: cumulative, model: "claude-opus-5"))
    #expect(fraction > 1)
    #expect(abs(fraction - 80.0) < 0.000_001)
}

@Test("a window sizes a request directly, without going through the table")
func modelContextWindowSizesARequest() {
    let window = ModelContextWindow(
        modelID: "test-model", displayName: "Test", maximumInputTokens: 200_000)
    #expect(window.fraction(ofRequestInputTokens: 50_000) == 0.25)
    #expect(window.fraction(ofRequestInputTokens: 0) == 0)
    // Negative input cannot happen in practice; it must not produce a negative
    // meter if it ever does.
    #expect(window.fraction(ofRequestInputTokens: -5) == 0)
}

@Test("A non-positive limit yields no fraction rather than zero")
func nonPositiveLimitIsUnavailable() {
    // The public initialiser does not validate, so this is reachable from
    // outside the module. Zero would render as "0% used", which claims a
    // measurement we do not have.
    let broken = ModelContextWindow(
        modelID: "claude-test-broken",
        displayName: "Broken",
        maximumInputTokens: 0
    )
    #expect(broken.fraction(ofRequestInputTokens: 1_000) == nil)

    let table = ContextWindowTable(entries: [broken], provenance: ContextWindowTable.current.provenance)
    #expect(table.fractionUsed(requestInputTokens: 1_000, model: "claude-test-broken") == nil)
}
