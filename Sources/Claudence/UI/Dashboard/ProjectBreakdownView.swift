import SwiftUI
import ClaudenceCore

/// Where the energy went, by project.
///
/// A quiet table, not a card grid. Every cell is either a measured value or the
/// word for its absence; no column ever falls back to zero. The share bar is
/// explicitly relative to the busiest project, stated in the footnote, because
/// a bar with an unstated denominator is a ratio nobody agreed to.
struct ProjectBreakdownView: View {
    let rows: [ProjectRow]
    let emptyMessage: Phrase
    let emptyReason: Phrase?
    /// Reference time for "last active". Injected so the view stays a function
    /// of its inputs.
    let now: Date

    @Environment(\.appLanguage) private var language

    init(
        rows: [ProjectRow],
        emptyMessage: Phrase = Strings.noActivityRecorded,
        emptyReason: Phrase? = nil,
        now: Date = Date()
    ) {
        self.rows = rows
        self.emptyMessage = emptyMessage
        self.emptyReason = emptyReason
        self.now = now
    }

    /// Denominator for the share bars. Nil when nothing has been measured, in
    /// which case no bar is drawn at all.
    private var busiestTotal: Int? {
        let peak = rows.map(\.usage.total).max() ?? 0
        return peak > 0 ? peak : nil
    }

    var body: some View {
        if rows.isEmpty {
            UnavailableView(emptyMessage, reason: emptyReason)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header
                Divider().overlay(Theme.separator)
                ForEach(rows) { row in
                    projectRow(row)
                }
                if busiestTotal != nil {
                    PhraseText(Strings.barsRelative)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.Space.xxs)
                } else {
                    // Every project measured zero. That is a real answer, so
                    // say it rather than drawing empty tracks.
                    PhraseText(Strings.noTokensRecorded)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.Space.xxs)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: DashboardMetrics.columnSpacing) {
            columnTitle(Strings.columnProject)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle(Strings.columnSessions)
                .frame(width: DashboardMetrics.projectSessionsColumn, alignment: .trailing)
            columnTitle(Strings.columnTokens)
                .frame(width: DashboardMetrics.projectTokensColumn, alignment: .trailing)
            columnTitle(Strings.columnApiEquiv)
                .frame(width: DashboardMetrics.projectCostColumn, alignment: .trailing)
            columnTitle(Strings.columnAvgTime)
                .frame(width: DashboardMetrics.projectDurationColumn, alignment: .trailing)
            columnTitle(Strings.columnLastActive)
                .frame(width: DashboardMetrics.projectLastActiveColumn, alignment: .trailing)
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

    private func projectRow(_ row: ProjectRow) -> some View {
        HStack(alignment: .top, spacing: DashboardMetrics.columnSpacing) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(row.project)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    // The tail of a path is what identifies a project, so a
                    // very long one loses its head, not its name.
                    .truncationMode(.head)
                shareBar(row)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            numericCell(
                "\(row.sessionCount)",
                width: DashboardMetrics.projectSessionsColumn,
                isKnown: true
            )
            numericCell(
                Format.tokens(row.usage.total),
                width: DashboardMetrics.projectTokensColumn,
                isKnown: true
            )
            numericCell(
                Format.cost(row.estimatedCost),
                width: DashboardMetrics.projectCostColumn,
                isKnown: row.estimatedCost != nil
            )
            numericCell(
                averageText(row),
                width: DashboardMetrics.projectDurationColumn,
                isKnown: row.averageDuration != nil
            )
            numericCell(
                lastActiveText(row),
                width: DashboardMetrics.projectLastActiveColumn,
                isKnown: row.lastActivity != nil
            )
        }
        .padding(.vertical, Theme.Space.xxs)
        // The row the design names when it defines `hoverTarget`: six columns
        // read across, where losing your place costs the reading. The lift and
        // the ground are supplied by `elevates`; the row's own padding is
        // untouched, so the hover ground covers exactly the area the row
        // already occupied and no line moves when the pointer arrives.
        .elevates(.row, cornerRadius: Theme.Radius.hoverTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel(row))
    }

    private func numericCell(_ text: String, width: CGFloat, isKnown: Bool) -> some View {
        Text(text)
            .font(Theme.Typography.numeric)
            .foregroundStyle(isKnown ? Theme.textSecondary : Theme.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: width, alignment: .trailing)
    }

