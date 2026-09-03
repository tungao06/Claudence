import SwiftUI
import ClaudenceCore

/// The power meter, drawn as vertical tubes.
///
/// The dashboard's hero and the first thing on the window, because the product
/// is a power meter rather than an analytics dashboard. One tube per usage
/// window, side by side, so the reading is a comparison and not three separate
/// numbers a reader has to hold in their head.
///
/// Vertical rather than horizontal on purpose: a tube filling from the floor is
/// the shape of a tank, and the eye reads three tanks against each other in one
/// glance where three stacked bars have to be read in sequence.
///
/// Two rules the tube geometry exists to serve:
///
/// 1. **A non-zero reading is never rounded away.** One percent of 186 pt is
///    under two points and disappears against the track's own rounding, so the
///    fill is floored at `Theme.Bar.minimumVisibleFill`. A bar that showed
///    nothing for a real reading would be claiming there is no usage. Zero
///    stays zero: the floor lifts a measurement, it never invents one.
/// 2. **The fill is coloured by which window it is, and severity is carried in
///    words.** The design gives each tube its own hue — coral for the five
///    hour, lavender for the seven day, mint for the model-scoped cap — so the
///    three tubes stay tellable apart at a glance and a tube does not change
///    identity as its reading rises. The reading's severity is not lost: the
///    glyph beside each percentage is `Theme.glyph(for:)` in
///    `Theme.color(for:)`, and the summary pill underneath names the worst
///    window in a word. Colour therefore never carries a state on its own here,
///    and the one place a state resolves to a colour is still
///    `Theme.color(for: Severity)`.
///
/// Nothing animates except a fill arriving at a new whole percent. The design's
/// vertical glint sweep is one of the nine repeating animations `CLAUDE.md`
/// forbids, and the tubes are mounted for the life of the window.
struct PowerMeterView: View {
    let data: DashboardData
    /// Reference time for the reset countdowns. Injected so the card stays a
    /// function of its inputs.
    let now: Date
    /// The window the shell header's picker has selected, outlined here. Nil
    /// outlines nothing, which is what a card rendered without a picker wants.
    let highlightedWindowName: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveIndicators) private var liveIndicators
    @Environment(\.appLanguage) private var language

    init(data: DashboardData, now: Date, highlightedWindowName: String? = nil) {
        self.data = data
        self.now = now
        self.highlightedWindowName = highlightedWindowName
    }

    var body: some View {
        DashboardCard(
            title: Strings.title,
            subtitle: Strings.subtitle,
            headerLayout: .inline,
            tooltipKey: "power"
        ) {
            if let reason = data.usageUnavailableReason {
                // Never a meter at some default fill. See spec section 9.4.
                // `reason` arrives translated: `UsageState.unavailable` carries
                // a `Phrase`, so a Keychain refusal or a rate limit reads in
                // the same language as the sentence above it.
                UnavailableView(UnavailableView.usageUnavailable, reason: reason)
            } else if data.windows.isEmpty {
                UnavailableView(UnavailableView.usageUnavailable, reason: Strings.noWindowReported)
            } else {
                tubes
                banner
                burnLeaderLine
            }
        }
    }

    /// Names the session responsible for the largest share of the current
    /// burn (9.11), when there is one. `BurnAttribution.leader` returns nil
    /// while nothing is burning, which is an ordinary state, not a missing
    /// measurement, so the line simply does not draw rather than saying
    /// "unavailable" about a rate of zero.
    ///
    /// Glyph and words, no colour: this line identifies *who*, not *how bad*,
    /// so it borrows none of the severity tokens the tubes and the banner
    /// above already spend colour on.
    @ViewBuilder
    private var burnLeaderLine: some View {
        if let leader = data.burnLeader {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Text(
                    Strings.burnLeaderLine.format(
                        in: language,
                        leader.displayName,
                        Format.share(leader.share)
                    )
                )
                .font(Theme.Typography.help)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Strings.burnLeaderSpoken.format(
                    in: language,
                    leader.displayName,
                    Format.share(leader.share)
                )
            )
        }
    }

    // MARK: - Tubes

    /// Space-around, so two windows and five windows both centre themselves.
    /// The tube keeps its designed width inside a flexible column rather than
    /// stretching, because a tube that changes width with the payload stops
    /// being comparable to the one beside it.
    private var tubes: some View {
        HStack(alignment: .top, spacing: DashboardMetrics.tubeColumnGap) {
            ForEach(data.meterWindows) { window in
                tube(window)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func tube(_ window: UsageWindow) -> some View {
        let percent = window.usedPercent.map { min(100, max(0, $0)) }
        let severity = percent.map(Constants.UsageThreshold.severity(forPercent:))
        return VStack(spacing: DashboardMetrics.tubeStackGap) {
            reading(percent: percent, severity: severity)
            column(
                percent: percent,
                fill: Self.fill(for: window),
                isHighlighted: window.name == highlightedWindowName
            )
            caption(window)
        }
        .frame(maxWidth: .infinity)
        .tooltip(TooltipText.tip(Self.tooltipKey(for: window)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenTube(window, percent: percent, severity: severity))
    }

    /// The percentage, with the severity glyph beside it. The glyph is what
    /// carries the reading for anyone the colour does not reach.
    private func reading(percent: Double?, severity: Severity?) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: severity.map(Theme.glyph(for:)) ?? "minus.circle")
                .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                .foregroundStyle(severity.map(Theme.color(for:)) ?? Theme.textTertiary)
            Text(Format.percent(percent))
                .font(Theme.Typography.tubeValue)
                .foregroundStyle(percent == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
        }
    }

    private func column(percent: Double?, fill: Color, isHighlighted: Bool) -> some View {
        ZStack(alignment: .bottom) {
            // The tube has a ground and a hairline of its own, one step warmer
            // than the bar track used everywhere else.
            Rectangle()
                .fill(Theme.surfaceTube)
            if let percent, percent > 0 {
                Rectangle()
                    .fill(fill)
                    .frame(height: fillHeight(percent: percent))
            }
        }
        .frame(width: Theme.Bar.tubeWidth, height: Theme.Bar.tubeHeight)
        // The fill takes the tube's curve rather than a curve of its own. As a
        // `Capsule` it was rounded to *its own* height, so a 1% reading drew a
        // 56 pt wide lens 4 pt tall whose corners hung outside the tube's own
        // rounded bottom: the sliver sat across the tube's outline instead of
        // inside it. The design's fill is `border-radius: 28` in a tube of the
        // same radius, which is this: one shape, clipped once.
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Theme.borderTube, lineWidth: DashboardMetrics.chartGridStroke)
        )
        .overlay(highlight(isHighlighted))
        // Quantised to a whole percent, the same rule `TokenBar` follows: the
        // raw value moves on every refresh, and an animation restarted before
        // it finishes interpolates forever inside a window that stays mounted.
        .animation(
            Theme.valueAnimation(Theme.Motion.grow, reduceMotion: reduceMotion, liveIndicators: liveIndicators),
            value: (percent ?? -1).rounded()
        )
        .accessibilityHidden(true)
    }

    /// The header picker's selection, drawn as an outline outside the tube. The
    /// same emphasis language the chart uses on the most recent column, and the
    /// selection is stated in the picker's own words as well, so the outline is
    /// never the only thing saying which window is selected.
    @ViewBuilder
    private func highlight(_ isHighlighted: Bool) -> some View {
        if isHighlighted {
            Capsule(style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: DashboardMetrics.tubeSelectionStroke)
                .padding(DashboardMetrics.tubeSelectionInset)
        }
    }

    /// Each window's own hue, from `Theme.identity(forWindowNamed:)`: coral for
    /// the five hour, lavender for the seven day, mint for a model-scoped cap.
    ///
    /// The design fills each tube with a two-stop gradient. This is the deep
    /// stop of it, flat: `SessionIdentity` carries both stops, and a gradient
    /// costs a shading pass per tube for a difference that is invisible at
    /// 56 pt wide. `lightStop` is there when someone wants it.
    private static func fill(for window: UsageWindow) -> Color {
        Theme.identity(forWindowNamed: window.name).dot
    }

    /// The minimum-fill rule, in one place. A real reading of 1% is floored to
    /// a visible sliver; a measured zero draws nothing, because the floor is
    /// there to keep a small truth visible, not to manufacture one.
    private func fillHeight(percent: Double) -> CGFloat {
        let measured = Theme.Bar.tubeHeight * CGFloat(min(1, percent / 100))
        return min(Theme.Bar.tubeHeight, max(measured, Theme.Bar.minimumVisibleTubeFill))
    }

    private func caption(_ window: UsageWindow) -> some View {
        VStack(spacing: DashboardMetrics.tubeCaptionGap) {
            Text(window.displayName)
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(resetCaption(window, in: language))
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
                // Two, because the caption now carries the countdown and the
                // clock time it counts down to. One line for both wrapped at
                // the first reading that ran long.
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                // A bare duration under a window's name is the one figure on
                // this card that does not say what it counts down to. The
                // design wrote the explanation; nothing was attached to it.
                .tooltip(tip: "reset")
            // The projection (9.11), beside the reset it is measured against:
            // the gap between the two is the whole decision, so it belongs in
            // this same block rather than a separate card.
            projectionLine(for: window)
            if data.isBindingWindow(window) {
                bindingBadge(window)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// The projection, printed under the reset it is measured against.
    ///
    /// Four cases, three of which are not a time (9.11): a rate that empties
    /// the window prints when; a rate that does not is the ordinary case and
    /// the reset above already answers it, so nothing further is said; and the
    /// two `rateUnavailable` reasons this card can actually reach, too few
    /// samples, or a share that has not moved, get their own honest words
    /// rather than one blanket label, because they answer different questions.
    /// `windowIncomplete` prints nothing: `resetCaption` already says `reset
    /// unknown` for that window, and a second line saying the same thing in
    /// different words would not add information.
    @ViewBuilder
    private func projectionLine(for window: UsageWindow) -> some View {
        switch data.projection(for: window) {
        case .exhausts(let at):
            Text(
                Strings.empties.format(
                    in: language,
                    Format.resetStamp(at, now: now, in: language) ?? Strings.soon.string(in: language)
                )
            )
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .holdsUntilReset:
            EmptyView()
        case .rateUnavailable(.notEnoughSamples):
            PhraseText(Strings.rateUnavailable)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuinary)
                .lineLimit(1)
        case .rateUnavailable(.notMoving):
            PhraseText(Strings.notSpending)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuinary)
                .lineLimit(1)
        case .rateUnavailable(.windowIncomplete):
            EmptyView()
        }
    }

    /// Marks the window projected to run out first, among those that run out
    /// at all before they reset (9.11). Glyph and word, not colour alone, and
    /// no colour this card does not already use: the tint is the same
    /// `Theme.color(for: Severity)` the reading and the banner draw from, keyed
    /// off this window's own severity rather than a fourth hue invented for
    /// the badge.
    private func bindingBadge(_ window: UsageWindow) -> some View {
        let severity = window.usedPercent.map { Constants.UsageThreshold.severity(forPercent: min(100, max(0, $0))) }
        return HStack(spacing: Theme.Space.xxs) {
            Image(systemName: "arrow.down.right.circle.fill")
                .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
            PhraseText(Strings.bindsFirst)
        }
        .font(Theme.Typography.micro)
        .foregroundStyle(severity.map(Theme.color(for:)) ?? Theme.textTertiary)
        .accessibilityHidden(true)
    }

    /// The bare duration the design prints under the window's name — `4h 35m`,
    /// not `resets in 4h 35m`. The sentence form is still spoken in the tube's
    /// accessibility label, where there is room for it and no column to keep.
    ///
    /// A reset time that has passed, or was never reported, says so instead. The
    /// design always has a countdown; a real payload does not always carry one.
    private func resetCaption(_ window: UsageWindow, in language: AppLanguage) -> String {
        guard let remaining = Format.timeUntil(window.resetsAt, now: now) else {
            // A reset that has passed still has a clock time worth printing:
            // the window may simply not have been re-read yet, and "reset
            // unknown" beside a timestamp the source did report would be false.
            return Format.resetStamp(window.resetsAt, now: now, in: language) ?? Strings.resetUnknown.string(in: language)
        }
        guard let stamp = Format.resetStamp(window.resetsAt, now: now, in: language) else {
            return remaining
        }
        // Two lines rather than one: the tube column is 372 pt wide shared
        // between every window, and a single line carrying both readings wraps
        // at the first one that runs long.
        return "\(remaining)\n\(stamp)"
    }

    // MARK: - Banner
    //
    // Glyph, word, sentence. The word is the severity spoken, so the banner
    // reads correctly with the tint removed, and the sentence describes what
    // was actually measured rather than repeating the design's copy for a state
    // the data may not be in.

    @ViewBuilder
    private var banner: some View {
        if let state = data.meterState {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Image(systemName: Theme.glyph(for: state.severity))
                    .font(.system(size: Theme.Bar.severityGlyph, weight: .semibold))
                    .foregroundStyle(Theme.color(for: state.severity))
                PhraseText(Theme.namePhrase(for: state.severity).capitalizedInEnglish)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.color(for: state.severity))
                Text(sentence(state, in: language))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, DashboardMetrics.bannerPaddingVertical)
            .padding(.horizontal, DashboardMetrics.bannerPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.banner, style: .continuous)
                    .fill(Theme.color(for: state.severity).opacity(DashboardMetrics.bannerTintOpacity))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                Strings.severitySentence.format(
                    in: language,
                    Theme.namePhrase(for: state.severity).capitalizedInEnglish.string(in: language),
                    sentence(state, in: language)
                )
            )
        } else {
            UnavailableView(UnavailableView.usageUnavailable, reason: Strings.noWindowReportedPercentage)
        }
    }

    /// The sentence used to repeat the worst tube's own percentage and reset
    /// countdown, forty pixels above it in the same card (9.10): `reading(_:)`
    /// already prints `78%` over that tube, and `caption(_:)` already prints
    /// its reset countdown under it, so the banner was restating both figures
    /// a second time under a different sentence. What the tube cannot say is
    /// which of several tubes the banner is about, or that the picker's own
    /// severity glyph has no accompanying word anywhere else on the card — the
    /// glyph carries colour, and `CLAUDE.md` requires colour never to stand
    /// alone. Both survive; the percent and the countdown do not.
    private func sentence(
        _ state: (window: UsageWindow, percent: Double, severity: Severity),
        in language: AppLanguage
    ) -> String {
        guard !data.everyWindowIsHealthy else {
            // The design's own line, and only ever shown when it is true of
            // every window on the card.
            return Strings.plentyOfPower.string(in: language)
        }
        var text = Strings.windowNamed.format(in: language, state.window.displayName)
        let unreadable = data.meterWindows.filter { $0.usedPercent == nil }.count
        if unreadable == 1 {
            text += Strings.oneWindowUnavailable.string(in: language)
        } else if unreadable > 1 {
            text += Strings.windowsUnavailable.format(in: language, "\(unreadable)")
        }
        return text
    }

    // MARK: - Text

    /// The tooltip that explains this window. Keyed off the payload's own name,
    /// so a model-scoped cap gets the model-scoped explanation.
    private static func tooltipKey(for window: UsageWindow) -> String {
        switch window.name {
        case DashboardData.WindowKey.fiveHour: return "power"
        case DashboardData.WindowKey.sevenDay: return "seven"
        default: return "fable"
        }
    }

    private func spokenTube(
        _ window: UsageWindow,
        percent: Double?,
        severity: Severity?
    ) -> String {
        guard let percent, let severity else {
            return Strings.spokenTubeUnavailable.format(in: language, window.displayName)
        }
        var text = Strings.spokenTubeUsed.format(
            in: language,
            window.displayName,
            Format.percent(percent),
            Theme.namePhrase(for: severity).string(in: language)
        )
        if let remaining = Format.timeUntil(window.resetsAt, now: now) {
            text += Strings.spokenResetsIn.format(in: language, remaining)
        }
        text += " \(spokenProjection(for: window, in: language))"
        if data.isBindingWindow(window) {
            text += Strings.spokenBindsFirst.string(in: language)
        }
        return text
    }

    /// The projection line, spoken. Kept apart from `projectionLine(for:)` so
    /// the visual and the spoken form can each say what fits their medium
    /// without one constraining the other's wording, the same split
    /// `sentence(_:)` already keeps from the tube's own reading.
    private func spokenProjection(for window: UsageWindow, in language: AppLanguage) -> String {
        switch data.projection(for: window) {
        case .exhausts(let at):
            return Strings.spokenProjectedEmpty.format(
                in: language,
                Format.resetStamp(at, now: now, in: language) ?? Strings.beforeTheReset.string(in: language)
            )
        case .holdsUntilReset:
            return Strings.spokenHoldsUntilReset.string(in: language)
        case .rateUnavailable(.notEnoughSamples):
            return Strings.spokenRateUnavailable.string(in: language)
        case .rateUnavailable(.notMoving):
            return Strings.spokenNotSpending.string(in: language)
        case .rateUnavailable(.windowIncomplete):
            return ""
        }
    }
}

