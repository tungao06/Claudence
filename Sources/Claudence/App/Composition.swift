import Foundation
import ClaudenceCore

/// The one place concrete adapters are chosen. Everything below this line talks
/// to protocols, so swapping a source or adding a provider does not reach into
/// the engine or the views.
@MainActor
enum Composition {
    static func makeViewModel() -> MonitorViewModel {
        // Persistence is best effort. A degraded store still lets the app show
        // live sessions; it only loses history and offset resumption.
        let store = ClaudenceStore()

        let engine = MonitorEngine(
            discovery: SessionRegistryAdapter(),
            transcripts: TranscriptReader(cursorStore: store),
            usageProvider: UsageClient(),
            store: store
        )
        return MonitorViewModel(engine: engine, storeHealth: store.health)
    }

    static func makeWatcher() -> RegistryWatcher {
        RegistryWatcher()
    }
}
