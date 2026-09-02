import SwiftUI
import ClaudenceCore

/// Where today's tokens went, split four ways.
///
/// The four categories are `Theme.TokenCategory` and nothing else decides what
/// they are. Cache read and cache write keep their own rows here for the same
/// reason they do everywhere in the product: a cache read costs roughly a tenth
/// of a fresh input token, so folding the three into one "input" figure would
/// make the display disagree with the bill by an order of magnitude on the
/// cheapest part of it.
///
/// The design's card also carries a context-window inset. That is not
/// reproduced, and deliberately: a context window bounds one request's input,
/// while this card totals every request of the day, so there is no denominator
/// on this screen to divide by. `SessionDetailView` explains the same refusal
/// at length. Shipping the inset would mean shipping a percentage with nothing
/// behind it.
struct TokenBreakdownCard: View {
    /// Nil means today's totals could not be read. A zero total is a different
    /// answer and is drawn as one.
    let usage: TokenUsage?
    /// What the figures are a total of, shown under the title.
    let subtitle: String

    init(usage: TokenUsage?, subtitle: String = "today · all projects") {
        self.usage = usage
        self.subtitle = subtitle
    }

    var body: some View {
        DashboardCard(
            title: "Token breakdown",
            subtitle: subtitle,
            contentGap: DashboardMetrics.cardContentGapTight
        ) {
            if let usage {
                if usage.total > 0 {
                    stackedBar(usage)
                }
                rows(usage)
                Divider().overlay(Theme.separator)
                totalRow(usage)
                privacyFooter
            } else {
                UnavailableView(
                    "Token usage unavailable",
                    reason: "No transcript has been read for today yet"
                )
                privacyFooter
            }
        }
    }

    // MARK: - Stacked bar

    private func stackedBar(_ usage: TokenUsage) -> some View {
        let drawn = Self.segments(usage).filter { $0.drawn > 0 }
        return GeometryReader { geo in
            let gaps = DashboardMetrics.stackedBarSegmentGap * CGFloat(max(0, drawn.count - 1))
            let available = max(0, geo.size.width - gaps)
            HStack(spacing: DashboardMetrics.stackedBarSegmentGap) {
                ForEach(drawn) { segment in
                    Capsule(style: .continuous)
                        .fill(Theme.color(for: segment.category))
                        .frame(width: available * CGFloat(segment.drawn))
                }
            }
        }
        .frame(height: DashboardMetrics.stackedBarHeight)
        .accessibilityHidden(true)
    }

    /// One slice of the stacked bar: the share as measured, and the share as
    /// drawn.
    struct Segment: Identifiable, Equatable {
        let category: Theme.TokenCategory
        /// The true fraction of the total. This is what the row prints.
        let measured: Double
        /// The fraction the bar paints, after the minimum-fill lift.
        let drawn: Double

        var id: Theme.TokenCategory { category }
    }

    /// The four segments, with a real-but-tiny category lifted to a visible
    /// width.
    ///
    /// A segment under `Theme.Bar.minimumVisibleFill` of the bar is raised to
    /// it and the difference is taken proportionally off the segments that can
    /// afford it, so the bar still sums to the whole. The lift never applies to
    /// a zero, and `measured` is untouched, so nothing a reader can quote off
    /// this card has been adjusted for legibility.
    static func segments(_ usage: TokenUsage) -> [Segment] {
        let total = Double(usage.total)
        let categories = Theme.TokenCategory.allCases
        guard total > 0 else {
            return categories.map { Segment(category: $0, measured: 0, drawn: 0) }
        }
        let measured = categories.map { Double(value(for: $0, in: usage)) / total }
        let floorShare = Theme.Bar.minimumVisibleFill

        let deficit = measured
            .filter { $0 > 0 && $0 < floorShare }
            .reduce(0) { $0 + (floorShare - $1) }
        let pool = measured.filter { $0 >= floorShare }.reduce(0, +)
        // With no room to borrow from, the bar keeps its raw proportions rather
        // than distorting into shares that no longer sum to the whole.
        guard deficit > 0, pool > deficit else {
            return zip(categories, measured).map {
                Segment(category: $0, measured: $1, drawn: $1)
            }
        }
        let scale = (pool - deficit) / pool
        return zip(categories, measured).map { category, share in
            let drawn: Double
            if share <= 0 {
                drawn = 0
            } else {
                drawn = share < floorShare ? floorShare : share * scale
            }
            return Segment(category: category, measured: share, drawn: drawn)
        }
    }

