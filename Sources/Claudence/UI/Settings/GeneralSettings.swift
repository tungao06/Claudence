import SwiftUI
import ClaudenceCore

/// How much of a session Claudence lists, and how often it asks Anthropic for
/// the usage windows.
///
/// The design's third block, with the design's three controls and nothing else.
/// Launch at login used to lead this file under a `Startup` eyebrow of its own;
/// it now sits in the menu bar block, where the design puts it, because it is a
/// fact about the menu bar item rather than about sessions.
///
/// Every control carries an accessibility label and a hint holding the same
/// sentence printed underneath it, so a VoiceOver user hears the explanation a
/// sighted user reads.
struct SessionsSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsSection(title: "Sessions") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsToggle(
                    title: "Show subagents",
                    explanation: Self.subagentsExplanation,
                    isOn: $preferences.showSubagents
                )
                SettingsToggle(
                    title: "Compact rows",
                    explanation: Self.compactExplanation,
                    isOn: $preferences.compactRows
                )
                SettingsPicker(
                    title: "Usage refresh",
                    options: UsageRefreshInterval.allCases,
                    optionTitle: \.title,
                    explanation: Self.refreshExplanation,
                    selection: $preferences.usageRefreshInterval
                )
            }
        }
    }

    // MARK: Copy

    /// Design section 7, verbatim. Accurate: a subagent's tokens are billed to
    /// its parent, which is what "share of the parent" means here.
    private static let subagentsExplanation =
        "List agents spawned under each session, with their share of the parent."

    /// Design section 7, verbatim.
    private static let compactExplanation =
        "Hide duration, rate and sparkline until a row is opened."

    /// Design section 7, verbatim, and the sentence that keeps this control
    /// honest: it paces one network call and touches nothing else.
    private static let refreshExplanation =
        "Sessions and tokens update on file change; this only paces the usage-limit call."
}
