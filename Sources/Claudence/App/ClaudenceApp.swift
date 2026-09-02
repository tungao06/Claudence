import SwiftUI
import ClaudenceCore

struct ClaudenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var services = Composition.makeServices()
    /// Started here rather than from a view. `MenuBarExtra` does not build its
    /// content until the popover is first opened, so an observer that lived
    /// there was not listening yet the first time Settings changed the theme.
    @State private var appearance: AppearanceController

    init() {
        let services = Composition.makeServices()
        _services = State(initialValue: services)
        let appearance = AppearanceController(preferences: services.preferences)
        _appearance = State(initialValue: appearance)
        appearance.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: services.model, preferences: services.preferences)
                // `Live indicators` reaches the bars, arcs and rings through the
                // environment. They are leaves several levels down and have no
                // other reason to know a preference exists.
                .environment(\.liveIndicators, services.preferences.liveIndicators)
                .task { await start() }
                // The popover content is mounted for the life of the process,
                // which makes it the one reliable place to notice a preference
                // changing in the settings window. Both observers are inert
                // until a value actually moves, so an idle app pays nothing.
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
                .onChange(of: services.preferences.notifyOnSessionNeedsInput) { _, _ in
                    rebuildNotificationFilter()
                }
        } label: {
            MenuBarLabel(model: services.model, preferences: services.preferences)
        }
        .menuBarExtraStyle(.window)

        Window("Claudence Dashboard", id: DashboardWindow.id) {
            DashboardHost(model: services.model, preferences: services.preferences)
                .environment(\.liveIndicators, services.preferences.liveIndicators)
        }
        // The design lays the dashboard out at 1120 wide: four stat tiles in a
        // row, then a 372 pt power-meter column beside the chart. At the old
        // 720 the tiles wrapped and the sessions table's fixed trailing columns
        // ate the whole row, so the window opened showing a clipped version of
        // a layout that was correct.
        .defaultSize(width: Theme.Layout.dashboardWidth, height: 780)

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

        // The refresh interval reaches outside its own view and is applied
        // here, once, before anything runs. The settings pane stores intent;
        // deciding what the application does with it is not a leaf view's job.
        // Appearance is not applied here: `AppearanceController` owns it, and
        // owns it from launch rather than from the first time this view runs.
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
    // `NSApp` is an implicitly unwrapped optional and is nil until
    // `NSApplicationMain` has run. Every caller is supposed to be past that
    // point; one was not, and the trap it produced killed the process at launch
    // with nothing on screen to say why. Returning is the right answer because
    // the value is stored and `AppearanceController` applies it again as soon
    // as there is an application to apply it to.
    guard NSApp != nil else { return }

    let appearance: NSAppearance? = switch mode {
    case .auto: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
    NSApp.appearance = appearance
    // Setting the application appearance is not enough on its own. The
    // menu-bar popover picks it up, but a `Window` scene opened afterwards was
    // observed rendering in the system appearance regardless: Light in
    // Settings, a dark dashboard on a dark system, both on screen at once.
    // Assigning it to each window as well is what actually makes the setting
    // mean something. Nil is assigned too, and deliberately — that is how a
    // window is put back to following the system for `.auto`.
    for window in NSApp.windows { window.appearance = appearance }
}

enum DashboardWindow {
    static let id = "claudence.dashboard"
}

