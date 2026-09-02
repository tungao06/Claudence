import SwiftUI

/// The three controls that change what the application does.
///
/// Every control carries an accessibility label and a hint holding the same
/// sentence printed underneath it, so a VoiceOver user hears the explanation a
/// sighted user reads.
struct GeneralSettings: View {
    @Bindable var preferences: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsSection(title: "General") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                launchAtLoginRow
                menuBarReadingRow
                menuBarStyleRow
                notificationsRow
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
                Text("Start Claudence at login")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Start Claudence at login")
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

    // MARK: Menu bar

    private var menuBarReadingRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(isOn: $preferences.showMenuBarUsage) {
                Text("Show a live reading in the menu bar")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Show a live reading in the menu bar")
            .accessibilityHint(Self.readingExplanation)

            SettingsExplanation(text: Self.readingExplanation)
        }
    }

    private var menuBarStyleRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Picker(selection: $preferences.menuBarStyle) {
                ForEach(MenuBarStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            } label: {
                Text("Menu bar reading")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!preferences.showMenuBarUsage)
            .accessibilityLabel("Menu bar reading")
            .accessibilityHint(preferences.menuBarStyle.explanation)
            .accessibilityValue(preferences.menuBarStyle.title)

            SettingsExplanation(text: styleExplanation, indented: false)
        }
        .animation(
            Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
            value: preferences.menuBarStyle
        )
        .animation(
            Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
            value: preferences.showMenuBarUsage
        )
    }

    /// A disabled picker says why it is disabled. Otherwise it explains the
    /// selected option, so the line is never inert.
    private var styleExplanation: String {
        preferences.showMenuBarUsage
            ? preferences.menuBarStyle.explanation
            : "Turn the live reading on to choose what it shows."
    }

    // MARK: Notifications

    private var notificationsRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Toggle(isOn: $preferences.notificationsEnabled) {
                Text("Notify me about sessions and limits")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textPrimary)
            }
            .toggleStyle(.switch)
            .accessibilityLabel("Notify me about sessions and limits")
            .accessibilityHint(Self.notificationsExplanation)

            SettingsExplanation(text: Self.notificationsExplanation)
        }
    }

    // MARK: Copy

    private static let launchExplanation = """
    macOS starts Claudence when you log in. The status below is what macOS \
    reports, not what this switch was set to.
    """

    private static let readingExplanation = """
    Off keeps the menu bar to a plain icon, so nothing about your usage is \
    legible over your shoulder.
    """

    private static let notificationsExplanation = """
    A notification when a session finishes and when a usage window is nearly \
    spent. macOS asks for permission separately, the first time one is sent.
    """
}