    @ViewBuilder
    private func shareBar(_ row: ProjectRow) -> some View {
        if let busiestTotal {
            let fraction = min(1, max(0, Double(row.usage.total) / Double(busiestTotal)))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Theme.track)
                    Capsule(style: .continuous)
                        .fill(Theme.healthy)
                        // A non-zero share always shows at least a dot, so a
                        // small project is visibly different from an idle one.
                        .frame(
                            width: fraction <= 0
                                ? 0
                                : max(Theme.Bar.micro, geo.size.width * fraction)
                        )
                }
            }
            .frame(height: Theme.Bar.micro)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Text

    private func averageText(_ row: ProjectRow) -> String {
        guard let average = row.averageDuration else { return Strings.unavailable.string(in: language) }
        return Format.duration(average)
    }

    private func lastActiveText(_ row: ProjectRow) -> String {
        guard let last = row.lastActivity else { return Strings.unavailable.string(in: language) }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= 0 else { return Strings.justNow.string(in: language) }
        return Strings.durationAgo.format(in: language, Format.duration(elapsed))
    }

    private func spokenLabel(_ row: ProjectRow) -> String {
        var parts = [
            "\(row.project).",
            row.sessionCount == 1
                ? Strings.spokenOneSession.string(in: language)
                : Strings.spokenSessionCount.format(in: language, "\(row.sessionCount)"),
            Strings.spokenTokens.format(in: language, Format.tokens(row.usage.total)),
        ]
        if let cost = row.estimatedCost {
            parts.append(Strings.spokenApiEquivalent.format(in: language, Format.cost(cost)))
        } else {
            parts.append(Strings.spokenApiEquivalentUnavailable.string(in: language))
        }
        if let average = row.averageDuration {
            parts.append(Strings.spokenAverageSession.format(in: language, Format.duration(average)))
        } else {
            parts.append(Strings.spokenAverageSessionUnavailable.string(in: language))
        }
        parts.append(
            row.lastActivity == nil
                ? Strings.spokenLastActiveUnavailable.string(in: language)
                : Strings.spokenLastActive.format(in: language, lastActiveText(row))
        )
        return parts.joined(separator: " ")
    }
}

// MARK: - Strings

private enum Strings {
    static let noActivityRecorded = Phrase(
        en: "No project activity recorded",
        th: "ยังไม่มีกิจกรรมของโปรเจกต์บันทึกไว้"
    )
    static let barsRelative = Phrase(
        en: "Bars are relative to the busiest project.",
        th: "แท่งกราฟเทียบกับโปรเจกต์ที่ใช้งานมากที่สุด"
    )
    static let noTokensRecorded = Phrase(
        en: "No tokens recorded for any project yet.",
        th: "ยังไม่มี token บันทึกไว้สำหรับโปรเจกต์ใดเลย"
    )

    static let columnProject = Phrase(en: "Project", th: "โปรเจกต์")
    static let columnSessions = Phrase(en: "Sessions", th: "Session")
    static let columnTokens = Phrase(en: "Tokens", th: "Token")
    static let columnApiEquiv = Phrase(en: "API equiv.", th: "เทียบเท่า API")
    static let columnAvgTime = Phrase(en: "Avg time", th: "เวลาเฉลี่ย")
    static let columnLastActive = Phrase(en: "Last active", th: "ใช้งานล่าสุด")

    static let unavailable = Phrase(en: "unavailable", th: "ไม่มีข้อมูล")
    static let justNow = Phrase(en: "just now", th: "เมื่อสักครู่")
    static let durationAgo = Phrase(en: "%@ ago", th: "%@ ที่แล้ว")

    static let spokenOneSession = Phrase(en: "1 session.", th: "1 session")
    static let spokenSessionCount = Phrase(en: "%@ sessions.", th: "%@ session")
    static let spokenTokens = Phrase(en: "%@ tokens.", th: "%@ token")
    static let spokenApiEquivalent = Phrase(
        en: "API equivalent %@.",
        th: "เทียบเท่า API %@"
    )
    static let spokenApiEquivalentUnavailable = Phrase(
        en: "API equivalent unavailable.",
        th: "ไม่มีข้อมูลเทียบเท่า API"
    )
    static let spokenAverageSession = Phrase(
        en: "Average session %@.",
        th: "session เฉลี่ย %@"
    )
    static let spokenAverageSessionUnavailable = Phrase(
        en: "Average session length unavailable.",
        th: "ไม่มีข้อมูลระยะเวลา session เฉลี่ย"
    )
    static let spokenLastActive = Phrase(en: "Last active %@.", th: "ใช้งานล่าสุด %@")
    static let spokenLastActiveUnavailable = Phrase(
        en: "Last active unavailable.",
        th: "ไม่มีข้อมูลการใช้งานล่าสุด"
    )
}
