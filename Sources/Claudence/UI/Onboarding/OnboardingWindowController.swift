import AppKit
import SwiftUI

/// Presents the first-launch screen in a real, ordinary `NSWindow` -- opened
/// directly through AppKit rather than declared as a SwiftUI `Window` scene.
///
/// ## Why not a `Window` scene
///
/// Every other extra window this app owns (`DashboardWindow`, the settings
/// window) is opened through `openWindow`/`openSettings`, called from inside
/// a view that is already on screen: the popover's footer link, the
/// dashboard button. Onboarding has no such view to call from. It has to
/// appear before the user has clicked anything at all, and `MenuBarExtra`
/// does not build its own popover content until the popover is opened once
/// -- see the note on `AppearanceController` for the same trap hit by a
/// different preference. There is no mounted view yet to hold the
/// `@Environment(\.openWindow)` action a scene needs, and SwiftUI makes no
/// promise that a bare `Window` scene opens itself at launch. A plain
/// `NSWindow` needs neither: it exists the moment this type creates it, and
/// showing it does not depend on anything else in the view tree having run
/// first.
///
/// ## Lifecycle
///
/// Created and told to present from `ClaudenceApp.init()`, deferred by one
/// run loop turn the same way `AppearanceController.start()` is: `NSApp` is
/// still nil while `init()` runs, and touching it there crashes before
/// anything is drawn.
///
/// `presentIfNeeded` is a no-op once `Preferences.hasCompletedOnboarding` is
/// true, so it is safe to call every launch without a separate guard at the
/// call site.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let preferences: Preferences
    private var window: NSWindow?

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Builds and shows the window, unless onboarding is already behind us or
    /// a window from an earlier call is still open.
    func presentIfNeeded<Content: View>(@ViewBuilder rootView: () -> Content) {
        guard !preferences.hasCompletedOnboarding, window == nil else { return }

        let hosting = NSHostingController(rootView: rootView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to Claudence"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window

        // An accessory app (`LSUIElement`) is never activated on its own, so
        // a window it opens is created behind whichever app currently owns
        // the front. Both calls are needed, exactly as `presentWindow` in
        // `ClaudenceApp.swift` documents for the same reason.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// What the "Get Started" button calls. Closing the window here runs the
    /// same path as the user clicking its own close button: both end at
    /// `windowWillClose`, so there is exactly one place that marks onboarding
    /// done.
    func finish() {
        window?.close()
    }

    /// Reached however the window closed -- the button below, or the red
    /// traffic light. A friend who dismisses this without pressing "Get
    /// Started" has still made the one decision onboarding exists to
    /// front-run: whether Claudence gets to run at all. Showing this again on
    /// every relaunch because the button was not the one pressed would be
    /// worse than treating any dismissal as consent to proceed.
    func windowWillClose(_ notification: Notification) {
        preferences.hasCompletedOnboarding = true
        window = nil
    }
}
