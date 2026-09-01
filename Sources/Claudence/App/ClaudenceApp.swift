import SwiftUI
import ClaudenceCore

struct ClaudenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = Composition.makeViewModel()
    @State private var watcher = Composition.makeWatcher()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
                .task { await start() }
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    /// Session refresh is driven by filesystem events, never by a timer, so an
    /// idle machine does no work. Usage runs on its own cadence inside the view
    /// model: filesystem churn must never trigger a network request.
    private func start() async {
        guard !model.isRunning else { return }
        await model.start()
        _ = watcher.start { @Sendable in
            await MainActor.run { }
            await model.handleFilesystemChange()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
    }
}
