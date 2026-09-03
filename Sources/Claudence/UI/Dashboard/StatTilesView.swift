import SwiftUI
import ClaudenceCore

/// The four-up summary strip.
///
/// Each tile is a label, one large machine-set number, and a sub-caption that
/// states what the number is a measurement of. The sub-caption is not
/// decoration: three of these four figures are meaningless without their
/// denominator, and a tile that showed the number alone would be inviting the
/// wrong reading.
///
/// The design tints each tile a different hue and inks its label and caption to
/// match: warm for tokens, lavender for burn, mint for sessions, amber for
/// cost. Those tints are identity, not severity. Nothing on this strip has a
/// severity to report — a cost is not "attention" because it is amber — so the
/// tint is fixed per tile and never moves with a value, and every reading on
/// the strip is carried by its own words. Severity still resolves in exactly
/// one place, `Theme.color(for: Severity)`, and the meter is where it is drawn.
///
/// Every value here can go missing independently, so each tile degrades on its
/// own rather than the strip disappearing.
struct StatTilesView: View {
    let data: DashboardData

    /// Whether `Preferences.liveOnlyMode` is on, read the same way
    /// `liveIndicators` is: this strip is a leaf several levels under the
    /// composition root and has no other reason to know a preference exists.
    ///
    /// `Tokens today` and `API equivalent today` are both totals over every session
    /// that ran today, ended ones included, which is a figure live-only mode
    /// has nothing to reconstruct once a session leaves the live registry; the
    /// day-over-day delta compounds that by comparing against yesterday, which
    /// is gone the moment the process quits. All three are omitted rather than
    /// rendered `Usage unavailable`, and the grid drops to the two tiles nothing
    /// about live-only mode touches: burn rate and active sessions, both read
    /// straight off the live registry.
    @Environment(\.liveOnlyMode) private var liveOnlyMode
    @Environment(\.appLanguage) private var language

    /// One tile's tint, ink and border, from `Theme.Tile`.
    ///
    /// A tile's colour is identity, not state: the cost tile is amber whether
    /// the cost is a cent or a hundred dollars. That is why these are their own
    /// family in `Theme` rather than the severity ramp borrowed for decoration
    /// — an amber that sometimes means "attention" and sometimes means "this is
    /// the cost tile" means neither.
    private struct Tint {
        let fill: Color
        let border: Color
        let ink: Color
    }

    private static var warmTint: Tint {
        Tint(fill: Theme.Tile.warmFill, border: Theme.Tile.warmBorder, ink: Theme.Tile.warmInk)
    }

    private static var lavenderTint: Tint {
        Tint(
            fill: Theme.Tile.lavenderFill,
            border: Theme.Tile.lavenderBorder,
            ink: Theme.Tile.lavenderInk
        )
    }

    private static var mintTint: Tint {
        Tint(fill: Theme.Tile.mintFill, border: Theme.Tile.mintBorder, ink: Theme.Tile.mintInk)
    }

