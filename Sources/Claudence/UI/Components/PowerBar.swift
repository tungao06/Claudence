import SwiftUI
import ClaudenceCore

/// The popover's hero: one usage window, read before anything else on screen.
///
/// Sessions are machines, tokens are energy, and this is the battery. It is a
/// panel rather than a stack of text because the design gives it its own
/// ground, and that ground is the only thing separating the meter from the list
/// below without spending a rule on it. See design section 5.2 and spec 7.2.
///
/// Split out of `PowerBar` rather than added to it as a style flag. The two are
/// not one component at two sizes: this one owns a panel, a 40 pt number, a unit
/// set apart from it, a severity pill and a right-hand reset column, and the
/// secondary window below owns a single baseline row over an 8 pt track. A flag
/// would have meant a body where most of the view is inside one branch or the
/// other, and a call site that reads `PowerBar(style: .hero)` says less than one
/// that reads `PowerHero`.
///
/// What survives from the old shared implementation, because it is the rule and
/// not the styling: a nil percentage refuses to draw a fill. The design has no
/// unavailable variant, so an empty track is the only thing it could degrade
/// to, and an empty track reads as a measured zero.
///
/// ## What the fill is coloured by, and why it changed
///
/// It was the severity ramp. Read against `Design/Claudence-UI.dc.html` rather
/// than against the transcription, that is not what the design does: the three
/// windows carry three different gradients at the same 24% / 13% / 1% healthy
/// reading, coral for the 5-hour, lavender for the 7-day, mint for the
/// model-scoped one. The colour is answering "which limit is this", not "how
/// bad is it". Severity has not been dropped; it moved to where the design
/// keeps it, in the `✓ Healthy` pill, which states it as a glyph, a word and a
/// tint at once. That is also the arrangement that satisfies the project's own
/// rule, because nobody now has to tell coral from amber to learn anything.
struct PowerHero: View {
    /// Window name, e.g. "Claude Power" or `UsageWindow.displayName`.
    let title: Phrase
    /// The window's raw key, e.g. `five_hour`. Chooses the fill's identity and
    /// nothing else; an unrecognised key takes the third identity rather than
    /// failing, because a fill has to be some colour.
    let windowName: String
    /// Percent of the window consumed. Nil means the value is not known and the
    /// bar refuses to draw rather than inventing a fill.
    let percentUsed: Double?
    /// When the window rolls over, if the source reported it.
    let resetsAt: Date?
    /// Message shown in place of the reading when `percentUsed` is nil.
    let unavailableMessage: Phrase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveIndicators) private var liveIndicators
    @Environment(\.appLanguage) private var language

    /// For a caller that has not yet converted its own strings to `Phrase`.
    /// See `UnavailableView`'s own two-initialiser note for why this keeps the
    /// default and the `Phrase` overload does not: a single initialiser taking
    /// both a `String` and a `Phrase` default would make a zero-argument-style
    /// call ambiguous.
    init(
        title: String,
        windowName: String = "five_hour",
        percentUsed: Double?,
        resetsAt: Date? = nil,
        unavailableMessage: String = "Usage unavailable"
    ) {
        self.title = .untranslated(title)
        self.windowName = windowName
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.unavailableMessage = .untranslated(unavailableMessage)
    }

    init(
        title: Phrase,
        windowName: String = "five_hour",
        percentUsed: Double?,
        resetsAt: Date? = nil,
        unavailableMessage: Phrase = UnavailableView.usageUnavailable
    ) {
        self.title = title
        self.windowName = windowName
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.unavailableMessage = unavailableMessage
    }

    // Clamped so a source reporting 104% or -1% cannot break the layout.
    private var clampedPercent: Double? {
        percentUsed.map { min(100, max(0, $0)) }
    }

    private var severity: Severity? {
        clampedPercent.map { Constants.UsageThreshold.severity(forPercent: $0) }
    }

    private var identity: Theme.SessionIdentity {
        Theme.identity(forWindowNamed: windowName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Popover.heroGap) {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                VStack(alignment: .leading, spacing: Theme.Popover.heroLabelGap) {
                    PhraseText(title)
                        .font(Theme.Typography.labelEmphasis)
                        .tracking(Theme.heroLabelTracking)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    reading
                }
                Spacer(minLength: Theme.Space.s)
                resetColumn
            }
            if let percent = clampedPercent {
                fill(percent: percent)
            }
        }
        .padding(.horizontal, Theme.Popover.heroPaddingTop)
        .padding(.top, Theme.Popover.heroPaddingTop)
        .padding(.bottom, Theme.Popover.heroPaddingBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Theme.Hero.panelTop, Theme.Hero.panelBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(Theme.Hero.panelBorder)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel, in: language)
    }

    // MARK: - Reading

    @ViewBuilder
    private var reading: some View {
        if let percent = clampedPercent, let severity {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Popover.heroReadingGap) {
                // `Format.percent` is not usable here: the design sets the unit
                // at less than half the number's size and in a quieter ink, so
                // the two have to be separate views. The rounding is the same
                // rounding, deliberately, so the hero and every other reading of
                // this window agree to the digit.
                //
                // Neither of the two views below is a word: a bare digit
                // string and the `%` sign are identical in both languages, so
                // there is nothing here for `Phrase` to carry.
                let wholePercent = "\(Int(percent.rounded()))"
                Text(wholePercent)
                    .font(Theme.Typography.hero)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                let percentSign = "%"
                Text(percentSign)
                    .font(Theme.Typography.heroUnit)
                    .foregroundStyle(Theme.textQuaternary)
                // The only place severity is stated in the popover's meter, and
                // it is stated three ways at once. See the type's own note.
                StatusPill(severity: severity)
            }
        } else {
            UnavailableView(unavailableMessage, compact: true)
        }
    }

    @ViewBuilder
    private var resetColumn: some View {
        // Shown whenever the source reported a rollover, including when the
        // percentage did not resolve: the two facts arrive separately and one
        // being absent is no reason to withhold the other.
        if let time = Format.timeUntil(resetsAt) {
            VStack(alignment: .trailing, spacing: Theme.Popover.heroResetGap) {
                PhraseText(Strings.resetsIn)
                    .font(Theme.Typography.help)
                    .foregroundStyle(Theme.textQuaternary)
                Text(time)
                    .font(Theme.Typography.value)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                // The clock time under the countdown, because the two answer
                // different questions. "4h 35m" cannot be checked against a
                // calendar or remembered past the moment it is read; it is only
                // true at the instant it was rendered, and this view does not
                // tick. "23:40" stays true, and is the form anyone planning
                // around the limit actually needs.
                if let stamp = Format.resetStamp(resetsAt, in: language) {
                    Text(stamp)
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.textQuaternary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(resetLabel(time: time), in: language)
        }
    }

    private func resetLabel(time: String) -> Phrase {
        guard let stamp = Format.resetStamp(resetsAt, in: language) else {
            return Phrase(en: "Resets in \(time)", th: "รีเซ็ตใน \(time)")
        }
        return Phrase(
            en: "Resets in \(time), at \(stamp)",
            th: "รีเซ็ตใน \(time) เวลา \(stamp)"
        )
    }

    // MARK: - Bar

    private func fill(percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    // The hero's empty track is warmer than every other track
                    // in the design, which is what stops the panel's own warm
                    // ground from swallowing it.
                    .fill(Theme.heroTrack)
                Capsule(style: .continuous)
                    // Light stop to deep, both from this window's identity.
                    .fill(
                        LinearGradient(
                            colors: [identity.lightStop, identity.dot],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // A non-zero reading always shows at least a dot, so 0.4%
                    // is visibly different from 0%. Exactly zero draws nothing.
                    .frame(
                        width: percent <= 0
                            ? 0
                            : max(Theme.Bar.hero, geo.size.width * percent / 100)
                    )
            }
        }
        .frame(height: Theme.Bar.hero)
        // Quantised to whole percent. The raw value moves with every usage
        // refresh and the bar cannot show a difference smaller than this, so
        // animating the raw one only restarts a glide that never lands.
        .animation(
            Theme.valueAnimation(reduceMotion: reduceMotion, liveIndicators: liveIndicators),
            value: percent.rounded()
        )
    }

    private var spokenLabel: Phrase {
        guard let percent = clampedPercent, let severity else {
            return Phrase(
                en: "\(title.en). \(unavailableMessage.en).",
                th: "\(title.th) \(unavailableMessage.th)"
            )
        }
        let usedPercent = Format.percent(percent)
        let name = Theme.namePhrase(for: severity)
        var en = "\(title.en). \(usedPercent) used. \(name.en)."
        var th = "\(title.th) ใช้ไป \(usedPercent) \(name.th)"
        if let time = Format.timeUntil(resetsAt) {
            en += " Resets in \(time)."
            th += " รีเซ็ตใน \(time)"
        }
        return Phrase(en: en, th: th)
    }
}

/// A secondary usage window: the 7-day cap, and any model-scoped weekly cap.
///
/// One baseline row of name, reading and rollover hint over a thin track. It is
/// deliberately quiet. These windows matter, but a second and third element with
/// the hero's weight would leave the popover with no hero at all, and the whole
/// point of the ordering in `CLAUDE.md` is that one reading comes first.
///
/// See design section 5.3. The default height is the row bar, not the hero bar:
/// this type is the small one now, and a caller wanting a thicker track says so.
///
/// ## The severity glyph that used to be here
///
/// This row used to draw `Theme.glyph(for: severity)` in the severity's colour
/// immediately before the percentage, so a healthy 7-day window rendered as a
/// green check followed by `13%`. The design has no such badge anywhere in
/// these rows, and neither does the transcription: both set the row as name,
/// percentage, rollover hint, over a track. It was invented, and it is gone.
///
/// Nothing is lost by removing it, which is the test that mattered before it
/// went. The severity of the *primary* window is stated in full by the hero
/// directly above. A secondary row's own reading is its percentage and its fill
/// length, both of which are legible with no colour at all, and the spoken
/// label still names the severity for anyone who is not looking at the row.
struct PowerBar: View {
    /// Window name, e.g. `UsageWindow.displayName`.
    let title: Phrase
    /// A muted caption beside the name. The design writes `weekly scoped` next
    /// to a model-scoped window and nothing next to the 7-day one.
    let caption: Phrase?
    /// The window's raw key, e.g. `seven_day`. Chooses the fill's identity.
    let windowName: String
    /// Percent of the window consumed. Nil means the value is not known and the
    /// bar refuses to draw rather than inventing a fill.
    let percentUsed: Double?
    /// When the window rolls over, if the source reported it.
    let resetsAt: Date?
    /// Track thickness.
    let height: CGFloat
    /// Message shown in place of the bar when `percentUsed` is nil.
    let unavailableMessage: Phrase

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveIndicators) private var liveIndicators
    @Environment(\.appLanguage) private var language

    /// For a caller that has not yet converted its own strings to `Phrase`.
    /// See `PowerHero`'s own note for why this keeps the default and the
    /// `Phrase` overload does not.
    init(
        title: String,
        caption: String? = nil,
        windowName: String = "seven_day",
        percentUsed: Double?,
        resetsAt: Date? = nil,
        height: CGFloat = Theme.Bar.row,
        unavailableMessage: String = "Usage unavailable"
    ) {
        self.title = .untranslated(title)
        self.caption = caption.map(Phrase.untranslated)
        self.windowName = windowName
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.height = height
        self.unavailableMessage = .untranslated(unavailableMessage)
    }

    init(
        title: Phrase,
        caption: Phrase? = nil,
        windowName: String = "seven_day",
        percentUsed: Double?,
        resetsAt: Date? = nil,
        height: CGFloat = Theme.Bar.row,
        unavailableMessage: Phrase = UnavailableView.usageUnavailable
    ) {
        self.title = title
        self.caption = caption
        self.windowName = windowName
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.height = height
        self.unavailableMessage = unavailableMessage
    }

    // Clamped so a source reporting 104% or -1% cannot break the layout.
    private var clampedPercent: Double? {
        percentUsed.map { min(100, max(0, $0)) }
    }

    private var severity: Severity? {
        clampedPercent.map { Constants.UsageThreshold.severity(forPercent: $0) }
    }

    private var identity: Theme.SessionIdentity {
        Theme.identity(forWindowNamed: windowName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Popover.secondaryInnerGap) {
            header
            if let percent = clampedPercent {
                fill(percent: percent)
            } else {
                UnavailableView(unavailableMessage, compact: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel, in: language)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Popover.secondaryCaptionGap) {
            PhraseText(title)
                .font(Theme.Typography.rowLabel)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let caption {
                PhraseText(caption)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.xs)
            Text(Format.percent(clampedPercent))
                .font(Theme.Typography.value)
                .foregroundStyle(clampedPercent == nil ? Theme.textTertiary : Theme.textPrimary)
            // The rollover moves onto the baseline row rather than sitting under
            // the bar as a caption: at this weight a second line would give the
            // secondary window more vertical space than the hero's own bar.
            if let time = Format.timeUntil(resetsAt) {
                Text(time)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
                    .padding(.leading, Theme.Popover.secondaryValueGap - Theme.Popover.secondaryCaptionGap)
            }
        }
    }

    private func fill(percent: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.track)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [identity.lightStop, identity.dot],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // A non-zero reading always shows at least a dot, so 0.4%
                    // is visibly different from 0%. Exactly zero draws nothing.
                    .frame(width: percent <= 0 ? 0 : max(height, geo.size.width * percent / 100))
            }
        }
        .frame(height: height)
        // Quantised to whole percent, for the reason given in `PowerHero.fill`.
        .animation(
            Theme.valueAnimation(reduceMotion: reduceMotion, liveIndicators: liveIndicators),
            value: percent.rounded()
        )
    }

    private var spokenLabel: Phrase {
        let en = caption.map { "\(title.en), \($0.en)" } ?? title.en
        let th = caption.map { "\(title.th) \($0.th)" } ?? title.th
        guard let percent = clampedPercent, let severity else {
            return Phrase(en: "\(en). \(unavailableMessage.en).", th: "\(th) \(unavailableMessage.th)")
        }
        let usedPercent = Format.percent(percent)
        let name = Theme.namePhrase(for: severity)
        var enLine = "\(en). \(usedPercent) used. \(name.en)."
        var thLine = "\(th) ใช้ไป \(usedPercent) \(name.th)"
        if let time = Format.timeUntil(resetsAt) {
            enLine += " Resets in \(time)."
            thLine += " รีเซ็ตใน \(time)"
        }
        return Phrase(en: enLine, th: thLine)
    }
}

/// Words shared between `PowerHero` and `PowerBar`.
private enum Strings {
    static let resetsIn = Phrase(en: "Resets in", th: "รีเซ็ตใน")
}
