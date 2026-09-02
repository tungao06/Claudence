import SwiftUI

// MARK: - Layout tokens

/// Tokens the popover never needed. Added here rather than in `Theme.swift`
/// because settings is the only surface that is a real window.
extension Theme.Layout {
    /// A settings window, not the 300 pt popover. Wide enough for a sentence
    /// of explanation on one or two lines.
    static let settingsWidth: CGFloat = 420
    static let settingsPadding: CGFloat = 20
    static let settingsMinHeight: CGFloat = 420
    static let settingsMaxHeight: CGFloat = 760
    static var settingsContentWidth: CGFloat { settingsWidth - settingsPadding * 2 }
    /// Vertical gap between two sections. Larger than `Space.xl` so the three
    /// sections read as separate topics without needing a card each.
    static let settingsSectionGap: CGFloat = 22
    /// Indent under a control, so its explanation lines up with the label.
    static let settingsExplanationIndent: CGFloat = 20
}

// MARK: - Section chrome

/// A titled block. The only section header in settings, so the type scale is
/// applied once rather than at four call sites.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title.uppercased())
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textSecondary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityLabel(title)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one-line explanation that sits under a control.
///
/// Hidden from VoiceOver: the same sentence is attached to its control as an
/// accessibility hint, and reading it twice is worse than reading it once.
struct SettingsExplanation: View {
    let text: String
    var indented: Bool = true

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, indented ? Theme.Layout.settingsExplanationIndent : 0)
            .accessibilityHidden(true)
    }
}

/// A paragraph of body copy. Used by the privacy disclosure, which is prose
/// rather than controls.
struct SettingsParagraph: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Version

/// The application version, read from the bundle and never invented.
///
/// A binary launched outside a bundle has no `Info.plist`, so both keys can be
/// absent. That state is reported as "unknown"; a plausible-looking version
/// string would be a fabricated number, which section 9.4 forbids.
enum AppVersion {
    static let unknown = "unknown"

    static var short: String { string(forKey: "CFBundleShortVersionString") }
    static var build: String { string(forKey: "CFBundleVersion") }

    /// `0.1.0 (1)`, or `unknown` when the bundle says nothing.
    static var display: String {
        let short = short
        let build = build
        if short == unknown && build == unknown { return unknown }
        if build == unknown { return short }
        return "\(short) (\(build))"
    }

    private static func string(forKey key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.trimmingCharacters(in: .whitespaces).isEmpty
        else { return unknown }
        return value
    }
}

// MARK: - Settings

/// The settings window. Three sections in fixed order: what the app does, what
/// it reads, and what it is.
struct SettingsView: View {
    @Bindable var preferences: Preferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.settingsSectionGap) {
                GeneralSettings(preferences: preferences)
                Divider().overlay(Theme.separator)
                PrivacySettings()
                Divider().overlay(Theme.separator)
                AboutSettings()
            }
            .padding(Theme.Layout.settingsPadding)
            .frame(width: Theme.Layout.settingsWidth, alignment: .leading)
        }
        .frame(width: Theme.Layout.settingsWidth)
        .frame(
            minHeight: Theme.Layout.settingsMinHeight,
            maxHeight: Theme.Layout.settingsMaxHeight
        )
        .background(Theme.surface)
    }
}

// MARK: - About

/// Version and the estimate disclaimer. Section 9.4: anything derived rather
/// than measured says so, every time it is shown.
struct AboutSettings: View {
    var body: some View {
        SettingsSection(title: "About") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Claudence")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(AppVersion.display)
                        .font(Theme.Typography.numeric)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Claudence version \(AppVersion.display)")

                SettingsParagraph(text: Self.estimateDisclaimer)
            }
        }
    }

    /// Named, so the same sentence cannot drift between here and the popover.
    static let estimateDisclaimer = """
    Usage and cost figures are estimates. Token counts come from the transcript \
    files Claude Code writes, and cost is worked out from published model prices. \
    Neither is a bill. Where a figure cannot be worked out, Claudence says so \
    instead of showing a zero.
    """
}

// MARK: - Scene

/// The settings window, ready to be added to the app's `body`. Exposed as a
/// `Scene` so composition is one line and `ClaudenceApp` needs no knowledge of
/// what settings contains.
struct SettingsScene: Scene {
    let preferences: Preferences

    var body: some Scene {
        Settings {
            SettingsView(preferences: preferences)
        }
    }
}
