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
    let emptyMessage: Phrase
    let emptyReason: Phrase?

    @Environment(\.appLanguage) private var language

    init(
        rows: [MonthlyProjectRow],
        includesSubagentTokens: Bool,
        emptyMessage: Phrase = Strings.noUsageThisMonth,
        emptyReason: Phrase? = nil
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
                PhraseText(subagentFootnote)
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
    private var subagentFootnote: Phrase {
        includesSubagentTokens
            ? Strings.includesSubagentTokens
            : Strings.excludesSubagentTokens
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: DashboardMetrics.columnSpacing) {
            columnTitle(Strings.columnProject)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle(Strings.columnSessions)
                .frame(width: DashboardMetrics.monthlySessionsColumn, alignment: .trailing)
            columnTitle(Strings.columnTokens)
                .frame(width: DashboardMetrics.monthlyTokensColumn, alignment: .trailing)
            columnTitle(Strings.columnOpus)
                .frame(width: DashboardMetrics.monthlyShareColumn, alignment: .trailing)
            columnTitle(Strings.columnSonnet)
                .frame(width: DashboardMetrics.monthlyShareColumn, alignment: .trailing)
            columnTitle(Strings.columnOther)
                .frame(width: DashboardMetrics.monthlyShareColumn, alignment: .trailing)
            columnTitle(Strings.columnApiEquiv)
                .frame(width: DashboardMetrics.monthlyCostColumn, alignment: .trailing)
        }
        .accessibilityHidden(true)
    }

    private func columnTitle(_ phrase: Phrase) -> some View {
        Text(phrase.string(in: language).uppercased())
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
        return Strings.tokensKnownNoPrice.string(in: language)
    }

    private func spokenLabel(_ row: MonthlyProjectRow) -> String {
        var parts = [
            "\(row.project).",
            row.sessionCount == 1
                ? Strings.spokenOneSession.string(in: language)
                : Strings.spokenSessionCount.format(in: language, "\(row.sessionCount)"),
            Strings.spokenTokens.format(in: language, Format.tokens(row.usage.total)),
            Strings.spokenModelShares.format(
                in: language,
                Format.share(row.opusShare),
                Format.share(row.sonnetShare),
                Format.share(row.otherShare)
            ),
        ]
        if let cost = row.apiEquivalent {
            parts.append(Strings.spokenApiEquivalent.format(in: language, Format.cost(cost)))
        } else if row.usage.total > 0 {
            parts.append(Strings.spokenTokensKnownNoPrice.string(in: language))
        } else {
            parts.append(Strings.spokenApiEquivalentUnavailable.string(in: language))
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Strings

private enum Strings {
    static let noUsageThisMonth = Phrase(
        en: "No usage recorded this month",
        th: "ยังไม่มีการใช้งานบันทึกไว้ในเดือนนี้"
    )
    static let includesSubagentTokens = Phrase(
        en: "Includes subagent tokens.",
        th: "รวม token ของ subagent ด้วย"
    )
    static let excludesSubagentTokens = Phrase(
        en: "Subagent tokens are not included in these figures.",
        th: "ตัวเลขเหล่านี้ไม่รวม token ของ subagent"
    )

    static let columnProject = Phrase(en: "Project", th: "โปรเจกต์")
    static let columnSessions = Phrase(en: "Sessions", th: "Session")
    static let columnTokens = Phrase(en: "Tokens", th: "Token")
    static let columnOpus = Phrase.untranslated("Opus")
    static let columnSonnet = Phrase.untranslated("Sonnet")
    static let columnOther = Phrase(en: "Other", th: "อื่นๆ")
    static let columnApiEquiv = Phrase(en: "API equiv.", th: "เทียบเท่า API")

    static let tokensKnownNoPrice = Phrase(
        en: "tokens known, no price",
        th: "รู้จำนวน token แต่ไม่มีราคา"
    )

    static let spokenOneSession = Phrase(en: "1 session.", th: "1 session")
    static let spokenSessionCount = Phrase(en: "%@ sessions.", th: "%@ session")
    static let spokenTokens = Phrase(en: "%@ tokens.", th: "%@ token")
    static let spokenModelShares = Phrase(
        en: "%@ Opus, %@ Sonnet, %@ other models.",
        th: "Opus %@, Sonnet %@, โมเดลอื่น %@"
    )
    static let spokenApiEquivalent = Phrase(en: "API equivalent %@.", th: "เทียบเท่า API %@")
    static let spokenTokensKnownNoPrice = Phrase(
        en: "Tokens known, no price available for the API equivalent.",
        th: "รู้จำนวน token แต่ไม่มีราคาสำหรับคำนวณมูลค่าเทียบเท่า API"
    )
    static let spokenApiEquivalentUnavailable = Phrase(
        en: "API equivalent unavailable.",
        th: "ไม่มีข้อมูลมูลค่าเทียบเท่า API"
    )
}
