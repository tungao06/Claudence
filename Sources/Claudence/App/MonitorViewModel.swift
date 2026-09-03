import Foundation
import Observation
import ClaudenceCore

/// The app's single source of view state. Holds a snapshot pushed from the
/// engine and nothing else: no file handle, no process, no request. Every
/// number on screen came from a snapshot. See spec section 4.
@MainActor
@Observable
final class MonitorViewModel {
    /// What the menu bar label alone depends on.
    ///
    /// Split out of `snapshot` on purpose. `@Observable` tracks reads per
    /// stored property, so a label that reads only this is not invalidated when
    /// a session's token count moves — and the label is the only thing on
    /// screen while the popover is closed, which is nearly all of the time.
    struct MenuBarState: Equatable {
        var text: String = "Claude"
        var severity: Severity?
        var accessibilityLabel: String = "Claudence, usage unavailable, 0 active sessions"
    }

    private(set) var snapshot: MonitorSnapshot = .empty

    /// The newest snapshot held back by the publish interval, and the task that
    /// will deliver it. Nil means nothing is waiting.
    @ObservationIgnored private var pendingSnapshot: MonitorSnapshot?
    @ObservationIgnored private var pendingPublish: Task<Void, Never>?
    @ObservationIgnored private var lastPublishedAt = Date.distantPast
    private(set) var burnRates: [String: BurnRate] = [:]
    private(set) var isRunning = false

    /// Usage is stored apart from `snapshot` for the same reason: it changes on
    /// its own 60-second cadence, so the windows in the popover and the label
    /// should not be invalidated by session churn.
    private(set) var usageState: UsageState = MonitorSnapshot.empty.usage
    private(set) var menuBarState = MenuBarState()

    /// Recent `usedPercent` readings of each usage window, kept to project
    /// when it will run out (9.11). Fed in `publish(_:at:)`, whenever
    /// `usageState` actually changes value, which is exactly the cadence the
    /// usage loop in `start()` already runs at, so nothing here adds a second
    /// wake. Nothing new is fetched either: `UsageProjector` only divides over
    /// readings the app already holds.
    ///
    /// `@ObservationIgnored` because nothing reads this property directly. A
    /// view never observes it; `DashboardAdapter.refreshDashboard` reads it
    /// through `projection(for:now:)` and `bindingWindow(now:)` at its own
    /// explicit refresh points and copies the result into `DashboardData`,
    /// which is what views actually track.
    ///
    /// Untouched by `isLiveOnly`: the readings come from the usage endpoint,
    /// which that flag never gates.
    @ObservationIgnored private var usageProjector = UsageProjector()

    /// What the store reported when it was opened at launch. Captured once,
    /// same as before: a store that fell back to memory at launch stays
    /// degraded for the life of the process (see `ClaudenceStore.baselineHealth`),
    /// so this value never goes stale on its own. What it cannot show is a
    /// store that answered fine at launch and has since stopped answering —
    /// that is `currentStoreHealth`, below.
    let launchStoreHealth: StoreHealth

    /// The store's condition as of the last time it was asked. Distinct from
    /// `launchStoreHealth` so the banner can tell "fell back to memory at
    /// launch" from "was fine, is not answering right now" instead of
    /// collapsing both into one snapshot taken before either could happen.
    ///
    /// Refreshed from `refreshStoreHealth()`, which rides the existing usage
    /// loop in `start()` rather than a timer of its own: a store health check
    /// costs nothing extra on a wake the process already makes every
    /// `usageRefreshInterval`, and adding a second recurring wake here would
    /// collide with the no-polling rule and the idle CPU budget.
    private(set) var currentStoreHealth: StoreHealth

    /// How to ask the persistence layer its live condition. A closure rather
    /// than a reference to the concrete store, so this file does not need to
    /// import or know which store backs the engine; the composition root
    /// wires it to `store.health`. Nil (the default, used by previews and by
    /// call sites that pass no store) means health can only ever be the value
    /// captured at launch.
    private let healthProvider: (() -> StoreHealth)?

