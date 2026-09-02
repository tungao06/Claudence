import SwiftUI
import ClaudenceCore

struct ClaudenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var services = Composition.makeServices()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: services.model)
                .task { await start() }
        } label: {
            MenuBarLabel(model: services.model)
        }
        .menuBarExtraStyle(.window)

        Window("Claudence Dashboard", id: DashboardWindow.id) {
            DashboardHost(model: services.model)
        }
        .defaultSize(width: 720, height: 560)

        SettingsScene(preferences: services.preferences)
    }

    /// Session refresh is driven by filesystem events, never by a timer, so an
    /// idle machine does no work. Usage runs on its own cadence inside the view
    /// model: filesystem churn must never trigger a network request.
    private func start() async {
        guard !services.model.isRunning else { return }
        await services.model.start()

        let model = services.model
        _ = services.watcher.start { @Sendable in
            await model.handleFilesystemChange()
        }

        await services.notifications.start(observing: services.model.engine)
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
