import SwiftUI
import ClaudenceCore

/// The language every user-facing string is drawn in, carried down the view
/// tree beside `liveIndicators` and `liveOnlyMode`.
///
/// One delivery mechanism, for the reason 9.8 recorded: a setting that reaches
/// one surface and not another is worse than one that reaches none, because the
/// half that works hides the half that does not. Every scene injects it from
/// `Preferences.appLanguage`, and every view that draws words reads it from
/// here rather than from `Preferences`, so a preview or a render shot can ask
/// for Thai without a preferences object existing at all.
private struct AppLanguageKey: EnvironmentKey {
    /// English, because a view outside the app's scenes, a preview or an
    /// offscreen render, has no user to ask.
    static let defaultValue = AppLanguage.english
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

/// A `Text` built from a `Phrase`, in whatever language the environment says.
///
/// Written as a view rather than as a `Text` initialiser because `Text` cannot
/// read the environment: the value has to be resolved during `body`, and a
/// helper that took the language as an argument would put the same lookup at
/// every call site and let one of them forget.
struct PhraseText: View {
    private let phrase: Phrase
    private let arguments: [String]
    @Environment(\.appLanguage) private var language

    init(_ phrase: Phrase, _ arguments: String...) {
        self.phrase = phrase
        self.arguments = arguments
    }

    init(_ phrase: Phrase, arguments: [String]) {
        self.phrase = phrase
        self.arguments = arguments
    }

    var body: Text {
        Text(arguments.isEmpty ? phrase.string(in: language) : phrase.format(in: language, arguments))
    }
}

extension View {
    /// The spoken label, from a phrase. VoiceOver reads the same language the
    /// screen is in, which is the whole point of carrying the language rather
    /// than translating at the point of display.
    func accessibilityLabel(_ phrase: Phrase, in language: AppLanguage) -> some View {
        accessibilityLabel(Text(phrase.string(in: language)))
    }
}

extension Phrase {
    /// Resolved against an environment value the caller already has.
    ///
    /// For the places a `String` is genuinely needed rather than a view: an
    /// accessibility label, a tooltip body, a window title, a save panel's
    /// default name.
    func callAsFunction(in language: AppLanguage, _ arguments: String...) -> String {
        arguments.isEmpty ? string(in: language) : format(in: language, arguments)
    }
}