    private static var amberTint: Tint {
        Tint(fill: Theme.Tile.amberFill, border: Theme.Tile.amberBorder, ink: Theme.Tile.amberInk)
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: DashboardMetrics.statTileGap, alignment: .top),
            count: liveOnlyMode ? 2 : 4
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: DashboardMetrics.statTileGap) {
            if !liveOnlyMode {
                tokensTile
            }
            burnTile
            activeTile
            if !liveOnlyMode {
                costTile
            }
        }
    }

    // MARK: - Tiles

    /// The one surviving reader of `data.todayUsage.total` on this window
    /// (9.10). `TokenBreakdownCard`'s own `Total` row printed the identical
    /// figure a few inches below this tile until it was removed, and this one
    /// is the reader that keeps it: the four-tile strip is where someone scans
    /// for "how much today, and versus yesterday" without opening a card, and
    /// `changeCaption` below carries the day-over-day delta the breakdown card
    /// never had a place for. The breakdown card's own reader, "where did it
    /// go", is unaffected — its four category rows and stacked bar still sum
    /// to the same number this tile shows, just no longer printed a second
    /// time as its own headline.
    private var tokensTile: some View {
        tile(
            label: Strings.tokensToday,
            tint: Self.warmTint,
            tooltipKey: "today",
            spoken: spokenTokens
        ) {
            if let usage = data.todayUsage {
                value(Format.tokens(usage.total))
                changeCaption(ink: Self.warmTint.ink)
            } else {
                UnavailableView(TokenBar.tokenUsageUnavailable, compact: true)
            }
        }
    }

    /// Direction as an arrow and a word, never as a colour. A day that grew and
    /// a day that shrank are both ordinary, so neither gets a severity token.
    ///
    /// "Yesterday" is a claim, and one the figure behind it earns:
    /// `AnalyticsService.dayOverDay()` keys the two buckets on the calendar
    /// itself and answers nil when the store could not read them or when
    /// yesterday recorded nothing to compare against.
    @ViewBuilder
    private func changeCaption(ink: Color) -> some View {
        if let change = data.todayVersusYesterday {
            HStack(spacing: Theme.Space.xxs) {
                Image(systemName: change < 0 ? "arrow.down" : "arrow.up")
                    .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                Text(Strings.vsYesterday.format(in: language, Format.percent(abs(change) * 100)))
            }
            .font(Theme.Typography.help)
            .foregroundStyle(ink)
            .lineLimit(1)
        } else {
            caption(Strings.acrossAllProjects, ink: ink)
        }
    }

    private var burnTile: some View {
        tile(
            label: Strings.burnRate,
            tint: Self.lavenderTint,
            tooltipKey: "burn",
            spoken: spokenBurn
        ) {
            if let rate = data.burnRatePerMinute {
                // `/min` set apart from the figure, at the design's 14 px: it
                // is a unit, not another digit.
                value(Format.tokens(Int(rate.rounded())), unit: "/min")
                caption(.untranslated(burnDenominator), ink: Self.lavenderTint.ink)
            } else {
                UnavailableView(
                    Strings.rateUnavailable,
                    reason: Strings.tooFewSamples,
                    compact: true
                )
            }
        }
    }

    /// The design's caption here is `rolling 10 min`. The tracker behind this
    /// figure averages over five minutes, not ten, and it sums the sessions that
    /// could state a rate rather than every session on screen. Both facts are in
    /// the caption, because a caption that named the wrong window would be
    /// describing a measurement this application does not take.
    private var burnDenominator: String {
        let count = data.sessionsReportingBurn
        let sessions = count == 1
            ? Strings.oneSession.string(in: language)
            : Strings.sessionCount.format(in: language, "\(count)")
        return Strings.rollingMinutes.format(in: language, "\(DashboardMetrics.burnWindowMinutes)", sessions)
    }

    /// Active over live, both counted off the same array.
    ///
    /// The design's shape here is `2 / 4 today`, and the denominator used to be
    /// `sessionsActiveToday()`: a count of stored rows whose last activity fell
    /// today, against a numerator that was every session in the live registry.
    /// The two sets are not nested, so an idle session still alive under
    /// yesterday's timestamp was in the numerator and not the denominator and
    /// the tile printed `2 / 1 today`, which is not a quantity. Ordering the two
    /// reads does not fix it; only counting both halves off one set does.
    ///
    /// So the fraction is active over live, where active is `status ==
    /// .running` and live is every session with a process. The numerator is a
    /// subset of the denominator by construction, and the word "active" means
    /// the same thing here as it does in the menu bar's spoken label.
    ///
    /// The denominator itself, `/ N live`, does not print on the tile (9.10).
    /// It is `data.liveSessionCount`, which is `data.sessions.count` — exactly
    /// the row count of the `Live sessions` card sitting directly above this
    /// strip, printed a second time as a headline figure a reader had already
    /// seen by looking at the rows. Dropping it does not drop the range this
    /// tile is answering over: the label already says "active sessions", the
    /// caption still says how many projects they span, and a reader who wants
    /// the live total has it by counting the card above or, for VoiceOver,
    /// from `spokenActive` below, which keeps the live count because a screen
    /// reader has no card of rows to fall back on the way a sighted reader
    /// does.
    private var activeTile: some View {
        tile(
            label: Strings.activeSessions,
            tint: Self.mintTint,
            tooltipKey: "active",
            spoken: spokenActive
        ) {
            value("\(data.activeSessionCount)")
            caption(
                data.liveProjectCount == 1
                    ? Strings.oneProject
                    : .untranslated(Strings.projectCount.format(in: language, "\(data.liveProjectCount)")),
                ink: Self.mintTint.ink
            )
        }
    }

    /// Labelled as an API equivalent rather than as a cost.
    ///
    /// On a subscription this figure is not an amount owed and never was: the
    /// monthly bill is fixed and this number does not appear on it. What it is good
    /// for is the one job no token count can do, which is comparing 632k of
    /// Sonnet against 632k of Opus, and the question a reader actually has is
    /// whether the subscription is earning its price. Calling it a cost invited
    /// the other question, the one it answers wrongly.
    private var costTile: some View {
        tile(
            label: Strings.apiEquivalentToday,
            tint: Self.amberTint,
            tooltipKey: "cost",
            spoken: spokenCost
        ) {
            if let cost = data.todayCost {
                value(Format.cost(cost, in: language))
                caption(.untranslated(costCaption), ink: Self.amberTint.ink)
            } else {
                UnavailableView(
                    Strings.apiEquivalentUnavailable,
                    reason: unpricedReason ?? Strings.noPriceKnown,
                    compact: true
                )
            }
            if let subscriptionLine {
                caption(.untranslated(subscriptionLine), ink: Self.amberTint.ink)
            }
        }
    }

    /// The plan's own price, named beside the API-equivalent estimate so the
    /// reader is not recalling it from memory (9.14).
    ///
    /// Both figures state their own period rather than being left to imply a
    /// comparison neither earns on its own: the tile above this line is what
    /// today's tokens would have cost on the API, and this is a fixed charge
    /// for the whole month, not the same question asked twice. Nil whenever
    /// the preference is unset, which is the default -- CLAUDE.md forbids
    /// hard-coding a published subscription price, so this is the one dollar
    /// figure on the tile that the reader supplies rather than one Claudence
    /// measures.
    private var subscriptionLine: String? {
        guard let price = data.subscriptionMonthlyPrice else { return nil }
        guard let plan = data.accountPlanDisplayName else {
            return Strings.yourPlanCosts.format(in: language, Format.cost(price))
        }
        return Strings.planCosts.format(in: language, plan, Format.cost(price))
    }

    /// The word "estimated" travels with the number wherever it goes, and the
    /// count of unpriced sessions says how incomplete the estimate is.
    private var costCaption: String {
        var text: String
        switch data.unpricedSessionCount {
        case 0: text = Strings.estimatedNotBilled.string(in: language)
        case 1: text = Strings.estimatedOneUnpriced.string(in: language)
        default: text = Strings.estimatedCountUnpriced.format(in: language, "\(data.unpricedSessionCount)")
        }
        // Only ever appended, never substituted for the sentence above: how
        // incomplete the estimate is and how old its rates are are two separate
        // facts and the caption owes the reader both.
        if let days = data.priceTableStaleDays {
            text += Strings.pricesDaysOld.format(in: language, "\(days)")
        }
        return text
    }

    private var unpricedReason: Phrase? {
        guard data.unpricedSessionCount > 0 else { return nil }
        return data.unpricedSessionCount == 1
            ? Strings.oneSessionNoPrice
            : .untranslated(Strings.sessionsNoPrice.format(in: language, "\(data.unpricedSessionCount)"))
    }

    // MARK: - Chrome

    private func tile<Content: View>(
        label: Phrase,
        tint: Tint,
        tooltipKey: String,
        spoken: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DashboardMetrics.statTileContentGap) {
            Text(label.string(in: language).uppercased())
                .font(Theme.Typography.label)
                // `.04em` at 11 px, not the popover section heading's `.14em`.
                .tracking(DashboardMetrics.statTileLabelTracking)
                .foregroundStyle(tint.ink)
                .lineLimit(1)
                .tooltip(tip: tooltipKey)
            content()
        }
        // Stretched to the tallest tile in the row. Four tiles whose contents
        // are of different heights - a figure, a figure with a caption, an
        // unavailable line - ended on four different baselines otherwise.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.vertical, DashboardMetrics.statTilePaddingVertical)
        .padding(.horizontal, DashboardMetrics.statTilePaddingHorizontal)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .fill(tint.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                .strokeBorder(tint.border, lineWidth: DashboardMetrics.chartGridStroke)
        )
        // A tile is a panel, so it takes the card level, not the row level: the
        // strip is four surfaces side by side and one of them coming forward is
        // the reading. The radius is the tile's own `panel` and not the level's
        // default `card`, so the hover ground behind it stays tucked behind its
        // corners rather than showing four warm slivers.
        .elevates(.card, cornerRadius: Theme.Radius.panel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// The figure, with an optional unit trailing it one step smaller and one
    /// step quieter. The two are one text run so the unit sits on the figure's
    /// baseline rather than being centred against a 26 pt line.
    private func value(_ text: String, unit: String? = nil) -> some View {
        (
            Text(text)
                .font(Theme.Typography.statValue)
                .foregroundStyle(Theme.textPrimary)
            + Text(unit ?? "")
                // Semibold, not regular: in the HTML the unit is a nested span
                // that inherits `font-weight: 600` from the figure it trails.
                // `UI-CONTRACT.md` records it as 400, which is a transcription
                // error against the markup.
                .font(
                    .system(
                        size: DashboardMetrics.statTileUnitSize,
                        weight: .semibold,
                        design: .monospaced
                    )
                )
                .foregroundStyle(Theme.textTertiary)
        )
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func caption(_ phrase: Phrase, ink: Color) -> some View {
        PhraseText(phrase)
            .font(Theme.Typography.help)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    // MARK: - Spoken labels

    private var spokenTokens: String {
        guard let usage = data.todayUsage else {
            return Strings.spokenTokensUnavailable.string(in: language)
        }
        var text = Strings.spokenTokensToday.format(in: language, Format.tokens(usage.total))
        if let change = data.todayVersusYesterday {
            let direction = change < 0 ? Strings.spokenDown : Strings.spokenUp
            text += Strings.spokenVsYesterday.format(
                in: language,
                direction.string(in: language),
                Format.percent(abs(change) * 100)
            )
        }
        return text
    }

    private var spokenBurn: String {
        guard let rate = data.burnRatePerMinute else {
            return Strings.spokenBurnUnavailable.string(in: language)
        }
        return Strings.spokenBurnRate.format(
            in: language,
            Format.tokens(Int(rate.rounded())),
            burnDenominator
        )
    }

    /// The same two counts and the same two words the tile prints. A spoken
    /// label that said "two sessions active" over a tile reading `1 / 2 live`
    /// is the defect this file is being edited for, one surface further down.
    private var spokenActive: String {
        let live = data.liveSessionCount == 1
            ? Strings.spokenOneLiveSession.string(in: language)
            : Strings.spokenLiveSessionCount.format(in: language, "\(data.liveSessionCount)")
        let projects = data.liveProjectCount == 1
            ? Strings.oneProject.string(in: language)
            : Strings.projectCount.format(in: language, "\(data.liveProjectCount)")
        return Strings.spokenActive.format(
            in: language,
            "\(data.activeSessionCount)",
            live,
            projects
        )
    }

    private var spokenCost: String {
        var text: String
        if let cost = data.todayCost {
            text = Strings.spokenApiEquivalent.format(
                in: language,
                Format.cost(cost, in: language),
                costCaption.capitalized
            )
        } else {
            text = Strings.spokenApiEquivalentUnavailable.format(
                in: language,
                (unpricedReason ?? Strings.noPriceKnown).string(in: language)
            )
        }
        if let subscriptionLine {
            text += Strings.spokenSubscriptionLine.format(in: language, subscriptionLine)
        }
        return text
    }
}

// MARK: - Strings

private enum Strings {
    static let tokensToday = Phrase(en: "Tokens today", th: "Token วันนี้")
    static let vsYesterday = Phrase(en: "%@ vs yesterday", th: "%@ เทียบกับเมื่อวาน")
    static let acrossAllProjects = Phrase(en: "across all projects", th: "รวมทุกโปรเจกต์")

    static let burnRate = Phrase(en: "Burn rate", th: "อัตราการใช้")
    static let rateUnavailable = Phrase(en: "Rate unavailable", th: "ไม่มีข้อมูลอัตราการใช้")
    static let tooFewSamples = Phrase(
        en: "Too few samples to state a rate",
        th: "มีตัวอย่างไม่พอที่จะระบุอัตราการใช้"
    )
    static let oneSession = Phrase(en: "1 session", th: "1 session")
    static let sessionCount = Phrase(en: "%@ sessions", th: "%@ session")
    static let rollingMinutes = Phrase(
        en: "rolling %@ min · %@",
        th: "rolling %@ นาที · %@"
    )

    static let activeSessions = Phrase(en: "Active sessions", th: "Session ที่กำลังทำงาน")
    static let oneProject = Phrase(en: "1 project", th: "1 โปรเจกต์")
    static let projectCount = Phrase(en: "%@ projects", th: "%@ โปรเจกต์")

    static let apiEquivalentToday = Phrase(en: "API equivalent today", th: "มูลค่าเทียบเท่า API วันนี้")
    static let apiEquivalentUnavailable = Phrase(
        en: "API equivalent unavailable",
        th: "ไม่มีข้อมูลมูลค่าเทียบเท่า API"
    )
    static let noPriceKnown = Phrase(
        en: "No price is known for one of today's models",
        th: "ไม่มีราคาของโมเดลที่ใช้ในวันนี้อย่างน้อยหนึ่งตัว"
    )
    static let oneSessionNoPrice = Phrase(
        en: "1 session has no price for its model",
        th: "1 session ไม่มีราคาสำหรับโมเดลของมัน"
    )
    static let sessionsNoPrice = Phrase(
        en: "%@ sessions have no price for their model",
        th: "%@ session ไม่มีราคาสำหรับโมเดลของตัวเอง"
    )
    static let yourPlanCosts = Phrase(en: "Your plan costs %@/mo", th: "แผนของคุณมีค่าใช้จ่าย %@/เดือน")
    static let planCosts = Phrase(en: "%@ costs %@/mo", th: "%@ มีค่าใช้จ่าย %@/เดือน")
    static let estimatedNotBilled = Phrase(
        en: "estimated, not billed",
        th: "ประมาณการ ไม่ได้เรียกเก็บเงินจริง"
    )
    static let estimatedOneUnpriced = Phrase(
        en: "estimated, 1 session unpriced",
        th: "ประมาณการ มี 1 session ที่ไม่มีราคา"
    )
    static let estimatedCountUnpriced = Phrase(
        en: "estimated, %@ sessions unpriced",
        th: "ประมาณการ มี %@ session ที่ไม่มีราคา"
    )
    static let pricesDaysOld = Phrase(en: " \u{00B7} prices %@ days old", th: " \u{00B7} ราคาเก่า %@ วัน")

    static let spokenTokensUnavailable = Phrase(
        en: "Tokens today, usage unavailable.",
        th: "Token วันนี้ ไม่มีข้อมูลการใช้งาน"
    )
    static let spokenTokensToday = Phrase(en: "Tokens today, %@.", th: "Token วันนี้ %@")
    static let spokenDown = Phrase(en: "Down", th: "ลดลง")
    static let spokenUp = Phrase(en: "Up", th: "เพิ่มขึ้น")
    static let spokenVsYesterday = Phrase(
        en: " %@ %@ on yesterday.",
        th: " %@ %@ เทียบกับเมื่อวาน"
    )
    static let spokenBurnUnavailable = Phrase(
        en: "Burn rate unavailable. Too few samples to state a rate.",
        th: "ไม่มีข้อมูลอัตราการใช้ มีตัวอย่างไม่พอที่จะระบุอัตราการใช้"
    )
    static let spokenBurnRate = Phrase(
        en: "Burn rate, %@ tokens per minute, %@.",
        th: "อัตราการใช้ %@ token ต่อนาที %@"
    )
    static let spokenOneLiveSession = Phrase(en: "1 live session", th: "1 session ที่ทำงานอยู่")
    static let spokenLiveSessionCount = Phrase(en: "%@ live sessions", th: "%@ session ที่ทำงานอยู่")
    static let spokenActive = Phrase(
        en: "%@ of %@ active, across %@.",
        th: "%@ จาก %@ ที่ active ครอบคลุม %@"
    )
    static let spokenApiEquivalent = Phrase(
        en: "API equivalent today, %@. %@. "
            + "This is what today's tokens would have cost on the API, not an amount owed.",
        th: "มูลค่าเทียบเท่า API วันนี้ %@ %@ "
            + "นี่คือมูลค่าที่ token วันนี้จะมีราคาเท่าไรถ้าใช้ผ่าน API ไม่ใช่ยอดที่ต้องจ่ายจริง"
    )
    static let spokenApiEquivalentUnavailable = Phrase(
        en: "API equivalent unavailable. %@.",
        th: "ไม่มีข้อมูลมูลค่าเทียบเท่า API %@"
    )
    static let spokenSubscriptionLine = Phrase(en: " %@.", th: " %@")
}
