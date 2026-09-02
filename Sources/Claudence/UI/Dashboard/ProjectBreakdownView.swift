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
    let emptyMessage: String
    let emptyReason: String?
    /// Reference time for "last active". Injected so the view stays a function
    /// of its inputs.
    let now: Date

    init(
        rows: [ProjectRow],
        emptyMessage: String = "No project activity recorded",
        emptyReason: String? = nil,
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
                    Text("Bars are relative to the busiest project.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, Theme.Space.xxs)
                } else {
                    // Every project measured zero. That is a real answer, so
                    // say it rather than drawing empty tracks.
                    Text("No tokens recorded for any project yet.")
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
            columnTitle("Project")
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle("Sessions")
                .frame(width: DashboardMetrics.projectSessionsColumn, alignment: .trailing)
            columnTitle("Tokens")
                .frame(width: DashboardMetrics.projectTokensColumn, alignment: .trailing)
            columnTitle("Est. cost")
                .frame(width: DashboardMetrics.projectCostColumn, alignment: .trailing)
            columnTitle("Avg time")
                .frame(width: DashboardMetrics.projectDurationColumn, alignment: .trailing)
            columnTitle("Last active")
                .frame(width: DashboardMetrics.projectLastActiveColumn, alignment: .trailing)
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
        guard let average = row.averageDuration else { return "unavailable" }
        return Format.duration(average)
    }

    private func lastActiveText(_ row: ProjectRow) -> String {
        guard let last = row.lastActivity else { return "unavailable" }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= 0 else { return "just now" }
        return "\(Format.duration(elapsed)) ago"
    }

    private func spokenLabel(_ row: ProjectRow) -> String {
        var parts = [
            "\(row.project).",
            row.sessionCount == 1 ? "1 session." : "\(row.sessionCount) sessions.",
            "\(Format.tokens(row.usage.total)) tokens.",
        ]
        if let cost = row.estimatedCost {
            parts.append("Estimated cost \(Format.cost(cost)).")
        } else {
            parts.append("Estimated cost unavailable.")
        }
        if let average = row.averageDuration {
            parts.append("Average session \(Format.duration(average)).")
        } else {
            parts.append("Average session length unavailable.")
        }
        parts.append(
            row.lastActivity == nil
                ? "Last active unavailable."
                : "Last active \(lastActiveText(row))."
        )
        return parts.joined(separator: " ")
    }
}
