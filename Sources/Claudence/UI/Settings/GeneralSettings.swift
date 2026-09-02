import SwiftUI
import ClaudenceCore

/// When Claudence starts, and how much of a session it lists.
///
/// Two sections rather than one: startup is a macOS fact Claudence only reports,
/// while the session controls are ordinary stored preferences. Mixing them would
/// suggest the login item behaves like the switches under it, and it does not.
///
/// Every control carries an accessibility label and a hint holding the same
/// sentence printed underneath it, so a VoiceOver user hears the explanation a
/// sighted user reads.
struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.settingsSectionGap) {
            SettingsSection(title: "Startup") {
                launchAtLoginRow
            }
            SettingsSection(title: "Sessions") {
                VStack(alignment: .leading, spacing: Theme.Space.xl) {
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
        // The login item can be switched off in System Settings while this
        // window is closed, so the status is re-read rather than remembered.
        .onAppear { preferences.refreshLaunchAtLoginStatus() }
    }

    // MARK: Launch at login

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(isOn: $preferences.launchAtLogin) {
                Text("Launch at login")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Launch at login")
            .accessibilityHint(Self.launchExplanation)
            // The toggle reads `launchAtLoginState`, which is re-read from
            // macOS after every attempt. A refused registration therefore
            // shows as off within the same update, never as a click that
            // appeared to work.
            .accessibilityValue(preferences.launchAtLoginState.summary)

            SettingsExplanation(text: Self.launchExplanation)
            statusLine
            failureLine
        }
        .animation(
            Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
            value: preferences.launchAtLoginState
        )
    }

    /// The real `SMAppService` status, glyph first so it never depends on
    /// colour alone.
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: preferences.launchAtLoginState.glyph)
                .font(.system(size: Theme.Bar.severityGlyph))
                .foregroundStyle(statusColor)
            Text(preferences.launchAtLoginState.summary)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, Theme.Layout.settingsExplanationIndent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("macOS reports: \(preferences.launchAtLoginState.summary)")
    }

    /// Accent for the working state, attention for the one the user can fix,
    /// tertiary otherwise. Severity tokens are reserved for usage, so none is
    /// borrowed here.
    private var statusColor: Color {
        switch preferences.launchAtLoginState {
        case .enabled: return Theme.accent
        case .requiresApproval: return Theme.attention
        case .notRegistered, .notFound, .unrecognized: return Theme.textTertiary
        }
    }

    @ViewBuilder
    private var failureLine: some View {
        if let failure = preferences.launchAtLoginFailure {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text(failure)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if preferences.launchAtLoginState.needsSystemSettings {
                    Button("Open Login Items in System Settings") {
                        preferences.openLoginItemsSettings()
                    }
                    .font(Theme.Typography.caption)
                    .accessibilityLabel("Open Login Items in System Settings")
                    .accessibilityHint("Allow Claudence to start at login, then return here.")
                }
            }
            .padding(.leading, Theme.Layout.settingsExplanationIndent)
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Copy

    private static let launchExplanation = """
    macOS starts Claudence when you log in. The status below is what macOS \
    reports, not what this switch was set to.
    """

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
