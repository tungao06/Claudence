import SwiftUI
import ClaudenceCore

/// A state said in three ways at once: a glyph, a word, and a tint.
///
/// The design draws two of these, the hero's `✓ Healthy` and the session row's
/// `● Working`, and they look like the same object because they are. Sharing
/// one type is what keeps them that way, and it puts the "never colour alone"
/// rule in a single place: this view cannot be constructed without a word, so
/// there is no call site that can quietly reduce a state to a swatch.
///
/// Colour comes from `Theme` and from nowhere else. The two convenience
/// initialisers below are the only two mappings the product needs, and each
/// takes its colour from the resolver that already owns that mapping rather
/// than choosing one here.
struct StatusPill: View {
    /// The glyph, as a text character.
    ///
    /// This used to be an SF Symbol name, on the argument that the symbol set
    /// was the closer match on this platform. Read against the design file
    /// rather than against the transcription, that was wrong: every icon in
    /// `Design/Claudence-UI.dc.html` is a character in the text run, and the
    /// two pills the design draws are literally the strings `\u{25CF} Working`
    /// and `\u{2713} Healthy`. Substituting a symbol changed the string a
    /// reader sees and changed its size and baseline with it. The symbol table
    /// in `Theme.glyph(for:)` is still there and still used where a symbol is
    /// the better shape; a pill takes `Theme.mark(for:)` instead.
    let glyph: String
    /// The state as a word. Never optional: the word is the point.
    let text: String
    /// Glyph and text colour.
    let ink: Color
    /// Pill background.
    let tint: Color
    let font: Font

    init(
        glyph: String,
        text: String,
        ink: Color,
        tint: Color,
        font: Font = Theme.Typography.label
    ) {
        self.glyph = glyph
        self.text = text
        self.ink = ink
        self.tint = tint
        self.font = font
    }

    /// The hero's severity badge.
    ///
    /// The word is capitalised because the design sets it as a label rather
    /// than as prose; `Theme.name(for:)` stays lowercase because every other
    /// caller of it is building a spoken sentence.
    init(severity: Severity) {
        self.init(
            glyph: Theme.mark(for: severity),
            text: Theme.name(for: severity).capitalized,
            // The design paints this pill's ink `0x7E9E86`, which is not the
            // `0x4E8A6B` of its dashboard banner. `Theme.healthyInk` is that
            // first value; the other three severities have no pill in the
            // design at all, so they take the severity ramp.
            ink: severity == .healthy ? Theme.healthyInk : Theme.color(for: severity),
            tint: Theme.tint(for: severity),
            font: Theme.Typography.labelEmphasis
        )
    }

    /// A session row's status.
    ///
    /// The tint is the session's identity, exactly as the design has it, and
    /// the glyph and the word are the state. That split is deliberate: the
    /// pill's colour answers "whose row is this", which is the same question
    /// the dot beside it answers, and never "how is it going", which is what
    /// the glyph shape and the word answer. So an identity colour is still
    /// carrying identity alone, and a reader who cannot see the tint at all
    /// loses nothing about the state.
    init(status: SessionStatus, identity: Theme.SessionIdentity) {
        self.init(
            glyph: Theme.mark(for: status),
            text: Theme.name(for: status),
            ink: identity.ink,
            tint: identity.tint
        )
    }

    var body: some View {
        // One text run, as the design has it: the glyph is set at the pill's
        // own size and sits on its baseline rather than being a separately
        // sized image beside it.
        HStack(spacing: Theme.Space.xs) {
            Text(glyph)
            Text(text)
                .lineLimit(1)
        }
        .font(font)
        .foregroundStyle(ink)
        .padding(.horizontal, Theme.Popover.pillPaddingHorizontal)
        .padding(.vertical, Theme.Popover.pillPaddingVertical)
        .background(tint, in: Capsule(style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