// MARK: - Strings

private enum Strings {
    static let title = Phrase(en: "Power meter", th: "มาตรวัดพลังงาน")
    static let subtitle = Phrase(en: "usage limits", th: "ขีดจำกัดการใช้งาน")
    static let noWindowReported = Phrase(
        en: "No usage window has been reported yet",
        th: "ยังไม่มีหน้าต่างการใช้งานที่รายงานเข้ามา"
    )
    static let noWindowReportedPercentage = Phrase(
        en: "No window reported a percentage",
        th: "ไม่มีหน้าต่างใดรายงานเปอร์เซ็นต์การใช้งาน"
    )

    static let burnLeaderLine = Phrase(
        en: "%@ is driving the burn, %@ of it",
        th: "%@ เป็นตัวขับเคลื่อนการใช้ token หลัก คิดเป็น %@ ของทั้งหมด"
    )
    static let burnLeaderSpoken = Phrase(
        en: "%@ is responsible for %@ of the current burn.",
        th: "%@ รับผิดชอบ %@ ของอัตราการใช้ token ปัจจุบัน"
    )

    static let empties = Phrase(en: "Empties %@", th: "หมดเมื่อ %@")
    static let soon = Phrase(en: "soon", th: "เร็วๆ นี้")
    static let rateUnavailable = Phrase(en: "Rate unavailable", th: "ไม่มีข้อมูลอัตราการใช้")
    static let notSpending = Phrase(en: "Not spending", th: "ไม่มีการใช้")
    static let bindsFirst = Phrase(en: "binds first", th: "หมดก่อนหน้าต่างอื่น")
    static let resetUnknown = Phrase(en: "reset unknown", th: "ไม่ทราบเวลารีเซ็ต")

