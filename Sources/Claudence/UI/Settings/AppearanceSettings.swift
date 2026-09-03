import SwiftUI
import ClaudenceCore

// MARK: - Motion

/// The design's first settings block.
///
/// It is first because it is the one setting whose effect the reader can see
/// while the window is open, and because the sentence under it is a statement
/// about who wins: the system's Reduce Motion always does.
struct MotionSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsSection(title: Self.sectionTitle) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsToggle(
                    title: Self.liveIndicatorsTitle,
                    explanation: Self.liveIndicatorsExplanation,
                    isOn: $preferences.liveIndicators
                )
                SettingsExplanation(text: Self.reduceMotionFootnote)
            }
        }
    }

    private static let sectionTitle = Phrase(en: "Motion", th: "การเคลื่อนไหว")

    private static let liveIndicatorsTitle = Phrase(en: "Live indicators", th: "ตัวบ่งชี้แบบเรียลไทม์")

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
    ///
    /// The sentence also used to over-promise in the other direction. It said
    /// the switch animates a value when it moves, and for a while only the
    /// status pulse was wired to it: every bar, ring and arc animated whatever
    /// the switch was set to. The flag now reaches them through
    /// `EnvironmentValues.liveIndicators`, and the wording says what off leaves
    /// behind -- the readings, still -- because off does not hide anything.
    private static let liveIndicatorsExplanation = Phrase(
        en: """
        Animate a value once when it moves, and pulse the mark on a working session, \
        so you can tell live from stalled. Off leaves every reading in place and \
        still. Nothing repeats or animates while idle either way.
        """,
        th: """
        เคลื่อนไหวค่าครั้งเดียวเมื่อมันเปลี่ยน และกะพริบสัญลักษณ์บน session ที่กำลังทำงาน \
        เพื่อให้บอกได้ว่า live หรือค้าง ปิดไว้จะให้ทุกค่าคงที่และนิ่ง ไม่ว่าจะเปิดหรือปิด \
        จะไม่มีอะไรเคลื่อนไหวซ้ำขณะไม่มีการเปลี่ยนแปลง
        """
    )

    /// Design section 7, verbatim, and accurate: every animation in the app is
    /// routed through `Theme.animation(_:reduceMotion:)`, which returns nil when
    /// the system setting is on, so values snap instead of gliding.
    private static let reduceMotionFootnote = Phrase(
        en: "System Reduce Motion always wins over this switch.",
        th: "การตั้งค่า Reduce Motion ของระบบมีผลเหนือกว่าสวิตช์นี้เสมอ"
    )
}

// MARK: - Menu bar

/// One block, as the design has it: what the menu bar shows, whether Claudence
/// starts with the machine, and which palette it uses.
///
/// These were three separate eyebrows — `Startup`, `Menu bar`, `Appearance` —
/// which is three headings for what the design presents as one topic: the thing
/// that is always on screen. Launch at login belongs here for the same reason
/// the design puts it here: it is a fact about the menu bar item's presence,
/// not about sessions or notifications.
struct MenuBarSettings: View {
    @Bindable var preferences: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var language

