import Observation
import ClaudenceCore

/// Carries the interface language to the one place that cannot read it from
/// the environment.
///
/// ## Why this exists
///
/// Every view gets the language through `\.appLanguage`, injected at both
/// scene roots. A notification is not a view. `NotificationBridge` builds its
/// text from `NotificationEvent` on whatever thread the engine published from,
/// with no environment to read and no `Preferences` reference of its own --
/// deliberately, because handing that `@MainActor @Observable` object to the
/// notification path would drag the settings model into the delivery path and
/// put an actor hop in front of a decision taken off the main actor.
///
/// So the language is pushed rather than pulled, and this is what pushes it.
///
/// ## Why from the application rather than from a view
///
/// The same trap `AppearanceController`'s own header describes: `MenuBarExtra`
/// does not build its content until the popover is first opened, so an
/// observer living there is not listening at launch. A user who never opens
/// the popover still gets notifications, and they would have arrived in the
/// wrong language until the moment they did.
///
/// `withObservationTracking` is not a poll: the closure runs once to record
/// what was read, and `onChange` fires only when it is written. An idle
/// application does no work here.
@MainActor
final class LanguageController {
    private let preferences: Preferences
    private let notifications: NotificationBridge

    init(preferences: Preferences, notifications: NotificationBridge) {
        self.preferences = preferences
        self.notifications = notifications
    }

    func start() {
        notifications.language = preferences.appLanguage
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = preferences.appLanguage
        } onChange: {
            // `onChange` fires before the new value is stored and off the main
            // actor, so the read is hopped rather than done here -- reading in
            // the callback returns the value being replaced.
            Task { @MainActor [weak self] in
                guard let self else { return }
                notifications.language = preferences.appLanguage
                observe()
            }
        }
    }
}