    /// How to read the store's monthly per-project totals, for the monthly
    /// table (9.13). A closure rather than a reference to the concrete store,
    /// the same reason `healthProvider` is one: this file does not need to
    /// import or know which store backs the engine. `AnalyticsService` has no
    /// method for this -- the store's per-model rollups are new in 9.13, and
    /// adding a wrapper there is a change to `ClaudenceCore`, not to this
    /// file -- so `DashboardAdapter` reads the store through this and the
    /// closure below directly, the same way it would through a method on
    /// `AnalyticsService` if one existed. Nil (previews, and call sites that
    /// pass no store) means the table has nothing to read from.
    let monthlyTotalsReader: ((Date) -> ClaudenceStore.MonthlyUsageReport)?

    /// How to read the store's unanswered-query counter, so `DashboardAdapter`
    /// can bracket the read above the same way every method inside
    /// `AnalyticsService` already brackets its own: a count taken before and
    /// after the read that does not match means the store did not actually
    /// answer, and the table should say so rather than render whatever
    /// partial rows came back.
    let unansweredQueriesReader: (() -> UInt64)?

    /// Dashboard aggregates. Built on demand rather than on every snapshot,
    /// because they read the database and the dashboard is usually closed.
    /// Settable from `DashboardAdapter`, which is the only writer.
    var dashboard = DashboardData()

    /// Not private: the composition root attaches the notification bridge to
    /// this same engine. Nothing in the view layer touches it.
    let engine: MonitorEngine

    let analytics: AnalyticsService?

    /// How long the usage loop waits between requests, and the floor it passes
    /// to the engine so a shorter choice is not swallowed by the engine's own
    /// rate limit. Set by the composition root from `Preferences`; the default
    /// is the cache TTL, which is what the loop used before it was settable.
    ///
    /// This paces the one polled source in the application. Session discovery
    /// and token counts stay event driven and are not affected by it.
    var usageRefreshInterval: TimeInterval = Constants.Usage.cacheTTL

    /// Whether `Preferences.liveOnlyMode` is on. Set by the composition root
    /// from `Preferences`, the same way `usageRefreshInterval` is, rather than
    /// read through the environment: `DashboardAdapter.refreshDashboard` is not
    /// a view, and the environment's `liveOnlyMode` is for the views that hide
    /// surfaces this flag lets the adapter skip computing in the first place.
    var isLiveOnly: Bool = false
    private var observerToken: UUID?
    private var usageTask: Task<Void, Never>?

    init(
        engine: MonitorEngine,
        storeHealth: StoreHealth = .healthy,
        healthProvider: (() -> StoreHealth)? = nil,
        analytics: AnalyticsService? = nil,
        monthlyTotalsReader: ((Date) -> ClaudenceStore.MonthlyUsageReport)? = nil,
        unansweredQueriesReader: (() -> UInt64)? = nil
    ) {
        self.engine = engine
        self.launchStoreHealth = storeHealth
        self.currentStoreHealth = storeHealth
        self.healthProvider = healthProvider
        self.analytics = analytics
        self.monthlyTotalsReader = monthlyTotalsReader
        self.unansweredQueriesReader = unansweredQueriesReader
    }

    /// Which subscription the usage limits belong to, or nil when Claude Code's
    /// account file is absent or names a tier this does not recognise.
    ///
    /// Read for one reason: every percentage in this application is a share of
    /// a limit whose size it never states, and 62% of a Max 20x window is four
    /// times the work of 62% of a Max 5x one. Naming the plan is what turns the
    /// headline number from a ratio into a quantity the reader can place.
    ///
    /// Nil draws nothing. See `AccountPlanReader` for the privacy argument and
    /// for why an unrecognised tier is never guessed at.
    private(set) var accountPlan: AccountPlan?

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        // Read once, off the main actor, and never again. A subscription does
        // not change while the application is open, and the file it comes from
        // is 86 KB of JSON that would otherwise be decoded on every render of
        // the popover header.
        accountPlan = await Task.detached { AccountPlanReader.read() }.value

        observerToken = await engine.observe { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }

        await engine.refreshSessions()
        await refreshBurnRates()