/// Closes the menu bar popover.
///
/// Every footer link and the dashboard button open a real window, and leaving
/// the popover hanging over it is wrong twice: the window it opened is behind
/// the popover on screen, and the popover is still showing a menu the user has
/// finished with. Nothing in SwiftUI dismisses a `MenuBarExtra`:
/// `@Environment(\.dismiss)` is inert inside one, and the scene exposes no
/// binding for it.
///
/// So the menu bar item is clicked, which is what the user would do. The
/// obvious alternative -- finding the popover window and ordering it out -- was
/// tried first and is wrong in a way that only shows up on the next click:
/// SwiftUI keeps its own idea of whether the popover is presented, ordering the
/// window out does not change it, and the following click is spent toggling
/// that stale flag rather than reopening. Measured on macOS 26: the popover
/// vanished as intended, then took two clicks to come back. Driving the item
/// keeps SwiftUI's state and the screen agreeing.
///
/// The two windows involved were read out of `NSApp.windows` with the popover
/// open rather than assumed:
///
/// ```
/// NSStatusBarWindow            title "Item-0"  level 25   the menu bar item
/// MenuBarExtraWindow<AnyView>  title ""        level 101  the popover
/// ```
///
/// Neither class is public API, so both are matched by name and the whole thing
/// degrades to doing nothing if either name changes. That is the right failure:
/// a popover that stays open is untidy, and anything more forceful risks
/// ordering the menu bar item itself off the screen.
@MainActor
func dismissMenuBarPopover() {
    let isOpen = NSApp.windows.contains { window in
        window.isVisible && String(describing: type(of: window)).hasPrefix("MenuBarExtraWindow")
    }
    guard isOpen else { return }

    let statusWindow = NSApp.windows.first { window in
        String(describing: type(of: window)).hasPrefix("NSStatusBar")
    }
    guard let button = statusWindow?.contentView.flatMap(statusBarButton(in:)) else { return }

    // Deferred by one turn of the run loop. The caller is inside the button
    // action of a view this click tears down, and clicking the item from
    // underneath it is the kind of re-entrancy that AppKit does not promise
    // anything about.
    Task { @MainActor in button.performClick(nil) }
}

/// The menu bar item's button, wherever AppKit has it in the view tree.
@MainActor
private func statusBarButton(in view: NSView) -> NSStatusBarButton? {
    if let button = view as? NSStatusBarButton { return button }
    for subview in view.subviews {
        if let button = statusBarButton(in: subview) { return button }
    }
    return nil
}

/// Opens one of the app's windows and puts it in front of whatever is there.
///
/// `NSApp.setActivationPolicy(.accessory)` is what keeps Claudence out of the
/// Dock and the app switcher, and it is also why this function has to exist: an
/// accessory app is never activated, so a window it opens is ordered into the
/// window server behind whichever app currently owns the front. The window is
/// genuinely open and genuinely focused as far as SwiftUI is concerned, which
/// is why it does not read as a crash; it is simply underneath everything.
///
/// Two steps are needed and neither is sufficient alone. `NSApp.activate()`
/// makes Claudence the active app, and `orderFrontRegardless()` raises the
/// window even though an accessory app is not supposed to be able to.
///
/// The retry loop is there because `openWindow` and `openSettings` return
/// before AppKit has finished creating the window, so there is nothing to raise
/// on the tick that asked for it. It is bounded, it stops on the first success,
/// and it stops for good after roughly half a second. Nothing here repeats once
/// the window is up.
/// - Parameters:
///   - sceneIdentifier: a fragment of the window's AppKit identifier.
///   - title: the window's title, matched as a fallback. Both are checked
///     because SwiftUI promises neither: a `Window` scene's identifier carries
///     its id on current macOS, and the title is what remains if that changes.
@MainActor
func presentWindow(sceneIdentifier: String, title: String) {
    NSApp.activate()
    Task { @MainActor in
        for _ in 0..<16 {
            // Invisible windows are skipped, so a closed window left over from
            // a previous open cannot satisfy the search before the new one is
            // created.
            let match = NSApp.windows.first { window in
                guard window.isVisible else { return false }
                if let raw = window.identifier?.rawValue, raw.contains(sceneIdentifier) {
                    return true
                }
                return window.title == title
            }
            if let match {
                // A window created after `applyAppearance` ran never saw it, so
                // the setting is re-applied here rather than only at launch and
                // on change. Without this the dashboard opens in the system
                // appearance while the popover honours the preference.
                match.appearance = NSApp.appearance
                match.makeKeyAndOrderFront(nil)
                match.orderFrontRegardless()
                return
            }
            try? await Task.sleep(for: .milliseconds(30))
        }

        // Neither the identifier nor the title matched, which means one of them
        // changed underneath us. Raise the newest titled window instead of
        // giving up: the popover has no title bar, so `.titled` is what keeps
        // this from grabbing the menu bar content and hiding the real window
        // behind it. Ordering by number puts the most recently created first.
        NSApp.windows
            .filter { $0.isVisible && $0.styleMask.contains(.titled) }
            .max { $0.windowNumber < $1.windowNumber }
            .map {
                $0.makeKeyAndOrderFront(nil)
                $0.orderFrontRegardless()
            }
    }
}

