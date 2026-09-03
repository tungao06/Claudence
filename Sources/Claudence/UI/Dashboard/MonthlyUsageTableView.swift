import SwiftUI
import ClaudenceCore

/// The monthly table (spec 9.13): one row per project, sorted by tokens, over
/// the trailing month. Twelve rows at most -- `MonitorViewModel.monthlyUsage`
/// is already the prefix the adapter took -- and every cell is either a
/// measured value or the word for its absence, the same rule
/// `ProjectBreakdownView` follows for the all-time table above it.
///
/// The model split is the point of the row. Opus and Sonnet each get their
/// own column, and a third "Other" column carries every model neither name
/// matches -- Haiku, an older snapshot, and the `unknown` bucket a record with
/// no model name falls into -- so a project that spent a third of its tokens
/// on Haiku shows that share instead of reading as two thirds of something
/// else. The three columns are read off `MonthlyProjectRow.opusShare`,
/// `.sonnetShare` and `.otherShare`, which already sum to the whole by
/// construction: `DashboardAdapter.monthlyRow` sums each bucket from the
/// store's own per-model split rather than computing "other" by subtraction.
struct MonthlyUsageTableView: View {
    let rows: [MonthlyProjectRow]
    /// Whether `rows` already includes subagent tokens, carried as data from
    /// `ClaudenceStore.MonthlyUsageReport.includesSubagentTokens` rather than
    /// asserted here in prose that could drift from what the store actually
    /// did.
    let includesSubagentTokens: Bool
    let emptyMessage: String
    let emptyReason: String?

    init(
        rows: [MonthlyProjectRow],
        includesSubagentTokens: Bool,
        emptyMessage: String = "No usage recorded this month",
        emptyReason: String? = nil
    ) {
        self.rows = rows
        self.includesSubagentTokens = includesSubagentTokens
        self.emptyMessage = emptyMessage
        self.emptyReason = emptyReason
    }

    var body: some View {
        if rows.isEmpty {
            UnavailableView(emptyMessage, reason: emptyReason)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header
                Divider().overlay(Theme.separator)
                ForEach(rows) { row in
                    monthlyRow(row)
                }
                Text(subagentFootnote)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, Theme.Space.xxs)
            }
        }
    }

    /// States the fact `includesSubagentTokens` carries rather than a sentence
    /// written by hand for one side of it: a build where the store ever stops
    /// combining subagent tokens into these figures gets a footnote that says
    /// so instead of one that keeps claiming the earlier behaviour.
    private var subagentFootnote: String {
        includesSubagentTokens
            ? "Includes subagent tokens."
            : "Subagent tokens are not included in these figures."
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: DashboardMetrics.columnSpacing) {
            columnTitle("Project")
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle("Sessions")
                .frame(width: DashboardMetrics.monthlySessionsColumn, alignment: .trailing)
            columnTitle("Tokens")
                .frame(width: DashboardMetrics.monthlyTokensColumn, alignment: .trailing)
            columnTitle("Opus")
                .frame(width: DashboardMetrics.monthlyShareColumn, alignment: .trailing)
            columnTitle("Sonnet")
                .frame(width: DashboardMetrics.monthlyShareColumn, alignment: .trailing)
            columnTitle("Other")
                .frame(width: DashboardMetrics.monthlyShareColumn, alignment: .trailing)
            columnTitle("API equiv.")
                .frame(width: DashboardMetrics.monthlyCostColumn, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Theme.Typography.section)
            .tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
    }

    // MARK: - Row

    private func monthlyRow(_ row: MonthlyProjectRow) -> some View {
        HStack(alignment: .center, spacing: DashboardMetrics.columnSpacing) {
            Text(row.project)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                // The tail of a path is what identifies a project, the same
                // choice `ProjectBreakdownView` makes for the same reason.
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            numericCell(
                "\(row.sessionCount)",
                width: DashboardMetrics.monthlySessionsColumn
            )
            numericCell(
                Format.tokens(row.usage.total),
                width: DashboardMetrics.monthlyTokensColumn
            )
            numericCell(
                Format.share(row.opusShare),
                width: DashboardMetrics.monthlyShareColumn
            )
            numericCell(
                Format.share(row.sonnetShare),
                width: DashboardMetrics.monthlyShareColumn
            )
            numericCell(
                Format.share(row.otherShare),
                width: DashboardMetrics.monthlyShareColumn
            )
            numericCell(
                apiEquivalentText(row),
                width: DashboardMetrics.monthlyCostColumn,
                isKnown: row.apiEquivalent != nil
            )
        }
        .padding(.vertical, Theme.Space.xxs)
        .elevates(.row, cornerRadius: Theme.Radius.hoverTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(row))
    }

    private func numericCell(_ text: String, width: CGFloat, isKnown: Bool = true) -> some View {
        Text(text)
            .font(Theme.Typography.numeric)
            .foregroundStyle(isKnown ? Theme.textSecondary : Theme.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: width, alignment: .trailing)
    }

    /// A row whose tokens are known but whose price is not reads as zero if
    /// this just prints `Format.cost(nil)`'s "unavailable" -- the same word a
    /// project with nothing recorded at all would show. Saying plainly that
    /// the tokens are known and the price is not is the fix spec 9.13 calls
    /// for, kept out of `Format.cost` itself because that function has no way
    /// to know which kind of nil it was handed.
    private func apiEquivalentText(_ row: MonthlyProjectRow) -> String {
        if let cost = row.apiEquivalent {
            return Format.cost(cost)
        }
        guard row.usage.total > 0 else { return Format.cost(nil) }
        return "tokens known, no price"
    }

    private func spokenLabel(_ row: MonthlyProjectRow) -> String {
        var parts = [
            "\(row.project).",
            row.sessionCount == 1 ? "1 session." : "\(row.sessionCount) sessions.",
            "\(Format.tokens(row.usage.total)) tokens.",
            "\(Format.share(row.opusShare)) Opus, \(Format.share(row.sonnetShare)) Sonnet, "
                + "\(Format.share(row.otherShare)) other models.",
        ]
        if let cost = row.apiEquivalent {
            parts.append("API equivalent \(Format.cost(cost)).")
        } else if row.usage.total > 0 {
            parts.append("Tokens known, no price available for the API equivalent.")
        } else {
            parts.append("API equivalent unavailable.")
        }
        return parts.joined(separator: " ")
    }
}