    static let plentyOfPower = Phrase(
        en: "plenty of power in every window",
        th: "ทุกหน้าต่างยังมีโควต้าเหลือมาก"
    )
    static let windowNamed = Phrase(en: "%@ window", th: "หน้าต่าง %@")
    static let oneWindowUnavailable = Phrase(
        en: " · 1 window unavailable",
        th: " · หน้าต่างเดียวไม่มีข้อมูล"
    )
    static let windowsUnavailable = Phrase(
        en: " · %@ windows unavailable",
        th: " · %@ หน้าต่างไม่มีข้อมูล"
    )
    static let severitySentence = Phrase(en: "%@. %@.", th: "%@ %@")

    static let spokenTubeUnavailable = Phrase(
        en: "%@ window, usage unavailable.",
        th: "หน้าต่าง %@ ไม่มีข้อมูลการใช้งาน"
    )
    static let spokenTubeUsed = Phrase(
        en: "%@ window, %@ used, %@.",
        th: "หน้าต่าง %@ ใช้ไป %@ อยู่ในระดับ %@"
    )
    static let spokenResetsIn = Phrase(en: " Resets in %@.", th: " รีเซ็ตในอีก %@")
    static let spokenBindsFirst = Phrase(
        en: " This window binds first.",
        th: " หน้าต่างนี้จะหมดก่อนหน้าต่างอื่น"
    )
    static let spokenProjectedEmpty = Phrase(
        en: "Projected to empty %@.",
        th: "คาดว่าจะหมดที่ %@"
    )
    static let beforeTheReset = Phrase(en: "before the reset", th: "ก่อนถึงเวลารีเซ็ต")
    static let spokenHoldsUntilReset = Phrase(
        en: "Holds until reset at the current rate.",
        th: "ที่อัตราปัจจุบัน จะยังไม่หมดจนกว่าจะรีเซ็ต"
    )
    static let spokenRateUnavailable = Phrase(
        en: "Rate unavailable.",
        th: "ไม่มีข้อมูลอัตราการใช้"
    )
    static let spokenNotSpending = Phrase(en: "Not spending.", th: "ไม่มีการใช้")
}
