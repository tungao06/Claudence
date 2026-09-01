import Foundation
import Observation
import ClaudenceCore

/// The app's single source of view state. Holds a snapshot pushed from the
/// engine and nothing else: no file handle, no process, no request. Every
/// number on screen came from a snapshot. See spec section 4.
@MainActor
@Observable
final class MonitorViewModel {
    private(set) var snapshot: MonitorSnapshot = .empty
    private(set) var burnRates: [String: BurnRate] = [:]
    private(set) var isRunning = false

    /// Surfaced so the UI can say persistence is degraded rather than silently
    /// losing history. See spec section 9.4: an honest gap beats a quiet one.
    let storeHealth: StoreHealth

    private let engine: MonitorEngine
    private var observerToken: UUID?
    private var usageTask: Task<Void, Never>?

    init(engine: MonitorEngine, storeHealth: StoreHealth = .healthy) {
        self.engine = engine
        self.storeHealth = storeHealth
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
    var primaryWindow: UsageWindow? { snapshot.primaryWindow }
    var weeklyWindow: UsageWindow? { snapshot.usage.window(named: "seven_day") }

    /// Windows beyond the two fixed ones, so a newly launched model appears
    /// without a code change.
    var scopedWindows: [UsageWindow] {
        snapshot.usage.windows
            .filter { $0.name.hasPrefix("seven_day_") }
            .sorted { $0.displayName < $1.displayName }
    }

    var usageUnavailableReason: String? {
        if case .unavailable(let reason) = snapshot.usage { return reason }
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
    var menuBarText: String {
        if let percent = primaryWindow?.usedPercent {
            return Format.percent(percent)
        }
        return activeCount > 0 ? "\(activeCount)" : "Claude"
    }

    var menuBarSeverity: Severity? { snapshot.severity }

    var menuBarAccessibilityLabel: String {
        var parts = ["Claudence"]
        if let percent = primaryWindow?.usedPercent {
            parts.append("\(Int(percent.rounded())) percent of the five hour limit used")
        } else {
            parts.append("usage unavailable")
        }
        parts.append(activeCount == 1 ? "1 active session" : "\(activeCount) active sessions")
        return parts.joined(separator: ", ")
    }

    // MARK: - Internals

    private func apply(_ snapshot: MonitorSnapshot) {
        self.snapshot = snapshot
    }

    private func refreshBurnRates() async {
        var rates: [String: BurnRate] = [:]
        for session in snapshot.sessions {
            rates[session.id] = await engine.burnRate(forSession: session.id)
        }
        burnRates = rates
    }
}
