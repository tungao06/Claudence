import SwiftUI
import ClaudenceCore

/// When Claudence is allowed to interrupt a human.
///
/// The four rows run in the design's own order — usage threshold, completed,
/// failed, permission — with two additions that are deliberate and are not the
/// design's:
///
/// - A master switch above them. The per-event switches are inert while it is
///   off, so they are disabled rather than left looking live. Nothing in the
///   design turns notifications off as a group; dropping the switch would take
///   a working capability away and leave "turn every one of them off
///   individually" as the only way to get silence.
/// - `Session goes idle`, which has a real `NotificationEvent` case, a real
///   preference key and a deriver that fires it. It is off by default because
///   pausing while you read a diff is the ordinary case, not news.
///
/// ## The two rows that cannot be switched on
///
/// The design draws one of the four, `Permission required`, disabled. The code
/// says two are undeliverable, not one, and this was checked against the code
/// rather than assumed:
///
/// - `SessionStatus.permission` returns false from `isDerivable`. Nothing in the
///   registry or the transcript says a session is waiting on a permission
///   prompt.
/// - `SessionStatus.error` returns false too, `NotificationEvent` has no case
///   for it, and the type's own doc comment records why: the registry carries no
///   exit condition at all. A session that crashed and one that finished cleanly
///   both leave by having their `~/.claude/sessions/<pid>.json` file removed,
///   with no exit code, no signal and no terminal status anywhere in the
///   snapshot. "Failed" cannot be told apart from "completed" without inventing
///   it.
///
/// So `Session failed` is drawn disabled as well. The design ships it enabled
/// and On; the design is wrong, and `CLAUDE.md`'s rule that no UI ships for a
/// state with no data source decides it. Both rows are
/// `SettingsUnavailableToggle`, which has no binding behind it: there is no
/// preference key for either, because a key that can only ever hold its default
/// is a lie in `UserDefaults`. Both come back the day a source is proven, and
/// neither the deriver nor the throttle needs a change to carry them.
struct NotificationSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsSection(title: "Notifications") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsToggle(
                    title: "Notify me about sessions and limits",
                    explanation: Self.masterExplanation,
                    isOn: $preferences.notificationsEnabled
                )

                VStack(alignment: .leading, spacing: Theme.Space.l) {
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
                    SettingsUnavailableToggle(
                        title: "Session failed",
                        reason: Self.failedUnavailable
                    )
                    SettingsUnavailableToggle(
                        title: "Permission required",
                        reason: Self.permissionUnavailable
                    )
                    SettingsToggle(
                        title: "Session needs an answer",
                        explanation: Self.needsInputExplanation,
                        isOn: $preferences.notifyOnSessionNeedsInput
                    )
                    SettingsToggle(
                        title: "Session goes idle",
                        explanation: Self.idleExplanation,
                        isOn: $preferences.notifyOnSessionIdle
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

    private static let needsInputExplanation = """
    When a session asks you something and stops until you answer. On by \
    default: it is the one state where nothing happens at all until you look. \
    Claudence never reads the question itself, so the notification names the \
    project and nothing more.
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
