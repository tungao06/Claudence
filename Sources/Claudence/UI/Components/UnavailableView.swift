import SwiftUI
import ClaudenceCore

/// The honest empty state.
///
/// Rendered wherever a value is nil. It never substitutes a zero, a dash in a
/// bar, or a placeholder fill, because a fabricated number is worse than an
/// absent one. See spec section 9.4.
///
/// Two initialisers, deliberately not merged into one with a `Phrase`
/// parameter and a default: `UnavailableView()` is called from several files
/// outside `Components/` that have not yet converted their own strings, and a
/// single initialiser with all-default parameters on both a `String` and a
/// `Phrase` overload would make that call ambiguous. The `String` overload
/// keeps its default and wraps the literal as `Phrase.untranslated`, which is
/// not a translation -- it is a marker that the call site has not migrated,
/// and the text stays English even when the screen is Thai until it does. The
/// `Phrase` overload has no default message, so it never competes with the
/// zero-argument call.
struct UnavailableView: View {
    /// What is missing, in plain words.
    private let message: Phrase
    /// Optional second line explaining why, when a reason is actually known.
    private let reason: Phrase?
    /// Compact form fits inside a session row; regular form stands alone.
    private let isCompact: Bool

    @Environment(\.appLanguage) private var language

    /// For a caller in another area that has not yet converted its own
    /// strings to `Phrase`. See the type's doc comment for why this keeps the
    /// default and the `Phrase` overload does not.
    init(_ message: String = "Usage unavailable", reason: String? = nil, compact: Bool = false) {
        self.message = .untranslated(message)
        self.reason = reason.map(Phrase.untranslated)
        self.isCompact = compact
    }

    init(_ message: Phrase, reason: Phrase? = nil, compact: Bool = false) {
        self.message = message
        self.reason = reason
        self.isCompact = compact
    }

    /// The canonical "Usage unavailable" phrase, for a converted caller that
    /// wants this view's own default rather than writing its own copy of it.
    static let usageUnavailable = Phrase(en: "Usage unavailable", th: "ไม่มีข้อมูลการใช้งาน")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: "minus.circle")
                .font(.system(size: isCompact ? Theme.Bar.statusGlyph : Theme.Bar.severityGlyph))
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                PhraseText(message)
                    .font(isCompact ? Theme.Typography.caption : Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                if let reason, !reason.string(in: language).isEmpty {
                    PhraseText(reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .lineLimit(isCompact ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel, in: language)
    }

    private var spokenLabel: Phrase {
        guard let reason, !reason.en.isEmpty else { return message }
        return Phrase(en: "\(message.en). \(reason.en)", th: "\(message.th) \(reason.th)")
    }
}
