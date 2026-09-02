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
            count: 4
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: DashboardMetrics.statTileGap) {
            tokensTile
            burnTile
            activeTile
            costTile
        }
    }

    // MARK: - Tiles

    private var tokensTile: some View {
        tile(
            label: "Tokens today",
            tint: Self.warmTint,
            tooltipKey: "today",
            spoken: spokenTokens
        ) {
            if let usage = data.todayUsage {
                value(Format.tokens(usage.total))
                changeCaption(ink: Self.warmTint.ink)
            } else {
                UnavailableView("Token usage unavailable", compact: true)
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
                Text("\(Format.percent(abs(change) * 100)) vs yesterday")
            }
            .font(Theme.Typography.help)
            .foregroundStyle(ink)
            .lineLimit(1)
        } else {
            caption("across all projects", ink: ink)
        }
    }

    private var burnTile: some View {
        tile(
            label: "Burn rate",
            tint: Self.lavenderTint,
            tooltipKey: "burn",
            spoken: spokenBurn
        ) {
            if let rate = data.burnRatePerMinute {
                // `/min` set apart from the figure, at the design's 14 px: it
                // is a unit, not another digit.
                value(Format.tokens(Int(rate.rounded())), unit: "/min")
                caption(burnDenominator, ink: Self.lavenderTint.ink)
            } else {
                UnavailableView(
                    "Rate unavailable",
                    reason: "Too few samples to state a rate",
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
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        return "rolling \(DashboardMetrics.burnWindowMinutes) min · \(sessions)"
    }

    private var activeTile: some View {
        tile(
            label: "Active sessions",
            tint: Self.mintTint,
            tooltipKey: "active",
            spoken: spokenActive
        ) {
            // The design's ` / 4 today` only appears when something upstream
            // could actually count the day. It is nil today, and a denominator
            // invented from the live set would be smaller than the truth.
            value("\(data.sessions.count)", unit: todayDenominator)
            caption(
                data.activeProjectCount == 1
                    ? "1 project"
                    : "\(data.activeProjectCount) projects",
                ink: Self.mintTint.ink
            )
        }
    }

    private var todayDenominator: String? {
        data.todaySessionCount.map { " / \($0) today" }
    }

    private var costTile: some View {
        tile(
            label: "Est. cost",
            tint: Self.amberTint,
            tooltipKey: "cost",
            spoken: spokenCost
        ) {
            if let cost = data.todayCost {
                value(Format.cost(cost))
                caption(costCaption, ink: Self.amberTint.ink)
            } else {
                UnavailableView(
                    "Cost unavailable",
                    reason: unpricedReason ?? "No price is known for one of today's models",
                    compact: true
                )
            }
        }
    }

    /// The word "estimated" travels with the number wherever it goes, and the
    /// count of unpriced sessions says how incomplete the estimate is.
    private var costCaption: String {
        var text: String
        switch data.unpricedSessionCount {
        case 0: text = "estimated, not billed"
        case 1: text = "estimated, 1 session unpriced"
        default: text = "estimated, \(data.unpricedSessionCount) sessions unpriced"
        }
        // Only ever appended, never substituted for the sentence above: how
        // incomplete the estimate is and how old its rates are are two separate
        // facts and the caption owes the reader both.
        if let days = data.priceTableStaleDays {
            text += " \u{00B7} prices \(days) days old"
        }
        return text
    }

    private var unpricedReason: String? {
        guard data.unpricedSessionCount > 0 else { return nil }
        return data.unpricedSessionCount == 1
            ? "1 session has no price for its model"
            : "\(data.unpricedSessionCount) sessions have no price for their model"
    }

    // MARK: - Chrome

    private func tile<Content: View>(
        label: String,
        tint: Tint,
        tooltipKey: String,
        spoken: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DashboardMetrics.statTileContentGap) {
            Text(label.uppercased())
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

    private func caption(_ text: String, ink: Color) -> some View {
        Text(text)
            .font(Theme.Typography.help)
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }

    // MARK: - Spoken labels

    private var spokenTokens: String {
        guard let usage = data.todayUsage else { return "Tokens today, usage unavailable." }
        var text = "Tokens today, \(Format.tokens(usage.total))."
        if let change = data.todayVersusYesterday {
            let direction = change < 0 ? "down" : "up"
            text += " \(direction.capitalized) \(Format.percent(abs(change) * 100)) "
            text += "on yesterday."
        }
        return text
    }

    private var spokenBurn: String {
        guard let rate = data.burnRatePerMinute else {
            return "Burn rate unavailable. Too few samples to state a rate."
        }
        return "Burn rate, \(Format.tokens(Int(rate.rounded()))) tokens per minute, "
            + "\(burnDenominator)."
    }

    private var spokenActive: String {
        let sessions = data.sessions.count == 1 ? "1 session" : "\(data.sessions.count) sessions"
        let projects = data.activeProjectCount == 1
            ? "1 project"
            : "\(data.activeProjectCount) projects"
        var text = "\(sessions) active, across \(projects)."
        if let today = data.todaySessionCount {
            text += " \(today) ran today."
        }
        return text
    }

    private var spokenCost: String {
        guard let cost = data.todayCost else {
            return "Estimated cost unavailable. "
                + (unpricedReason ?? "No price is known for one of today's models") + "."
        }
        return "Estimated cost today, \(Format.cost(cost)). \(costCaption.capitalized). "
            + "This is an estimate, not a billing amount."
    }
}