    static func value(for category: Theme.TokenCategory, in usage: TokenUsage) -> Int {
        switch category {
        case .freshInput: return usage.freshInput
        case .cacheWrite: return usage.cacheCreation
        case .cacheRead: return usage.cacheRead
        case .output: return usage.output
        }
    }

    // MARK: - Legend rows

    private func rows(_ usage: TokenUsage) -> some View {
        VStack(alignment: .leading, spacing: DashboardMetrics.breakdownRowGap) {
            ForEach(Theme.TokenCategory.allCases, id: \.self) { category in
                row(category, usage: usage)
            }
        }
    }

    /// Swatch, label, figure, on one line, which is the whole of the design's
    /// row.
    ///
    /// A per-category track and a printed share used to sit here as well. Both
    /// went: the stacked bar directly above already draws every share against
    /// the same total, so a second bar per row was the same reading a second
    /// time, four rows deep, and it pushed the card past the height the column
    /// beside it has. The share itself is not lost — the row's tooltip states
    /// it, and so does its accessibility label.
    private func row(_ category: Theme.TokenCategory, usage: TokenUsage) -> some View {
        let amount = Self.value(for: category, in: usage)
        let share = usage.total > 0 ? Double(amount) / Double(usage.total) : nil
        return HStack(spacing: Theme.Space.s + Theme.Space.xs) {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.color(for: category))
                .frame(
                    width: DashboardMetrics.legendSwatch,
                    height: DashboardMetrics.legendSwatch
                )
            Text(category.label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if category == .output, usage.thinking > 0 {
                Text("(\(Format.tokens(usage.thinking)) thinking)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Space.s)
            Text(Format.tokens(amount))
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        // The row level, and only the row level. The card level is already on
        // this panel: it arrives with the `DashboardCard` shell above, which is
        // where every panel on the window gets its depth, and a second card
        // lift nested inside the first would double the rise and make this one
        // panel behave unlike the other five.
        //
        // The rows earn a lift of their own because each one is a tooltip
        // trigger, and four legend lines with a shared swatch column are
        // exactly the arrangement where a reader loses which line the bubble is
        // about. `elevates` sits under `tooltip` so the bubble's own hover
        // region is measured against a rectangle the lift cannot move.
        .elevates(.row, cornerRadius: Theme.Radius.hoverTarget)
        .tooltip(breakdown: category.label, value: amount, of: usage.total)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenRow(category, amount: amount, share: share))
    }

    private func totalRow(_ usage: TokenUsage) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text("Total")
                .font(Theme.Typography.labelEmphasis)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.m)
            Text(Format.tokens(usage.total))
                .font(Theme.Typography.panelValue)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Total, \(Format.tokens(usage.total)) tokens.")
    }

    /// The one claim on this card that is not a number, and the one the privacy
    /// contract makes it worth printing: the parser reads counts, never content.
    private var privacyFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: "lock.fill")
                .font(.system(size: Theme.Bar.statusGlyph))
            Text("Read locally. No text or commands are ever read.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Typography.caption)
        .foregroundStyle(Theme.textQuaternary)
        .accessibilityElement(children: .combine)
    }

    private func spokenRow(
        _ category: Theme.TokenCategory,
        amount: Int,
        share: Double?
    ) -> String {
        var text = "\(category.label), \(Format.tokens(amount)) tokens"
        if let share { text += ", \(Format.percent(share * 100)) of the total" }
        return text + "."
    }
}
