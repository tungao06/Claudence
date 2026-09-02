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

    /// Derived rather than assigned once, because these four preferences can
    /// change while the app runs. Built here so the launch path and the
    /// change path cannot drift apart.
    ///
    /// A keep-set rather than a drop-set: a kind added later is delivered until
    /// someone deliberately writes a switch for it.
    static func notificationFilter(from preferences: Preferences) -> NotificationFilter {
        NotificationFilter(
            isEnabled: preferences.notificationsEnabled,
            allowedKinds: Set(
                [
                    preferences.notifyOnUsageThreshold ? NotificationEvent.Kind.usageThreshold : nil,
                    preferences.notifyOnSessionCompleted ? .sessionCompleted : nil,
                    preferences.notifyOnSessionIdle ? .sessionIdle : nil,
                ].compactMap { $0 }
            )
        )
    }

    static func makeServices() -> Services {
        // Persistence is best effort. A degraded store still lets the app show
        // live sessions; it only loses history and offset resumption.
        let store = ClaudenceStore()

        let reader = TranscriptReader(cursorStore: store)
        let engine = MonitorEngine(
            discovery: SessionRegistryAdapter(),
            transcripts: reader,
            usageProvider: UsageClient(),
            store: store,
            // The parent transcript holds none of its subagents' records, and
            // on this machine they account for roughly half the tokens spent.
            // The store is passed as well as the reader. Read cursors were
            // already durable; without a durable total to resume against, a
            // subagent transcript picked up at byte N counted only what arrived
            // after a relaunch.
            subagents: SubagentTracker(reader: reader, store: store)
        )

        let analytics = AnalyticsService(store: store)
        let preferences = Preferences()
        let notifications = NotificationBridge()
        // The master switch and the per-event switches travel together, so a
        // preference that is stored is a preference that is read. A keep-set
        // rather than a drop-set: a kind added later is delivered until someone
        // deliberately writes a switch for it.
        notifications.filter = Composition.notificationFilter(from: preferences)

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
