import SwiftUI
import ClaudenceCore

/// The interface language, in Settings.
///
/// ## Why it is here as well as on the first-run screen
///
/// Onboarding asks once, before anything else, because the language a person
/// reads in is the first thing that decides whether the rest of that screen is
/// any use to them. But onboarding runs once and never returns: a friend who
/// chose English at first launch, or who let it follow a machine set to
/// English, had no way back. A setting made once and never again is not a
/// setting, it is a question, and the answer to a question about language
/// changes -- someone hands the Mac to a colleague, or simply changes their
/// mind.
///
/// The two are the same preference, written through the same
/// `Preferences.languagePreference`, so whichever one is used the other agrees
/// immediately.
///
/// ## Why it is the first block
///
/// It changes every word below it. Somebody who opens Settings because the
/// application is in a language they do not read will look at the top, and
/// they will be looking for a word they cannot read -- which is why the two
/// options name themselves in themselves, `English` and `ไทย`, per
/// `AppLanguage.endonym`, rather than each being written in the language
/// currently on screen.
///
/// ## Applying it
///
/// Nothing here applies anything. `Preferences` is `@Observable` and every
/// view reads the language from the environment, which is injected at both
/// scene roots from `preferences.appLanguage`, so a change reaches the whole
/// interface on the next render. The one surface with no environment to read
/// -- notifications -- is fed by `LanguageController`, which observes this
/// same preference from the application rather than from a view.
struct LanguageSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsSection(title: Self.sectionTitle) {
            SettingsPicker(
                title: Self.interfaceLanguageTitle,
                options: LanguagePreference.allCases,
                optionTitle: \.title,
                explanation: Self.explanation,
                selection: $preferences.languagePreference
            )
        }
    }

    // MARK: Copy

    private static let sectionTitle = Phrase(en: "Language", th: "ภาษา")

    private static let interfaceLanguageTitle = Phrase(
        en: "Interface language",
        th: "ภาษาของอินเทอร์เฟซ"
    )

    /// Says that `System` follows the machine, because that is the default and
    /// a reader who leaves it alone deserves to know what they are leaving it
    /// on. Dates stay on the Gregorian calendar in both languages, which is
    /// worth stating here rather than leaving someone to wonder why a Thai
    /// interface does not print Buddhist years.
    private static let explanation = Phrase(
        en: "Changes every screen in the application. System follows the Mac's own language. "
            + "Dates stay on the Gregorian calendar either way.",
        th: "เปลี่ยนทุกหน้าจอในแอปพลิเคชัน เลือกตามระบบจะใช้ภาษาของ Mac เอง "
            + "และวันที่จะใช้ปฏิทินเกรกอเรียนทั้งสองภาษา"
    )
}
