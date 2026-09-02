import SwiftUI
import ClaudenceCore

/// When Claudence is allowed to interrupt a human.
///
/// The master switch decides whether anything is posted at all; the per-event
/// switches below it choose which ones, and are inert while it is off, so they
/// are disabled rather than left looking live.
///
/// ## The two rows that cannot be switched on
///
/// Design section 7 lists four notifications and draws one of them, `Permission
/// required`, disabled. The code says two are undeliverable, not one:
///
/// - `SessionStatus.permission` returns false from `isDerivable`. Nothing in the
///   registry or the transcript says a session is waiting on a permission
///   prompt.
/// - `SessionStatus.error` returns false too, and `NotificationEvent` records
///   why in more detail: the registry carries no exit condition at all. A
///   session that crashed and one that finished cleanly both leave by having
///   their `~/.claude/sessions/<pid>.json` file removed, with no exit code, no
///   signal and no terminal status anywhere in the snapshot. "Failed" cannot be
///   told apart from "completed" without inventing it.
///
/// So `Session failed` is drawn disabled as well, against the design, and its
/// explanation names the real reason rather than repeating a generic one. Both
/// rows are `SettingsUnavailableToggle`, which has no binding behind it: there
/// is no preference key for either, because a key that can only ever hold its
/// default is a lie in `UserDefaults`. Both come back the day a source is
/// proven, and neither the deriver nor the throttle needs a change to carry
/// them.
struct NotificationSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsSection(title: "Notifications") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsToggle(
                    title: "Notify me about sessions and limits",
                    explanation: Self.masterExplanation,
                    isOn: $preferences.notificationsEnabled
                )

                VStack(alignment: .leading, spacing: Theme.Space.xl) {
                    SettingsToggle(
                        title: Self.usageThresholdTitle,
                        explanation: Self.usageThresholdExplanation,
                        isOn: $preferences.notifyOnUsageThreshold
                    )
                    SettingsToggle(
                        title: "Session completed",
                        explanation: Self.completedExplanation,
                        isOn: $preferences.notifyOnSessionCompleted
                    )
                    SettingsToggle(
                        title: "Session goes idle",
                        explanation: Self.idleExplanation,
                        isOn: $preferences.notifyOnSessionIdle
                    )
                    SettingsUnavailableToggle(
                        title: "Session failed",
                        reason: Self.failedUnavailable
                    )
                    SettingsUnavailableToggle(
                        title: "Permission required",
                        reason: Self.permissionUnavailable
                    )
                }
                .padding(.leading, Theme.Layout.settingsExplanationIndent)
                .disabled(!preferences.notificationsEnabled)
            }
        }
    }

    // MARK: Copy

    private static let masterExplanation = """
    A notification when a session finishes and when a usage window is nearly \
    spent. macOS asks for permission separately, the first time one is sent.
    """

    /// Built from the constant the deriver fires on, so the label and the
    /// behaviour cannot drift apart.
    private static let usageThresholdTitle =
        "Usage reaches \(Int(Constants.UsageThreshold.critical))%"

    private static let usageThresholdExplanation = """
    Once per window, when it crosses upward. A window that dips and crosses \
    again does not notify twice.
    """

    private static let completedExplanation = """
    When a session is gone from the registry and its process is confirmed gone \
    with it. A discovery hiccup on its own never counts.
    """

    private static let idleExplanation = """
    When a session stops working but stays open. Off by default: pausing while \
    you read the diff is the ordinary case, not news.
    """

    /// Deliberately not the design's generic sentence. The design's wording for
    /// the disabled row, "this state is not derivable yet", is true but says
    /// nothing about why, and this reason is specific and worth stating.
    private static let failedUnavailable = """
    Unavailable. A session that crashed and one that finished cleanly leave the \
    same way, with no exit code recorded anywhere, so Claudence cannot tell them \
    apart without guessing.
    """

    /// The design's own explanation, with its em dash rewritten as a full stop.
    private static let permissionUnavailable =
        "Unavailable. This state is not derivable yet."
}
