import SwiftUI
import ClaudenceCore

struct ClaudenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var services = Composition.makeServices()

    var body: some Scene {
        MenuBarExtra {
            PopoverHost(services: services)
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

/// Hosts the popover content and answers the one question the components need:
/// is any of this actually in front of the user?
///
/// The content stays mounted. Unmounting it on dismissal was tried and rejected:
/// the AppKit signals available here flip on spuriously, and a false negative
/// there means an empty popover, which is far worse than a missing animation.
/// Instead the answer is published into the environment and components that
/// animate suppress themselves. See `PopoverPresentation.swift` for why that
/// matters: a `.repeatForever` on a mounted-but-invisible view cost 6.9% of a
/// core against a 0.5% budget.
private struct PopoverHost: View {
    let services: Composition.Services

    @State private var isPresented = false

    var body: some View {
        MenuBarContent(model: services.model)
            .environment(\.popoverIsPresented, isPresented)
            .background(
                PresentationReader { presented in
                    if isPresented != presented { isPresented = presented }
                }
            )
    }
}

/// Rebuilds the dashboard aggregates when the window appears, and on demand.
/// They read the database, so they are never derived from a snapshot.
private struct DashboardHost: View {
    let model: MonitorViewModel

    var body: some View {
        DashboardView(data: model.dashboard)
            .task { model.refreshDashboard() }
    }
}

/// Reports whether the window hosting this view is in front of the user.
///
/// A `MenuBarExtra` popover becomes key when it opens and resigns key when it is
/// dismissed, which makes key state the one AppKit signal that means "presented"
/// for this kind of window. Occlusion is ORed in so a presented-but-not-key
/// window still reports as visible.
private struct PresentationReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView { Reader(onChange: onChange) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Reader)?.onChange = onChange
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        // SwiftUI tears down a representable on the main actor; the compiler
        // cannot see that through this static hook.
        MainActor.assumeIsolated { (nsView as? Reader)?.stopObserving() }
    }

    final class Reader: NSView {
        var onChange: (Bool) -> Void
        private var tokens: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        // No deinit: observers are removed by `dismantleNSView` on teardown and
        // by `viewDidMoveToWindow` when the view leaves its window, which covers
        // both exits. A nonisolated deinit cannot touch the token array under
        // Swift 6 concurrency checking, and the observer blocks hold `self`
        // weakly, so nothing is kept alive by the absence of one.

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else {
                report(false)
                return
            }
            report(Reader.isPresented(window))

            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didChangeOcclusionStateNotification,
            ]
            let center = NotificationCenter.default
            for name in names {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    guard let window = note.object as? NSWindow else { return }
                    MainActor.assumeIsolated { self?.report(Reader.isPresented(window)) }
                }
                tokens.append(token)
            }
        }

        func stopObserving() {
            let center = NotificationCenter.default
            for token in tokens { center.removeObserver(token) }
            tokens.removeAll()
        }

        private static func isPresented(_ window: NSWindow) -> Bool {
            window.isKeyWindow || window.occlusionState.contains(.visible)
        }

        private func report(_ presented: Bool) {
            let handler = onChange
            DispatchQueue.main.async { handler(presented) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, no main window.
        NSApp.setActivationPolicy(.accessory)
    }
}
