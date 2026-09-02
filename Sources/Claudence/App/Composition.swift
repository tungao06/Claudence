import Foundation
import ClaudenceCore

/// The one place concrete adapters are chosen. Everything below this line talks
/// to protocols, so swapping a source or adding a provider does not reach into
/// the engine or the views.
@MainActor
enum Composition {
    /// Everything the app needs, built once and held by the scene.
    struct Services {
        let model: MonitorViewModel
        let watcher: RegistryWatcher
        let preferences: Preferences
        let notifications: NotificationBridge
    }

    static func makeServices() -> Services {
        // Persistence is best effort. A degraded store still lets the app show
        // live sessions; it only loses history and offset resumption.
        let store = ClaudenceStore()

        let engine = MonitorEngine(
            discovery: SessionRegistryAdapter(),
            transcripts: TranscriptReader(cursorStore: store),
            usageProvider: UsageClient(),
            store: store
        )

        let analytics = AnalyticsService(store: store)
        let preferences = Preferences()
        let notifications = NotificationBridge()
        notifications.isEnabled = preferences.notificationsEnabled

        let model = MonitorViewModel(
            engine: engine,
            storeHealth: store.health,
            analytics: analytics
        )

        return Services(
            model: model,
            watcher: RegistryWatcher(),
            preferences: preferences,
            notifications: notifications
        )
    }
}
