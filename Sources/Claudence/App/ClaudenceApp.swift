import SwiftUI
import ClaudenceCore

struct ClaudenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var services = Composition.makeServices()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: services.model, preferences: services.preferences)
                .task { await start() }
                // The popover content is mounted for the life of the process,
                // which makes it the one reliable place to notice a preference
                // changing in the settings window. Both observers are inert
                // until a value actually moves, so an idle app pays nothing.
                .onChange(of: services.preferences.appearance) { _, mode in
                    applyAppearance(mode)
                }
                .onChange(of: services.preferences.usageRefreshInterval) { _, interval in
                    services.model.usageRefreshInterval = interval.seconds
                }
                // The notification filter is derived from four preferences, so
                // it is rebuilt whenever any of them moves. Assigning it only at
                // launch meant turning a notification off in Settings did not
                // stop it until the next launch, which is the kind of setting
                // that reads as broken rather than as delayed.
                .onChange(of: services.preferences.notificationsEnabled) { _, _ in
                    rebuildNotificationFilter()
                }
                .onChange(of: services.preferences.notifyOnUsageThreshold) { _, _ in
                    rebuildNotificationFilter()
                }
                .onChange(of: services.preferences.notifyOnSessionCompleted) { _, _ in
                    rebuildNotificationFilter()
                }
                .onChange(of: services.preferences.notifyOnSessionIdle) { _, _ in
                    rebuildNotificationFilter()
                }
        } label: {
            MenuBarLabel(model: services.model, preferences: services.preferences)
        }
        .menuBarExtraStyle(.window)

        Window("Claudence Dashboard", id: DashboardWindow.id) {
            DashboardHost(model: services.model)
        }
        .defaultSize(width: 720, height: 560)

        SettingsScene(preferences: services.preferences)
    }

    private func rebuildNotificationFilter() {
        services.notifications.filter = Composition.notificationFilter(from: services.preferences)
    }

    /// Session refresh is driven by filesystem events, never by a timer, so an
    /// idle machine does no work. Usage runs on its own cadence inside the view
    /// model: filesystem churn must never trigger a network request.
    private func start() async {
        guard !services.model.isRunning else { return }

        // Two preferences reach outside their own view and are applied here,
        // once, before anything runs. The settings pane stores intent; deciding
        // what the application does with it is not a leaf view's job.
        applyAppearance(services.preferences.appearance)
        services.model.usageRefreshInterval = services.preferences.usageRefreshInterval.seconds

        await services.model.start()

        let model = services.model
        _ = services.watcher.start { @Sendable in
            await model.handleFilesystemChange()
        }

        await services.notifications.start(observing: services.model.engine)
    }
}

/// Applies the stored appearance to the whole application.
///
/// `NSApp.appearance` is deliberately nil for `.auto`, not set to the current
/// system appearance: a nil appearance means "follow the system", and the
/// windows then keep following it when it switches at sunset. Reading the
/// system value once and pinning it would freeze the app on whatever the system
/// happened to be at launch, which looks identical to `.auto` until dusk.
@MainActor
func applyAppearance(_ mode: AppearanceMode) {
    switch mode {
    case .auto: NSApp.appearance = nil
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

enum DashboardWindow {
    static let id = "claudence.dashboard"
}

/// Rebuilds the dashboard aggregates when the window appears. They read the
/// database, so they are never derived from a snapshot.
private struct DashboardHost: View {
    let model: MonitorViewModel

    var body: some View {
        DashboardView(data: model.dashboard)
            .task { model.refreshDashboard() }
    }
}

/// Nothing sits between `MenuBarExtra` and its content any more.
///
/// A `PopoverHost` wrapper used to live here, watching `isKeyWindow` and
/// `occlusionState` so animated components could suppress themselves while the
/// popover was dismissed. It went when the repeating animation went, and
/// removing it took the last of the idle cost with it: the occlusion and key
/// notifications fire on their own schedule, and each one dispatched to the
/// main queue and pushed a state change through the view tree for a flag that
/// no component read any more.
///
/// The lesson worth keeping: `MenuBarExtra(style: .window)` keeps its content
/// mounted after dismissal, so anything here that observes, animates, or ticks
/// runs for the life of the process. Cost nothing when idle, by construction.

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
    }
}
