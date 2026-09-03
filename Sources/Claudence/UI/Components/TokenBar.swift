import SwiftUI
import ClaudenceCore

/// Token energy for one session or one roll-up.
///
/// The bar always measures `usage.total`; the breakdown always shows cache
/// separately from fresh input, because cache reads cost roughly an order of
/// magnitude less and collapsing them makes the display disagree with the bill.
/// Nothing here recomputes a total: `TokenUsage` owns the formula.
/// See spec section 5.
struct TokenBar: View {
    /// Nil means no transcript has been read for this session yet.
    let usage: TokenUsage?
    /// The value that corresponds to a full bar. Nil means we have no scale, so
    /// no bar is drawn: a fill without a denominator would be a made-up ratio.
    let scaleMaximum: Int?
    /// Severity of the fill. Token volume alone is not an alarm, so the default
    /// is the neutral healthy token; a caller holding a context percentage can
    /// pass a real severity.
    let severity: Severity
    let height: CGFloat
    let isExpandable: Bool
    /// When a container owns the disclosure state (a session row, say), it
    /// passes a binding and supplies its own control. Otherwise the bar keeps
    /// its own local UI state and draws its own chevron.
    let expansion: Binding<Bool>?
    let unavailableMessage: Phrase

    @State private var localExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveIndicators) private var liveIndicators
    @Environment(\.appLanguage) private var language

    /// The canonical "Token usage unavailable" phrase, for a converted caller
    /// that wants this view's own default rather than writing its own copy of
    /// it. Mirrors `UnavailableView.usageUnavailable`.
    static let tokenUsageUnavailable = Phrase(
        en: "Token usage unavailable",
        th: "ไม่มีข้อมูลการใช้งาน token"
    )

    /// One initialiser. There was a `String` one beside this while the three
    /// areas of the interface converted in parallel, and it defaulted to the
    /// English sentence, so a caller that simply omitted the argument drew
    /// English on a Thai screen. Every caller is converted, so the default is
    /// the phrase itself and there is no route that produces one language.
    init(
        usage: TokenUsage?,
        scaleMaximum: Int? = nil,
        severity: Severity = .healthy,
        height: CGFloat = Theme.Bar.row,
        isExpandable: Bool = true,
        startsExpanded: Bool = false,
        expansion: Binding<Bool>? = nil,
        unavailableMessage: Phrase = TokenBar.tokenUsageUnavailable
    ) {
        self.usage = usage
        self.scaleMaximum = scaleMaximum
        self.severity = severity
        self.height = height
        self.isExpandable = isExpandable
        self.expansion = expansion
        self.unavailableMessage = unavailableMessage
        _localExpanded = State(initialValue: startsExpanded)
    }

    private var isShowingBreakdown: Bool {
        guard isExpandable else { return false }
        return expansion?.wrappedValue ?? localExpanded
    }

    private var showsDisclosureControl: Bool { isExpandable && expansion == nil }

    private var fraction: Double? {
        guard let usage, let scaleMaximum, scaleMaximum > 0 else { return nil }
        return min(1, max(0, Double(usage.total) / Double(scaleMaximum)))
    }

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                summary(usage)
                if let fraction {
                    bar(fraction: fraction)
                }
                if isShowingBreakdown {
                    breakdown(usage)
                        .transition(.opacity)
                }
            }
            .animation(
                Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
                value: isShowingBreakdown
            )
        } else {
            UnavailableView(unavailableMessage, compact: true)
        }
    }

    // MARK: - Summary line

    private func summary(_ usage: TokenUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            PhraseText(Strings.tokenEnergy)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.xs)
            Text(Format.tokens(usage.total))
                .font(Theme.Typography.value)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if showsDisclosureControl {
                Button {
                    localExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(localExpanded ? Theme.Motion.disclosureRotation : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    localExpanded ? Strings.hideBreakdown : Strings.showBreakdown,
                    in: language
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryLabel(usage), in: language)
    }

    private func summaryLabel(_ usage: TokenUsage) -> Phrase {
        let total = Format.tokens(usage.total)
        guard let fraction else {
            return Phrase(
                en: "Token energy, \(total) total",
                th: "พลังงาน token รวม \(total)"
            )
        }
        let share = Format.percent(fraction * 100)
        return Phrase(
            en: "Token energy, \(total) total, \(share) of scale",
            th: "พลังงาน token รวม \(total), \(share) ของสเกล"
        )
    }

    // MARK: - Bar

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Theme.track)
                Capsule(style: .continuous)
                    .fill(Theme.color(for: severity))
                    .frame(width: fraction <= 0 ? 0 : max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        // Animated on a quantised fraction, not the raw one.
        //
        // The raw fraction moves on every transcript event, which arrives about
        // four times a second while a session is streaming. A 0.35 s animation
        // restarted every 0.25 s never finishes, so it interpolates
        // continuously, and this bar lives inside a popover that stays mounted
        // after dismissal. Quantising to whole percent means a redraw only
        // happens when the bar would visibly move, which is the only time an
        // animation was ever worth running.
        .animation(
            Theme.valueAnimation(reduceMotion: reduceMotion, liveIndicators: liveIndicators),
            value: (fraction * 100).rounded()
        )
        .accessibilityHidden(true)
    }

    // MARK: - Breakdown

    private func breakdown(_ usage: TokenUsage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            row(Theme.TokenCategory.freshInput.labelPhrase, usage.freshInput)
            row(Theme.TokenCategory.cacheWrite.labelPhrase, usage.cacheCreation)
            row(Theme.TokenCategory.cacheRead.labelPhrase, usage.cacheRead)
            row(Theme.TokenCategory.output.labelPhrase, usage.output)
            Divider().overlay(Theme.separator)
            row(Strings.total, usage.total, emphasised: true)
        }
        .padding(.top, Theme.Space.xxs)
    }

    private func row(_ name: Phrase, _ value: Int, emphasised: Bool = false) -> some View {
        HStack(spacing: Theme.Space.xs) {
            PhraseText(name)
                .font(Theme.Typography.body)
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.m)
            Text(Format.tokens(value))
                .font(Theme.Typography.numeric)
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Phrase(
                en: "\(name.en), \(Format.tokens(value)) tokens",
                th: "\(name.th), \(Format.tokens(value)) token"
            ),
            in: language
        )
    }
}

/// Words this file owns.
private enum Strings {
    static let tokenEnergy = Phrase(en: "Token energy", th: "พลังงาน token")
    static let hideBreakdown = Phrase(en: "Hide token breakdown", th: "ซ่อนรายละเอียด token")
    static let showBreakdown = Phrase(en: "Show token breakdown", th: "แสดงรายละเอียด token")
    static let total = Phrase(en: "Total", th: "รวม")
}
