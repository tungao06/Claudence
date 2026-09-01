import Foundation

/// The store implements every requirement of `ClaudenceStoring` already; this
/// declares the conformance without the store module having to know the engine
/// exists. Keeping it here preserves the one-way dependency: engine knows about
/// persistence through a protocol, persistence knows nothing about the engine.
extension ClaudenceStore: ClaudenceStoring {}
