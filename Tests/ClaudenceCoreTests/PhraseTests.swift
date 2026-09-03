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

    /// Thai has no letter case, so capitalising it is a no-op that would read
    /// in the source as if it did something.
    @Test("capitalising touches the English half only")
    func capitalisationIsEnglishOnly() {
        let phrase = Phrase(en: "critical", th: "วิกฤต").capitalizedInEnglish
        #expect(phrase.en == "Critical")
        #expect(phrase.th == "วิกฤต")
    }

    // MARK: - The words Format glues around its own numbers

    /// `Format` produces digits, a currency symbol and three English words.
    /// The digits are the same in both languages and the words were not.
    @Test("the reset stamp names the day in the reader's language")
    func resetStampSpeaksBothLanguages() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        let englishTomorrow = Format.resetStamp(tomorrow, now: now, in: .english, calendar: calendar)
        let thaiTomorrow = Format.resetStamp(tomorrow, now: now, in: .thai, calendar: calendar)
        #expect(englishTomorrow?.hasPrefix("Tomorrow") == true)
        #expect(thaiTomorrow?.hasPrefix("พรุ่งนี้") == true)

        let englishYesterday = Format.resetStamp(yesterday, now: now, in: .english, calendar: calendar)
        let thaiYesterday = Format.resetStamp(yesterday, now: now, in: .thai, calendar: calendar)
        #expect(englishYesterday?.hasPrefix("Yesterday") == true)
        #expect(thaiYesterday?.hasPrefix("เมื่อวาน") == true)

        // Same day is the clock alone in both, with no day word to translate.
        #expect(Format.resetStamp(now, now: now, in: .thai, calendar: calendar)
            == Format.resetStamp(now, now: now, in: .english, calendar: calendar))
    }

    /// A date far enough out to be named rather than called tomorrow. The
    /// month is a Thai word and the year is still 2026, not the Buddhist 2569.
    @Test("a named day is a Thai month on a Gregorian year")
    func namedDayIsThaiAndGregorian() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Bangkok") ?? .current
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: now)!

        let thai = try #require(Format.resetStamp(nextWeek, now: now, in: .thai, calendar: calendar))
        let english = try #require(
            Format.resetStamp(nextWeek, now: now, in: .english, calendar: calendar)
        )
        #expect(thai != english)
        #expect(!thai.contains("2569"))

        // The year the day formatter is built on, checked directly rather than
        // inferred from a stamp that does not print one.
        let yearFormatter = DateFormatter()
        yearFormatter.locale = AppLanguage.thai.locale
        yearFormatter.calendar = AppLanguage.thai.calendar
        yearFormatter.dateFormat = "yyyy"
        #expect(yearFormatter.string(from: nextWeek) == "2026")
    }

    @Test("an absent cost says so in the reader's language, and a present one does not change")
    func costSpeaksBothLanguages() {
        #expect(Format.cost(nil, in: .english) == "unavailable")
        #expect(Format.cost(nil, in: .thai) == "ไม่มีข้อมูล")
        // The figure is an API-equivalent amount in US dollars. The currency
        // does not change because the reader does.
        #expect(Format.cost(4.5, in: .thai) == "$4.50")
        #expect(Format.cost(4.5, in: .english) == Format.cost(4.5, in: .thai))
    }
}
