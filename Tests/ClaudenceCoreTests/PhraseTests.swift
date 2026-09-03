import Foundation
import Testing

@testable import ClaudenceCore

/// The product ships in Thai and English, complete, before anyone outside this
/// machine runs it. `Phrase` is what makes an untranslated string fail to
/// compile; these tests cover the two things a type cannot enforce on its own,
/// which are the calendar and the word order.
@Suite("Phrase")
struct PhraseTests {

    @Test("a phrase answers in the language it is asked in")
    func answersInTheRequestedLanguage() {
        let phrase = Phrase(en: "Active sessions", th: "เซสชันที่ทำงานอยู่")
        #expect(phrase.string(in: .english) == "Active sessions")
        #expect(phrase.string(in: .thai) == "เซสชันที่ทำงานอยู่")
        #expect(phrase(.thai) == "เซสชันที่ทำงานอยู่")
    }

    /// The trap this project measured before: `th_TH` supplies the Buddhist
    /// calendar, so a date formatted through it reads 2569 where the commit it
    /// describes reads 2026. Forced twice, in the locale and in the calendar,
    /// because a formatter built from a locale and a formatter given a calendar
    /// are two different ways into the same wrong year.
    @Test("Thai formatting stays on the Gregorian calendar")
    func thaiKeepsTheGregorianYear() {
        let moment = Date(timeIntervalSince1970: 1_788_000_000)

        let formatter = DateFormatter()
        formatter.locale = AppLanguage.thai.locale
        formatter.calendar = AppLanguage.thai.calendar
        formatter.dateFormat = "yyyy"
        #expect(formatter.string(from: moment) == "2026")

        // And through the locale alone, which is the path a caller takes when
        // it forgets to set the calendar.
        let localeOnly = DateFormatter()
        localeOnly.locale = AppLanguage.thai.locale
        localeOnly.dateFormat = "yyyy"
        #expect(localeOnly.string(from: moment) == "2026")

        #expect(AppLanguage.thai.calendar.identifier == .gregorian)
    }

    /// Thai does not always put a number where English does, so substitution
    /// runs against each language's own template rather than against one
    /// sentence assembled in English and then translated in pieces.
    @Test("placeholders are filled per language, in that language's order")
    func placeholdersFollowEachLanguage() {
        let phrase = Phrase(
            en: "%@ of %@ sessions are working",
            th: "มี %@ จาก %@ เซสชันที่กำลังทำงาน"
        )
        #expect(phrase.format(in: .english, "1", "2") == "1 of 2 sessions are working")
        #expect(phrase.format(in: .thai, "1", "2") == "มี 1 จาก 2 เซสชันที่กำลังทำงาน")
    }

    @Test("a missing argument leaves the placeholder rather than dropping the sentence")
    func missingArgumentsAreSurvivable() {
        let phrase = Phrase(en: "%@ of %@", th: "%@ จาก %@")
        #expect(phrase.format(in: .english, "1") == "1 of %@")
    }

    @Test("the system's language is matched, and anything else reads as English")
    func systemLanguageMatching() {
        #expect(AppLanguage.matchingSystem(preferred: ["th-TH", "en-US"]) == .thai)
        #expect(AppLanguage.matchingSystem(preferred: ["en-GB"]) == .english)
        #expect(AppLanguage.matchingSystem(preferred: ["ja-JP", "th"]) == .thai)
        #expect(AppLanguage.matchingSystem(preferred: ["ja-JP"]) == .english)
        #expect(AppLanguage.matchingSystem(preferred: []) == .english)
    }

    /// A language picker in English is no use to someone looking for Thai.
    @Test("each language names itself in itself")
    func endonyms() {
        #expect(AppLanguage.english.endonym == "English")
        #expect(AppLanguage.thai.endonym == "ไทย")
    }

    @Test("a string that is genuinely the same in both says so deliberately")
    func untranslatedIsExplicit() {
        let unit = Phrase.untranslated("MB")
        #expect(unit.string(in: .english) == unit.string(in: .thai))
    }
}
