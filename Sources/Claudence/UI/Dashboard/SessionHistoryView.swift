import SwiftUI
import ClaudenceCore

/// Which slice of history is on screen.
///
/// Three ranges, fixed. The cut-off is computed from an injected `now`, so the
/// view stays a function of its inputs and the boundary is testable.
enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDays
    case thirtyDays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .sevenDays: return "7 Days"
        case .thirtyDays: return "30 Days"
        }
    }

    /// Spoken form, so the filter never reads as an abbreviation.
    var spokenTitle: String {
        switch self {
        case .today: return "today"
        case .sevenDays: return "the last 7 days"
        case .thirtyDays: return "the last 30 days"
        }
    }

    private static let day: TimeInterval = 86_400

    /// Earliest start time included in this range.
    func cutoff(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .sevenDays: return now.addingTimeInterval(-7 * HistoryRange.day)
        case .thirtyDays: return now.addingTimeInterval(-30 * HistoryRange.day)
        }
    }
}

/// Finished sessions, newest first, filterable by range.
///
/// The last section in the fixed order, and deliberately the quietest thing on
/// the window: history explains the meter, it never competes with it.
struct SessionHistoryView: View {
    let rows: [HistoryRow]
    let now: Date

    @State private var range: HistoryRange

    init(rows: [HistoryRow], now: Date = Date(), initialRange: HistoryRange = .sevenDays) {
        self.rows = rows
        self.now = now
        _range = State(initialValue: initialRange)
    }

    private var visibleRows: [HistoryRow] {
        let cutoff = range.cutoff(from: now)
        return rows
            .filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private var visibleTotal: Int {
        visibleRows.reduce(0) { $0 + $1.usage.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            controls
            content
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
            Picker("History range", selection: $range) {
                ForEach(HistoryRange.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("History range")

            Spacer(minLength: Theme.Space.m)

            Text(summaryText)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .accessibilityLabel(spokenSummary)
        }
    }

    private var summaryText: String {
        let count = visibleRows.count
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        guard count > 0 else { return sessions }
        return "\(sessions) · \(Format.tokens(visibleTotal)) tokens"
    }

    private var spokenSummary: String {
        let count = visibleRows.count
        guard count > 0 else { return "No sessions in \(range.spokenTitle)." }
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        return "\(sessions) in \(range.spokenTitle), \(Format.tokens(visibleTotal)) tokens."
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            // Nothing has ever been recorded. Not an error state.
            UnavailableView(
                "No session history recorded",
                reason: "Sessions appear here once they finish"
            )
        } else if visibleRows.isEmpty {
            // The store answered; this range is genuinely empty.
            UnavailableView("No sessions in \(range.title.lowercased())", compact: true)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header
                Divider().overlay(Theme.separator)
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(visibleRows) { row in
                        historyRow(row)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: DashboardMetrics.columnSpacing) {
            columnTitle("Started")
                .frame(width: DashboardMetrics.historyStartedColumn, alignment: .leading)
            columnTitle("Project")
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle("Model")
                .frame(width: DashboardMetrics.historyModelColumn, alignment: .leading)
            columnTitle("Duration")
                .frame(width: DashboardMetrics.historyDurationColumn, alignment: .trailing)
            columnTitle("Tokens")
                .frame(width: DashboardMetrics.historyTokensColumn, alignment: .trailing)
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

    private func historyRow(_ row: HistoryRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.columnSpacing) {
            Text(Self.started(row.startedAt))
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: DashboardMetrics.historyStartedColumn, alignment: .leading)

            Text(row.project)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.model ?? "unavailable")
                .font(Theme.Typography.caption)
                .foregroundStyle(row.model == nil ? Theme.textTertiary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DashboardMetrics.historyModelColumn, alignment: .leading)

            Text(Format.duration(row.duration))
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: DashboardMetrics.historyDurationColumn, alignment: .trailing)

            Text(Format.tokens(row.usage.total))
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: DashboardMetrics.historyTokensColumn, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(row))
    }

    // MARK: - Text

    /// Value-type formatting: no shared `DateFormatter`, nothing to isolate.
    private static func started(_ date: Date) -> String {
        date.formatted(
            .dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .abbreviated)).minute()
        )
    }

    private static func spokenLabel(_ row: HistoryRow) -> String {
        var parts = [
            "\(row.project).",
            "Started \(started(row.startedAt)).",
            "Ran for \(Format.duration(row.duration)).",
            "\(Format.tokens(row.usage.total)) tokens.",
        ]
        parts.append(row.model.map { "Model \($0)." } ?? "Model unavailable.")
        return parts.joined(separator: " ")
    }
}