        // Usage lives on its own cadence. Filesystem churn must never trigger a
        // network request, so this loop is deliberately separate from the
        // event-driven session refresh.
        //
        // It is also the only recurring wake this process has, which is why
        // two more things ride along on it rather than getting timers of
        // their own:
        //
        // - Burn rates. They decay correctly once recomputed (see the model's
        //   own decay logic), but a quiet session produces no filesystem event
        //   at all — its registry file is not heartbeat-updated and its
        //   transcript stops growing — so nothing ever asks again and the
        //   screen keeps the last busy figure for as long as the session sits
        //   idle. This tick re-asks every session's rate on a bound no fs
        //   event is required to hit.
        // - Store health. See `refreshStoreHealth()`.
        usageTask = Task { [weak self, engine] in
            while !Task.isCancelled {
                // Read on every pass rather than captured once, so changing the
                // interval in Settings takes effect at the next tick instead of
                // at the next launch.
                let interval = self?.usageRefreshInterval ?? Constants.Usage.cacheTTL
                await engine.refreshUsage(minimumInterval: interval)
                await self?.refreshBurnRates()
                self?.refreshStoreHealth()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        usageTask?.cancel()
        usageTask = nil
        if let observerToken {
            Task { [engine] in await engine.removeObserver(observerToken) }
        }
        observerToken = nil
        isRunning = false
    }

    /// Called by the filesystem watcher. Cheap by construction: discovery plus
    /// incremental reads, never a full scan.
    func handleFilesystemChange() async {
        await engine.refreshSessions()
        await refreshBurnRates()
    }

    func refreshUsageNow() async {
        await engine.refreshUsage(force: true)
    }

    // MARK: - Derived view state

    /// Every session with a live process, busy or waiting. The popover lists
    /// all of them, which is why its band is titled LIVE SESSIONS.
    var sessions: [AISession] { snapshot.sessions }
    /// Sessions doing work now, and the only number this application prints
    /// under the word "active". `MonitorSnapshot.activeCount` holds the
    /// definition; nothing here filters on `.running` a second time.
    var activeCount: Int { snapshot.activeCount }
    /// Today's tokens, or nil when the store could not answer. Nil is not a
    /// zero and the popover must not render it as one.
    var todayUsage: TokenUsage? { snapshot.todayUsage }
    var primaryWindow: UsageWindow? { usageState.window(named: "five_hour") }
    var weeklyWindow: UsageWindow? { usageState.window(named: "seven_day") }

    /// Windows beyond the two fixed ones, so a newly launched model appears
    /// without a code change.
    var scopedWindows: [UsageWindow] {
        usageState.windows
            .filter { $0.name.hasPrefix("seven_day_") }
            .sorted { $0.displayName < $1.displayName }
    }

    var usageUnavailableReason: String? {
        if case .unavailable(let reason) = usageState { return reason }
        return nil
    }

    /// When `window` would run out at its current rate, per `UsageProjector`.
    /// Division over readings already kept in `usageProjector`; nothing new is
    /// read for this call.
    func projection(for window: UsageWindow, now: Date = Date()) -> UsageProjection {
        usageProjector.projection(for: window, now: now)
    }

    /// Which of the currently reported usage windows would run out first,
    /// among those that run out before they reset at all. Nil when none does.
    func bindingWindow(now: Date = Date()) -> (window: UsageWindow, at: Date)? {
        usageProjector.bindingWindow(among: usageState.windows, now: now)
    }

    /// The session responsible for the largest share of the current burn, and
    /// that share, over the rates `burnRates` already holds. Nil when nothing
    /// is burning, which is an ordinary state and not an absence of data.
    var burnLeader: (sessionID: String, share: Double)? {
        BurnAttribution.leader(rates: burnRates.mapValues(\.tokensPerMinute))
    }

    func burnRate(for session: AISession) -> BurnRate {
        burnRates[session.id] ?? .zero
    }

    /// Subagents a session spawned, newest activity first. Held apart from the
    /// snapshot because the drill-down is opened rarely and a subagent list
    /// changing must not invalidate the session list that is always on screen.
    private(set) var subagentsBySession: [String: [AISubagent]] = [:]

    func subagents(for session: AISession) -> [AISubagent] {
        subagentsBySession[session.id] ?? []
    }

    /// Each session's share of the tokens spent inside the recent window, keyed
    /// by session id.
    ///
    /// The denominator is what this application measured over the window, not
    /// the provider's window capacity: the usage API reports a percentage
    /// consumed and never a capacity, so there is no honest way to divide a
    /// token count by it.
    ///
    /// A session missing from this map has no share to show, either because the
    /// window measured nothing at all or because its own samples cannot be
    /// differenced across it. The view renders that as unavailable; a zero would
    /// be a claim the data does not support.
    private(set) var windowShares: [String: Double] = [:]

    func windowShare(for session: AISession) -> Double? {
        windowShares[session.id]
    }

    /// Recomputes the shares. Reads the database, so it runs off the main actor
    /// and is called when a detail view opens rather than on every snapshot.
    func refreshWindowShares() async {
        guard let analytics else { return }
        // The share is a rollup-era figure: it differences `usage_samples` over
        // the five-hour window. In live-only mode those samples start at the
        // moment the mode was switched on, so the percentage would answer a
        // shorter question than its label asks. The detail sheet hides the row;
        // this stops the work as well, and clears whatever the last persistent
        // pass left behind.
        guard !isLiveOnly else {
            if !windowShares.isEmpty { windowShares = [:] }
            return
        }
        let shares = await Task.detached(priority: .utility) {
            guard let result = analytics.shareOfWindowTokens() else { return [String: Double]() }
            var mapped: [String: Double] = [:]
            for entry in result.sessions {
                guard let share = entry.share else { continue }
                mapped[entry.sessionID] = share
            }
            return mapped
        }.value
        if windowShares != shares {
            windowShares = shares
        }
    }

    /// Pulls the subagent lists for the sessions currently on screen. Called
    /// when a detail view opens, not on every refresh: reading them is cheap
    /// but publishing them is not, and nothing shows them until asked.
    func refreshSubagents(for sessionID: String) async {
        let list = await engine.subagents(forSession: sessionID)
        if subagentsBySession[sessionID] != list {
            subagentsBySession[sessionID] = list
        }
    }

    /// Shared denominator for the session token bars, so their lengths are
    /// comparable to each other rather than each being full width.
    var tokenScaleMaximum: Int? {
        let peak = sessions.map(\.combinedUsage.total).max() ?? 0
        return peak > 0 ? peak : nil
    }

    var storeWarning: Phrase? {
        // A live health that differs from what launch reported is always a
        // fresh runtime failure, never a second launch-time fallback: the
        // store can only drift away from `launchStoreHealth` by a query
        // failing after launch, and only back to exactly `launchStoreHealth`
        // on the next success (see `ClaudenceStore.noteRecovery`). So this
        // branch is the "not answering now" case, kept distinct from the
        // "fell back to memory at launch" case below.
        if currentStoreHealth != launchStoreHealth {
            let reason = currentStoreHealth.reason ?? "unknown error"
            return Phrase(
                en: "History not saving: not responding (\(reason))",
                th: "ไม่สามารถบันทึกประวัติ: ไม่ตอบสนอง (\(reason))"
            )
        }
        switch launchStoreHealth {
        case .healthy: return nil
        case .degraded(let reason):
            return Phrase(
                en: "History not saved: \(reason)",
                th: "ไม่ได้บันทึกประวัติ: \(reason)"
            )
        case .unavailable(let reason):
            return Phrase(
                en: "History unavailable: \(reason)",
                th: "ไม่มีข้อมูลประวัติ: \(reason)"
            )
        }
    }

    /// What the menu bar shows. Compact by requirement: the menu bar is shared
    /// real estate and must stay under `Constants.Performance.maxMenuBarWidth`.
    /// Read from `menuBarState`, not from `snapshot`, so the label re-renders
    /// only when one of these three values actually changes.
    var menuBarText: String { menuBarState.text }

    var menuBarSeverity: Severity? { menuBarState.severity }

    var menuBarAccessibilityLabel: String { menuBarState.accessibilityLabel }

    /// Derives the label's inputs from a snapshot. Pure, so it is testable
    /// without a view.
    static func menuBarState(for snapshot: MonitorSnapshot) -> MenuBarState {
        let percent = snapshot.primaryWindow?.usedPercent
        let active = snapshot.activeCount

        var parts = ["Claudence"]
        if let percent {
            parts.append("\(Int(percent.rounded())) percent of the five hour limit used")
        } else {
            parts.append("usage unavailable")
        }
        parts.append(active == 1 ? "1 active session" : "\(active) active sessions")

        return MenuBarState(
            text: percent.map(Format.percent) ?? (active > 0 ? "\(active)" : "Claude"),
            severity: snapshot.severity,
            accessibilityLabel: parts.joined(separator: ", ")
        )
    }

    // MARK: - Internals

    /// Fans a snapshot out to the three observable properties, assigning each
    /// only when its own value moved.
    ///
    /// `@Observable` invalidates on assignment, not on change, so an assignment
    /// of an equal value still re-renders every view that read the property.
    /// The engine already drops unchanged snapshots; these guards keep the
    /// split properties honest when only one of the three moved.
    private func apply(_ snapshot: MonitorSnapshot) {
        // Coalesced to at most one publish a second, which is the fix for a
        // measured regression rather than a precaution.
        //
        // `MenuBarExtra(style: .window)` keeps the popover's whole view tree
        // mounted for the life of the process, so every assignment here costs a
        // full SwiftUI layout pass over that tree whether or not anyone has the
        // popover open. Three sessions streaming tokens push a changed snapshot
        // through the 250 ms filesystem debounce several times a second, and
        // `sample` showed the resulting cost as `LayoutEngineBox.sizeThatFits`
        // and `StackLayout.placeChildren` dominating an app that was, from the
        // user's point of view, doing nothing at all: 1.8% of a core against a
        // 0.5% budget.
        //
        // A second of latency is invisible on a monitor whose numbers are read,
        // not acted on, and the trailing publish means the last state of a burst
        // always lands. Nothing is dropped, only deferred.
        let now = Date()
        let sinceLast = now.timeIntervalSince(lastPublishedAt)
        guard sinceLast >= MonitorViewModel.publishInterval else {
            pendingSnapshot = snapshot
            schedulePendingPublish(after: MonitorViewModel.publishInterval - sinceLast)
            return
        }
        publish(snapshot, at: now)
    }

    /// How often the view tree may be invalidated by a new snapshot.
    private static let publishInterval: TimeInterval = 1

    private func schedulePendingPublish(after delay: TimeInterval) {
        guard pendingPublish == nil else { return }
        pendingPublish = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.pendingPublish = nil
            guard let pending = self.pendingSnapshot else { return }
            self.pendingSnapshot = nil
            self.publish(pending, at: Date())
        }
    }

