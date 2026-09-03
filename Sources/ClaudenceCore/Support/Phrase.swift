import Foundation

/// The two languages this product ships in.
///
/// An enumeration rather than a locale identifier, because the set is closed
/// and small: every user-facing string exists in both, and adding a third is a
/// decision with a translation budget attached, not a configuration value.
public enum AppLanguage: String, Sendable, CaseIterable, Codable {
    case english = "en"
    case thai = "th"

    /// What the system's preferred languages ask for, English when they ask for
    /// anything else. Called once at launch and whenever the preference is set
    /// to follow the system.
    public static func matchingSystem(
        preferred: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for identifier in preferred {
            let code = identifier.lowercased()
            if code.hasPrefix("th") { return .thai }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// The name of the language in the language itself, which is how a language
    /// picker should read: a Thai speaker looking for Thai should not have to
    /// find the word "Thai".
    public var endonym: String {
        switch self {
        case .english: return "English"
        case .thai: return "ไทย"
        }
    }

    /// The locale to format numbers and dates with.
    ///
    /// Thai formatting with the Buddhist calendar attached is the trap recorded
    /// in PLAN.md: `th_TH` supplies it, so a date that should read 2026 reads
    /// 2569. The identifier here pins the Gregorian calendar explicitly, and
    /// `calendar` below is the second place it is forced, because a formatter
    /// built from a locale and a formatter given a calendar are two different
    /// paths into the same mistake.
    public var locale: Locale {
        switch self {
        case .english: return Locale(identifier: "en_US_POSIX")
        case .thai: return Locale(identifier: "th_TH@calendar=gregorian")
        }
    }

    /// The Gregorian calendar, in this language's own time zone-free terms.
    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return calendar
    }
}

/// One user-facing string, in both languages at once.
///
/// The type exists so that an untranslated string cannot compile. A `String`
/// literal in a view is a sentence in exactly one language and nothing catches
/// it; a `Phrase` has to be given both, at the point where whoever writes the
/// English is also thinking about the Thai. `PhraseLintTests` is the second
/// half of that: it fails on a raw literal reaching a user-facing surface.
///
/// Interpolation is deliberately not a `String` initialiser. A phrase with a
/// number in it needs the number formatted in the reader's own locale, and a
/// caller that builds `"\(count) sessions"` has already lost that. Use
/// `format(_:)` with the pieces, which each language orders for itself.
public struct Phrase: Sendable, Equatable, Hashable {
    public let en: String
    public let th: String

    public init(en: String, th: String) {
        self.en = en
        self.th = th
    }

    public func callAsFunction(_ language: AppLanguage) -> String {
        string(in: language)
    }

    public func string(in language: AppLanguage) -> String {
        switch language {
        case .english: return en
        case .thai: return th
        }
    }

    /// Substitutes `%@` placeholders, in the order each language wants them.
    ///
    /// Thai and English do not always agree about where a number goes, so the
    /// substitution happens per language against that language's own template
    /// rather than against one assembled sentence.
    public func format(in language: AppLanguage, _ arguments: [String]) -> String {
        var result = string(in: language)
        for argument in arguments {
            guard let range = result.range(of: "%@") else { break }
            result.replaceSubrange(range, with: argument)
        }
        return result
    }

    public func format(in language: AppLanguage, _ arguments: String...) -> String {
        format(in: language, arguments)
    }
}

/// A phrase that is the same in both languages, stated once.
///
/// For the handful of strings that are genuinely identical: a model name, a
/// unit like `MB`, a brand. Written as its own initialiser so the reader can
/// see it was a decision rather than a translation someone forgot.
extension Phrase {
    public static func untranslated(_ text: String) -> Phrase {
        Phrase(en: text, th: text)
    }
}
