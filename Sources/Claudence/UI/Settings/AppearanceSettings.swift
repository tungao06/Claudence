import SwiftUI
import ClaudenceCore

/// How Claudence looks: the menu bar reading, the palette, and motion.
///
/// Three small sections rather than one, because they answer three different
/// questions and only the first one has a hard constraint attached to it.
struct AppearanceSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.settingsSectionGap) {
            menuBarSection
            appearanceSection
            motionSection
        }
    }

    // MARK: Menu bar

    private var menuBarSection: some View {
        SettingsSection(title: "Menu bar") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsToggle(
                    title: "Show a live reading in the menu bar",
                    explanation: Self.readingExplanation,
                    isOn: $preferences.showMenuBarUsage
                )
                SettingsPicker(
                    title: "What to show",
                    options: MenuBarStyle.allCases,
                    optionTitle: \.title,
                    explanation: styleExplanation,
                    selection: $preferences.menuBarStyle,
                    isEnabled: preferences.showMenuBarUsage
                )
            }
        }
    }

    /// The design's own help sentence while the control is live, and the reason
    /// it is dead when it is not. A disabled control that explains nothing is
    /// the same defect as a metric that renders a zero it never measured.
    private var styleExplanation: String {
        preferences.showMenuBarUsage
            ? Self.styleHelp
            : "Turn the live reading on to choose what it shows."
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            SettingsPicker(
                title: "Appearance",
                options: AppearanceMode.allCases,
                optionTitle: \.title,
                explanation: preferences.appearance.explanation,
                selection: $preferences.appearance
            )
        }
    }

    // MARK: Motion

    private var motionSection: some View {
        SettingsSection(title: "Motion") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SettingsToggle(
                    title: "Live indicators",
                    explanation: Self.liveIndicatorsExplanation,
                    isOn: $preferences.liveIndicators
                )
                SettingsExplanation(text: Self.reduceMotionFootnote, indented: false)
            }
        }
    }

    // MARK: Copy

    private static let readingExplanation = """
    Off keeps the menu bar to a plain icon, so nothing about your usage is \
    legible over your shoulder.
    """

    /// Design section 7, verbatim. The 60 pt half is a real requirement, not a
    /// figure of speech: see the measurement table on `MenuBarLabel`.
    private static let styleHelp =
        "Session count stays opt-in; width never exceeds 60 pt."

    /// Not the design's sentence.
    ///
    /// The design says "Bars glow softly while a session is working", which
    /// describes a `.repeatForever` animation. `CLAUDE.md` forbids one anywhere
    /// in the popover, and for a measured reason: `MenuBarExtra(style: .window)`
    /// keeps its content mounted after dismissal, so one repeating animation
    /// cost 6.9% of a core against a 0.5% budget with the popover never opened.
    /// What ships instead marks the working session and animates once when its
    /// numbers move, so the help text says that rather than promising a glow
    /// that is never coming.
    private static let liveIndicatorsExplanation = """
    Mark the sessions that are working, and animate a value once when it moves, \
    so you can tell live from stalled. Nothing repeats or animates while idle.
    """

    /// Design section 7, verbatim, and accurate: every animation in the app is
    /// routed through `Theme.animation(_:reduceMotion:)`, which returns nil when
    /// the system setting is on, so values snap instead of gliding.
    private static let reduceMotionFootnote =
        "System Reduce Motion always wins over this switch."
}