    /// Fans a snapshot out to the three observable properties, assigning each
    /// only when its own value moved.
    ///
    /// `@Observable` invalidates on assignment, not on change, so an assignment
    /// of an equal value still re-renders every view that read the property.
    /// The engine already drops unchanged snapshots; these guards keep the
    /// split properties honest when only one of the three moved.
    private func publish(_ snapshot: MonitorSnapshot, at date: Date) {
        lastPublishedAt = date
        if self.snapshot != snapshot {
            self.snapshot = snapshot
        }
        if usageState != snapshot.usage {
            usageState = snapshot.usage
            // Gated on the same `usageState` change the property assignment
            // above is: a snapshot published for session churn alone carries
            // no new usage reading, and recording it anyway would spend a
            // ring slot on a repeat `UsageProjector.record` already knows how
            // to collapse, for no gain.
            for window in usageState.windows {
                usageProjector.record(window, at: date)
            }
        }
        let next = MonitorViewModel.menuBarState(for: snapshot)
        if menuBarState != next {
            menuBarState = next
        }
    }

    private func refreshBurnRates() async {
        var rates: [String: BurnRate] = [:]
        for session in snapshot.sessions {
            rates[session.id] = await engine.burnRate(forSession: session.id)
        }
        if burnRates != rates {
            burnRates = rates
        }
    }

    /// Re-asks the store's live condition. Called from the usage loop in
    /// `start()`, never on its own timer — see that loop's comment for why
    /// piggybacking here costs nothing on top of the wake the process already
    /// makes.
    ///
    /// A no-op when no `healthProvider` was supplied, which keeps every call
    /// site and preview that constructs a `MonitorViewModel` without a store
    /// working exactly as before.
    private func refreshStoreHealth() {
        guard let healthProvider else { return }
        let next = healthProvider()
        if currentStoreHealth != next {
            currentStoreHealth = next
        }
    }
}
