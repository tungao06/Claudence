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
        let storeMode: StoreModeController
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
                    preferences.notifyOnSessionNeedsInput ? .sessionNeedsInput : nil,
                ].compactMap { $0 }
            )
        )
    }

    static func makeServices() -> Services {
        // Built before the store: live-only mode decides whether the store
        // opens its file or opens in memory, and that decision has to be made
        // before the store exists rather than applied to it afterwards.
        let preferences = Preferences()

        // Persistence is best effort. A degraded store still lets the app show
        // live sessions; it only loses history and offset resumption. In
        // live-only mode there is no file to degrade from: the store opens in
        // memory on purpose and reports `.healthy`.
        let store = ClaudenceStore(url: preferences.liveOnlyMode ? nil : ClaudenceStore.defaultDatabaseURL)

        // The store is wrapped rather than passed directly: a store with no
        // database at all answers no cursor and persists none, which sends the
        // reader back to byte 0 on every pass while the engine's accumulator
        // keeps what the last pass added. See `ResilientCursorStore`.
        let reader = TranscriptReader(cursorStore: ResilientCursorStore(durable: store))
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
        let storeMode = StoreModeController(store: store, preferences: preferences)
        let notifications = NotificationBridge()
        // The master switch and the per-event switches travel together, so a
        // preference that is stored is a preference that is read. A keep-set
        // rather than a drop-set: a kind added later is delivered until someone
        // deliberately writes a switch for it.
        notifications.filter = Composition.notificationFilter(from: preferences)

        let model = MonitorViewModel(
            engine: engine,
            storeHealth: store.health,
            // A closure rather than exposing the store itself: the view model
            // asks this on the usage loop's cadence (see
            // `MonitorViewModel.refreshStoreHealth`) to catch a store that
            // answered fine at launch and later stopped, which the snapshot
            // above cannot show on its own.
            healthProvider: { [store] in store.health },
            analytics: analytics
        )

        return Services(
            model: model,
            watcher: RegistryWatcher(),
            preferences: preferences,
            notifications: notifications,
            storeMode: storeMode
        )
    }
}
