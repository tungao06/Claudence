import AppKit
import Observation

/// Applies the appearance preference to the whole application, the moment it
/// changes, whatever is on screen.
///
/// ## Why this is not an `onChange` on a view
///
/// It was. The observer lived on the menu bar popover's content, which is the
/// one view mounted for the life of the process -- except that `MenuBarExtra`
/// does not build that content until the popover is first opened. A user who
/// launched Claudence, opened Settings from the Dock-less app's only other
/// route, and switched to Light therefore changed a stored value that nothing
/// was listening to: the setting took effect at the next launch, or as soon as
/// the popover was opened for the first time, which reads as a setting that
/// does not work rather than as one that is late.
///
/// Observation belongs to the application, not to a scene, so it starts from
/// the delegate and outlives every window.
///
/// ## Cost
///
/// `withObservationTracking` is not a poll. The closure runs once to record
/// which properties were read, and `onChange` fires only when one of them is
/// written; an idle application does no work here at all, which is the standing
/// requirement for anything that lives for the whole process. Each firing
/// re-arms, because the tracking is one-shot by design.
@MainActor
final class AppearanceController {
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Begins observing, and applies the stored value once the application
    /// exists.
    ///
    /// The apply is deferred by a run loop turn and that is not a nicety.
    /// `start()` is called from `ClaudenceApp.init()`, which runs before
    /// `NSApplicationMain`, so `NSApp` is still nil there: applying immediately
    /// trapped on an implicitly unwrapped optional and the process died at
    /// launch with `EXC_BREAKPOINT` before drawing anything. Observing is safe
    /// that early, touching AppKit is not.
    func start() {
        observe()
        Task { @MainActor [weak self] in
            guard let self else { return }
            applyAppearance(preferences.appearance)
        }
    }

    private func observe() {
        withObservationTracking {
            _ = preferences.appearance
        } onChange: {
            // `onChange` fires *before* the new value is stored, and it is not
            // on the main actor. Both are why the work is hopped rather than
            // done here: reading the preference from inside the callback would
            // return the value being replaced.
            Task { @MainActor [weak self] in
                guard let self else { return }
                applyAppearance(preferences.appearance)
                observe()
            }
        }
    }
}