/// What the dashboard's refresh button does.
///
/// It used to rebuild the aggregates and nothing else, which made it a button
/// that could not change most of what was on screen: the aggregates come out of
/// SQLite, and SQLite only moves when the engine has read a transcript into it.
/// Pressing it on a machine where nothing had changed since the window opened
/// redrew the same figures, and the usage tubes -- the part of the dashboard a
/// user is most likely to want current -- were served from whatever the last
/// scheduled fetch had left in memory and could be an hour stale either way.
///
/// So all three layers are refreshed, in the order they feed each other:
/// sessions and transcripts first, because that is what writes the rows; then a
/// forced usage fetch, which is the one place the application goes to the
/// network and is exactly what an explicit refresh is for; then the aggregates,
/// which read what the first step wrote.
///
/// This is the only path that forces a fetch off the usage cadence besides the
/// popover's own refresh, and it is user-initiated in both cases. Nothing here
/// runs on a timer.
@MainActor
private func refresh(_ model: MonitorViewModel) {
    Task { @MainActor in
        await model.handleFilesystemChange()
        await model.refreshUsageNow()
        model.refreshDashboard()
    }
}

/// Rebuilds the dashboard aggregates when the window appears. They read the
/// database, so they are never derived from a snapshot.
///
/// It is also the window's one bridge to `Preferences`. `Show subagents` and
/// `Compact rows` name things the dashboard draws, so the switches have to
/// reach it; the sheet used to pass `showsSubagents: true` as a literal and the
/// sessions card had no compact form at all, which made both controls read as
/// menu-bar-only without saying so.
private struct DashboardHost: View {
    let model: MonitorViewModel
    let preferences: Preferences
    @State private var selectedSession: AISession?

    var body: some View {
        // Read here rather than inside the sheet's builder. The builder is an
        // escaping closure evaluated outside this body's observation scope, so
        // a preference read only in there registers no dependency and a switch
        // flipped while a detail is open would not reach the open sheet.
        let showsSubagents = preferences.showSubagents
        // Both handlers are what the design's own chrome promises: a refresh
        // button in the header, and a card subtitle that says a row can be
        // clicked. Passed from here rather than defaulted inside the view,
        // because only the host can reach the model that answers them.
        return DashboardView(
            data: model.dashboard,
            isCompact: preferences.compactRows,
            onRefresh: { refresh(model) },
            onSelectSession: { session in selectedSession = session }
        )
        .task { model.refreshDashboard() }
        .sheet(item: $selectedSession) { session in
            let rate = model.burnRate(for: session)
            SessionDetailView(
                session: session,
                subagents: model.subagents(for: session),
                tokenScaleMaximum: model.tokenScaleMaximum,
                burnRatePerMinute: rate.tokensPerMinute > 0 ? rate.tokensPerMinute : nil,
                burnHistory: rate.samples,
                windowShare: model.windowShare(for: session),
                showsSubagents: showsSubagents,
                onClose: { selectedSession = nil }
            )
            .detailSheetChrome()
            // Subagent rows are pulled when a detail opens, not on every
            // refresh, exactly as the popover's own sheet does it.
            .task(id: session.id) { await model.refreshSubagents(for: session.id) }
        }
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
