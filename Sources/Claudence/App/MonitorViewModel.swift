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
        var hasPercent = false
        var accessibilityLabel: String = "Claudence, usage unavailable, 0 active sessions"
    }

    private(set) var snapshot: MonitorSnapshot = .empty
    private(set) var burnRates: [String: BurnRate] = [:]
    private(set) var isRunning = false

    /// Usage is stored apart from `snapshot` for the same reason: it changes on
    /// its own 60-second cadence, so the windows in the popover and the label
    /// should not be invalidated by session churn.
    private(set) var usageState: UsageState = MonitorSnapshot.empty.usage
    private(set) var menuBarState = MenuBarState()

    /// Surfaced so the UI can say persistence is degraded rather than silently
    /// losing history. See spec section 9.4: an honest gap beats a quiet one.
    let storeHealth: StoreHealth

    /// Dashboard aggregates. Built on demand rather than on every snapshot,
    /// because they read the database and the dashboard is usually closed.
    /// Settable from `DashboardAdapter`, which is the only writer.
    var dashboard = DashboardData()

    /// Not private: the composition root attaches the notification bridge to
    /// this same engine. Nothing in the view layer touches it.
    let engine: MonitorEngine

    let analytics: AnalyticsService?
    private var observerToken: UUID?
    private var usageTask: Task<Void, Never>?

    init(
        engine: MonitorEngine,
        storeHealth: StoreHealth = .healthy,
        analytics: AnalyticsService? = nil
    ) {
        self.engine = engine
        self.storeHealth = storeHealth
        self.analytics = analytics
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        isRunning = true

        observerToken = await engine.observe { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }

        await engine.refreshSessions()
        await refreshBurnRates()

        // Usage lives on its own cadence. Filesystem churn must never trigger a
        // network request, so this loop is deliberately separate from the
        // event-driven session refresh.
        usageTask = Task { [engine] in
            while !Task.isCancelled {
                await engine.refreshUsage()
                try? await Task.sleep(for: .seconds(Constants.Usage.cacheTTL))
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

    var sessions: [AISession] { snapshot.sessions }
    var activeCount: Int { snapshot.activeCount }
    var todayUsage: TokenUsage { snapshot.todayUsage }
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

    func burnRate(for session: AISession) -> BurnRate {
        burnRates[session.id] ?? .zero
    }

    /// Shared denominator for the session token bars, so their lengths are
    /// comparable to each other rather than each being full width.
    var tokenScaleMaximum: Int? {
        let peak = sessions.map(\.usage.total).max() ?? 0
        return peak > 0 ? peak : nil
    }

    var storeWarning: String? {
        switch storeHealth {
        case .healthy: return nil
        case .degraded(let reason): return "History not saved: \(reason)"
        case .unavailable(let reason): return "History unavailable: \(reason)"
        }
    }

    /// What the menu bar shows. Compact by requirement: the menu bar is shared
    /// real estate and must stay under `Constants.Performance.maxMenuBarWidth`.
    /// Read from `menuBarState`, not from `snapshot`, so the label re-renders
    /// only when one of these three values actually changes.
    var menuBarText: String { menuBarState.text }

    var menuBarSeverity: Severity? { menuBarState.severity }

    var menuBarHasPercent: Bool { menuBarState.hasPercent }

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
            hasPercent: percent != nil,
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
        if self.snapshot != snapshot {
            self.snapshot = snapshot
        }
        if usageState != snapshot.usage {
            usageState = snapshot.usage
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
}