    var body: some View {
        SettingsSection(title: Self.sectionTitle) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // Not in the design, and kept deliberately. Without it the only
                // way to stop the menu bar publishing a usage percentage over
                // your shoulder is to quit the application, and the preference
                // behind it is already persisted.
                SettingsToggle(
                    title: Self.readingTitle,
                    explanation: Self.readingExplanation,
                    isOn: $preferences.showMenuBarUsage
                )
                SettingsPicker(
                    title: Self.whatToShowTitle,
                    options: MenuBarStyle.allCases,
                    optionTitle: \.title,
                    explanation: styleExplanation,
                    selection: $preferences.menuBarStyle,
                    isEnabled: preferences.showMenuBarUsage
                )
                launchAtLoginRow
                SettingsPicker(
                    title: Self.appearanceTitle,
                    options: AppearanceMode.allCases,
                    optionTitle: \.title,
                    explanation: preferences.appearance.explanation,
                    selection: $preferences.appearance
                )
            }
        }
        // The login item can be switched off in System Settings while this
        // window is closed, so the status is re-read rather than remembered.
        .onAppear { preferences.refreshLaunchAtLoginStatus() }
    }

    /// The design's own help sentence while the control is live, and the reason
    /// it is dead when it is not. A disabled control that explains nothing is
    /// the same defect as a metric that renders a zero it never measured.
    private var styleExplanation: Phrase {
        preferences.showMenuBarUsage
            ? Self.styleHelp
            : Self.styleDisabledHelp
    }

    // MARK: Launch at login

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(alignment: .center, spacing: Theme.Space.l) {
                PhraseText(Self.launchTitle)
                    .font(Theme.Typography.rowLabel)
                    .foregroundStyle(Theme.textPrimary)

                Spacer(minLength: Theme.Space.s)

                Toggle(isOn: $preferences.launchAtLogin) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(ClaudenceToggleStyle())
                    .accessibilityLabel(Self.launchTitle, in: language)
                    .accessibilityHint(Self.launchExplanation.string(in: language))
                    // The toggle reads `launchAtLoginState`, which is re-read
                    // from macOS after every attempt. A refused registration
                    // therefore shows as off within the same update, never as
                    // a click that appeared to work.
                    .accessibilityValue(preferences.launchAtLoginState.summary.string(in: language))
            }

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
    /// colour alone. Left-aligned with the label above it: this is more
    /// context for the same row, not a nested sub-item.
    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: preferences.launchAtLoginState.glyph)
                .font(.system(size: Theme.Bar.severityGlyph))
                .foregroundStyle(statusColor)
            PhraseText(preferences.launchAtLoginState.summary)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.statusReport.format(in: language, preferences.launchAtLoginState.summary.string(in: language))
        )
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
                PhraseText(failure)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if preferences.launchAtLoginState.needsSystemSettings {
                    Button(Self.openSystemSettingsTitle.string(in: language)) {
                        preferences.openLoginItemsSettings()
                    }
                    .font(Theme.Typography.caption)
                    .accessibilityLabel(Self.openSystemSettingsTitle, in: language)
                    .accessibilityHint(Self.openSystemSettingsHint.string(in: language))
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Copy

    private static let sectionTitle = Phrase(en: "Menu bar", th: "Menu bar")

    private static let readingTitle = Phrase(
        en: "Show a live reading in the menu bar",
        th: "แสดงค่าแบบเรียลไทม์บน menu bar"
    )

    private static let whatToShowTitle = Phrase(en: "What to show", th: "แสดงอะไรบ้าง")

    private static let appearanceTitle = Phrase(en: "Appearance", th: "รูปลักษณ์")

    private static let launchTitle = Phrase(en: "Launch at login", th: "เปิดโปรแกรมตอนเข้าสู่ระบบ")

    private static let openSystemSettingsTitle = Phrase(
        en: "Open Login Items in System Settings",
        th: "เปิด Login Items ใน System Settings"
    )

    private static let openSystemSettingsHint = Phrase(
        en: "Allow Claudence to start at login, then return here.",
        th: "อนุญาตให้ Claudence เริ่มทำงานตอนเข้าสู่ระบบ แล้วกลับมาที่นี่"
    )

    /// "macOS reports: %@" — the report and the reported status, in the
    /// reader's own word order.
    private static let statusReport = Phrase(
        en: "macOS reports: %@",
        th: "macOS รายงานว่า: %@"
    )

    private static let readingExplanation = Phrase(
        en: """
        Off keeps the menu bar to a plain icon, so nothing about your usage is \
        legible over your shoulder.
        """,
        th: """
        ปิดไว้จะให้ menu bar เหลือแค่ไอคอนเปล่า ไม่มีข้อมูลการใช้งานให้ใครแอบมองข้ามไหล่เห็น
        """
    )

    /// Design section 7, verbatim. The 60 pt half is a real requirement, not a
    /// figure of speech: see the measurement table on `MenuBarLabel`.
    private static let styleHelp = Phrase(
        en: "Session count stays opt-in; width never exceeds 60 pt.",
        th: "การแสดงจำนวน session ยังคงเลือกเปิดเองได้ ความกว้างไม่เกิน 60 pt เสมอ"
    )

    private static let styleDisabledHelp = Phrase(
        en: "Turn the live reading on to choose what it shows.",
        th: "เปิดค่าแบบเรียลไทม์ก่อนจึงจะเลือกสิ่งที่จะแสดงได้"
    )

    private static let launchExplanation = Phrase(
        en: """
        macOS starts Claudence when you log in. The status below is what macOS \
        reports, not what this switch was set to.
        """,
        th: """
        macOS จะเปิด Claudence ให้เมื่อคุณเข้าสู่ระบบ สถานะด้านล่างคือค่าที่ macOS \
        รายงานจริง ไม่ใช่ค่าที่ตั้งไว้ในสวิตช์นี้
        """
    )
}
