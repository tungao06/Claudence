import Foundation

/// The store implements every requirement of `ClaudenceStoring` already; this
/// declares the conformance without the store module having to know the engine
/// exists. Keeping it here preserves the one-way dependency: engine knows about
/// persistence through a protocol, persistence knows nothing about the engine.
extension ClaudenceStore: ClaudenceStoring {}

/// The same arrangement for the subagent totals. `SubagentTracker` is an actor
/// and needs a `Sendable` store, which `ClaudenceStore` already is: it is a
/// `final class` marked `@unchecked Sendable` because every database call goes
/// through its own serial queue.
extension ClaudenceStore: SubagentTotalStoring {}
