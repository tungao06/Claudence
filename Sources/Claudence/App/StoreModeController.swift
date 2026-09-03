import Foundation
import ClaudenceCore

/// Applies the live-only preference to the store the whole app shares.
///
/// ## Why this exists rather than a view writing `preferences.liveOnlyMode`
///
/// `ClaudenceStore` is one object, held by the engine, the subagent tracker,
/// the transcript reader and the analytics service, none of which are rebuilt
/// when the mode changes -- `store.reopen(url:)` points the same connection
/// somewhere else instead. A view that only flipped the stored `Bool` would
/// change what `Preferences` says without changing what the store does; the
/// two would agree again only at the next launch, which is the exact failure
/// `AppearanceController`'s own header describes for a setting applied from a
/// view instead of from the application. This type is `StoreModeController`'s
/// answer to that for persistence: the settings view calls `setLiveOnly`, and
/// everything downstream of the store learns about the change through the
/// connection it already holds.
///
/// ## Ordering inside `setLiveOnly`
///
/// Turning live-only on reopens the store in memory first, then removes the
/// file if the caller asked, then writes the preference. Deleting a file the
/// store still has open is undefined by the time a WAL and a shm sibling are
/// involved, and `ClaudenceStore.removeStoredFile` says as much: it is "only
/// correct once nothing has the file open." The preference is written last so
/// that a crash between the reopen and the write leaves `Preferences` still
/// saying persistent, which is the state a relaunch can recover from cleanly
/// (open the file that is still there) rather than one where the app believes
/// it is live-only while a stale file sits on disk unaccounted for.
///
/// Turning it off reopens at `ClaudenceStore.defaultDatabaseURL`, which
/// re-creates the file and its schema if the earlier deletion removed it, and
/// then writes the preference.
@MainActor
@Observable
final class StoreModeController {
    private let store: ClaudenceStore
    private let preferences: Preferences
    /// Held so a delete can clear what the engine is still carrying. See
    /// `clearStoredData()`.
    private let engine: MonitorEngine?

    /// Files `ClaudenceStore.removeStoredFile` could not remove, most recent
    /// last. Cleared at the start of every `setLiveOnly` call that attempts a
    /// deletion, so a stale failure never outlives the attempt that produced
    /// it. The settings view is expected to show this list when it is
    /// non-empty -- a silently ignored deletion failure would leave a user
    /// believing their history is gone when the file, or its `-wal`/`-shm`
    /// sibling, is still sitting in Application Support.
    private(set) var lastDeletionFailures: [URL] = []

    init(store: ClaudenceStore, preferences: Preferences, engine: MonitorEngine? = nil) {
        self.store = store
        self.preferences = preferences
        self.engine = engine
    }

    /// Whether the store is currently meant to be in-memory. Reads the stored
    /// preference; it does not itself guarantee the store agrees, which is
    /// exactly why every write to the preference goes through this type.
    var isLiveOnly: Bool { preferences.liveOnlyMode }

    /// What the store holds right now, for a confirmation that names real
    /// counts.
    func storedDataSummary() -> ClaudenceStore.StoredDataSummary {
        store.storedDataSummary()
    }

    /// The store's condition right now. Exposed for the problem report
    /// (9.10c): that screen has no `MonitorViewModel` of its own, only the
    /// store this controller already wraps, and `store.health` is otherwise
    /// only mirrored through `MonitorViewModel.currentStoreHealth`.
    var storeHealth: StoreHealth { store.health }

    /// Deletes everything the store holds and reclaims the space (9.10d).
    ///
    /// Unlike `setLiveOnly(_:deletingStoredData:)`, this does not change where
    /// persistence points -- the store keeps writing to the same file
    /// afterwards, empty until the next write repopulates it.
    ///
    /// The engine is told to forget as well, and it has to be. The delete takes
    /// the read cursors with the session rows, which is the correct pairing on
    /// disk, but this process still holds every session's accumulated total in
    /// memory. Left alone, the next pass would find no cursor, read each
    /// transcript from byte 0, and add a file the accumulator already contains:
    /// the double count this codebase has now prevented from three other
    /// directions, arriving through a delete button.
    ///
    /// After both halves, cursors and totals are at zero together, so each live
    /// session re-reads its transcript once and arrives at the figure the file
    /// actually holds. A session on screen may therefore show a total that
    /// climbs back over a pass or two rather than one that never moved. That is
    /// the honest consequence of deleting the history it was resumed from.
    ///
    /// What does not come back on its own is everything derived from the rows
    /// that stay gone: `daily_rollups`, the projects breakdown and the session
    /// history table all read empty until new activity accumulates.
    func clearStoredData() async {
        store.deleteStoredData()
        await engine?.forgetAccumulatedTotals()
    }

    /// Turns live-only mode on or off.
    ///
    /// - Parameters:
    ///   - on: the mode to switch to.
    ///   - deletingStoredData: when turning the mode on, whether the file the
    ///     store is leaving should be deleted as well as abandoned. Ignored
    ///     when `on` is false.
    func setLiveOnly(_ on: Bool, deletingStoredData: Bool) {
        if on {
            // The file this store is about to stop using, read before the
            // reopen moves the connection to memory and the URL is no longer
            // reachable through it.
            let fileURL = store.storedDataSummary().fileURL

            store.reopen(url: nil)

            if deletingStoredData {
                lastDeletionFailures = []
                let target = fileURL ?? ClaudenceStore.defaultDatabaseURL
                let failed = ClaudenceStore.removeStoredFile(at: target)
                lastDeletionFailures = failed
            }

            preferences.liveOnlyMode = true
        } else {
            store.reopen(url: ClaudenceStore.defaultDatabaseURL)
            preferences.liveOnlyMode = false
        }
    }
}
