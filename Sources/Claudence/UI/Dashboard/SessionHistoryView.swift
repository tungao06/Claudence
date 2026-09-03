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

    var title: Phrase {
        switch self {
        case .today: return HistoryStrings.rangeToday
        case .sevenDays: return HistoryStrings.rangeSevenDays
        case .thirtyDays: return HistoryStrings.rangeThirtyDays
        }
    }

    /// Spoken form, so the filter never reads as an abbreviation.
    var spokenTitle: Phrase {
        switch self {
        case .today: return HistoryStrings.spokenRangeToday
        case .sevenDays: return HistoryStrings.spokenRangeSevenDays
        case .thirtyDays: return HistoryStrings.spokenRangeThirtyDays
        }
    }

    /// `title`, lowercased, for the sentence that names an empty range: "No
    /// sessions in today" rather than "No sessions in Today". Its own phrase
    /// rather than `title.string(in:).lowercased()`, because Thai script has
    /// no case to lower in the first place.
    var lowercaseTitle: Phrase {
        switch self {
        case .today: return HistoryStrings.rangeTodayLower
        case .sevenDays: return HistoryStrings.rangeSevenDaysLower
        case .thirtyDays: return HistoryStrings.rangeThirtyDaysLower
        }
    }

    private static let day: TimeInterval = 86_400

    /// Earliest *activity* time included in this range.
    ///
    /// Activity, not start. `Today` is `startOfDay`, and a session that opened
    /// last night and was still working this morning is one of today's: the
    /// same definition `AnalyticsService.sessionsToday()` and the daily rollup
    /// use. Filtering on `startedAt` made this table read `0 sessions` under a
    /// tile, on the same window and off the same database, that had counted
    /// that session as today's.
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
    @Environment(\.appLanguage) private var language

    init(rows: [HistoryRow], now: Date = Date(), initialRange: HistoryRange = .sevenDays) {
        self.rows = rows
        self.now = now
        _range = State(initialValue: initialRange)
    }

    /// Filtered and sorted exactly once per body evaluation.
    ///
    /// This used to be a computed property read by the summary line, the
    /// spoken summary and the table, which meant the sort ran three times for
    /// one frame, on every frame. It is a parameter now, so a longer history
    /// costs what it should.
    /// Filtered on last activity and sorted on start: the range asks which day
    /// the work happened on, and the column the reader is looking at is
    /// `Started`, so a row that survives the filter still lands where its own
    /// visible timestamp says it should.
    private var visibleRows: [HistoryRow] {
        let cutoff = range.cutoff(from: now)
        return rows
            .filter { $0.lastActivityAt >= cutoff }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func total(of visible: [HistoryRow]) -> Int {
        visible.reduce(0) { $0 + $1.usage.total }
    }

    var body: some View {
        let visible = visibleRows
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            controls(visible)
            content(visible)
        }
    }

    // MARK: - Controls

    private func controls(_ visible: [HistoryRow]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.l) {
            Picker(HistoryStrings.historyRange.string(in: language), selection: $range) {
                ForEach(HistoryRange.allCases) { option in
                    PhraseText(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(HistoryStrings.historyRange, in: language)

            Spacer(minLength: Theme.Space.m)

            Text(summaryText(visible))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .accessibilityLabel(spokenSummary(visible))
        }
    }

    private func summaryText(_ visible: [HistoryRow]) -> String {
        let count = visible.count
        let sessions = count == 1
            ? HistoryStrings.oneSession.string(in: language)
            : HistoryStrings.sessionCount.format(in: language, "\(count)")
        guard count > 0 else { return sessions }
        return HistoryStrings.summaryWithTokens.format(
            in: language,
            sessions,
            Format.tokens(total(of: visible))
        )
    }

    private func spokenSummary(_ visible: [HistoryRow]) -> String {
        let count = visible.count
        guard count > 0 else {
            return HistoryStrings.spokenNoSessions.format(in: language, range.spokenTitle.string(in: language))
        }
        let sessions = count == 1
            ? HistoryStrings.oneSession.string(in: language)
            : HistoryStrings.sessionCount.format(in: language, "\(count)")
        return HistoryStrings.spokenSummary.format(
            in: language,
            sessions,
            range.spokenTitle.string(in: language),
            Format.tokens(total(of: visible))
        )
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ visible: [HistoryRow]) -> some View {
        if rows.isEmpty {
            // Nothing has ever been recorded. Not an error state.
            UnavailableView(
                HistoryStrings.noHistoryRecorded,
                reason: HistoryStrings.sessionsAppearHere
            )
        } else if visible.isEmpty {
            // The store answered; this range is genuinely empty. A different
            // statement from having no history at all, and it must stay one.
            UnavailableView(noSessionsMessage(for: range), compact: true)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                header
                Divider().overlay(Theme.separator)
                LazyVStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(visible) { row in
                        historyRow(row)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: DashboardMetrics.columnSpacing) {
            columnTitle(HistoryStrings.columnStarted)
                .frame(width: DashboardMetrics.historyStartedColumn, alignment: .leading)
            columnTitle(HistoryStrings.columnProject)
                .frame(maxWidth: .infinity, alignment: .leading)
            columnTitle(HistoryStrings.columnModel)
                .frame(width: DashboardMetrics.historyModelColumn, alignment: .leading)
            columnTitle(HistoryStrings.columnDuration)
                .frame(width: DashboardMetrics.historyDurationColumn, alignment: .trailing)
            columnTitle(HistoryStrings.columnTokens)
                .frame(width: DashboardMetrics.historyTokensColumn, alignment: .trailing)
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

    private func historyRow(_ row: HistoryRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DashboardMetrics.columnSpacing) {
            Text(Self.started(row.startedAt, in: language))
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

            Text(row.model ?? HistoryStrings.unavailable.string(in: language))
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
        // A history line is five columns of text and nothing else, so unlike a
        // session row it has no surface of its own for a shadow to fall from.
        // `elevates` supplies one, which is also what tells a reader which of
        // thirty lines the pointer is on when the five values are read across.
        // The radius is the design's own `hoverTarget`, the corner it cuts a
        // row-sized hover ground to.
        .elevates(.row, cornerRadius: Theme.Radius.hoverTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(row, in: language))
    }

    // MARK: - Text

    /// A concrete phrase built in both languages, for a caller (`UnavailableView`)
    /// that resolves its own language from the environment rather than being
    /// handed an already-resolved string.
    private func noSessionsMessage(for range: HistoryRange) -> Phrase {
        Phrase(
            en: HistoryStrings.noSessionsInRange.format(
                in: .english,
                range.lowercaseTitle.string(in: .english)
            ),
            th: HistoryStrings.noSessionsInRange.format(
                in: .thai,
                range.lowercaseTitle.string(in: .thai)
            )
        )
    }

    /// Value-type formatting: no shared `DateFormatter`, nothing to isolate.
    /// Routed through `AppLanguage.locale`, per `CLAUDE.md`'s Thai-calendar
    /// trap: `th_TH` alone would print the Buddhist year, and this locale
    /// pins the Gregorian calendar the app displays everywhere else.
    private static func started(_ date: Date, in language: AppLanguage) -> String {
        date.formatted(
            .dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .abbreviated)).minute()
                .locale(language.locale)
        )
    }

    private static func spokenLabel(_ row: HistoryRow, in language: AppLanguage) -> String {
        var parts = [
            "\(row.project).",
            HistoryStrings.spokenStarted.format(in: language, started(row.startedAt, in: language)),
            HistoryStrings.spokenRanFor.format(in: language, Format.duration(row.duration)),
            HistoryStrings.spokenTokens.format(in: language, Format.tokens(row.usage.total)),
        ]
        parts.append(
            row.model.map { HistoryStrings.spokenModel.format(in: language, $0) }
                ?? HistoryStrings.spokenModelUnavailable.string(in: language)
        )
        return parts.joined(separator: " ")
    }
}

// MARK: - Strings

private enum HistoryStrings {
    static let rangeToday = Phrase(en: "Today", th: "วันนี้")
    static let rangeSevenDays = Phrase(en: "7 Days", th: "7 วัน")
    static let rangeThirtyDays = Phrase(en: "30 Days", th: "30 วัน")
    static let rangeTodayLower = Phrase(en: "today", th: "วันนี้")
    static let rangeSevenDaysLower = Phrase(en: "7 days", th: "7 วัน")
    static let rangeThirtyDaysLower = Phrase(en: "30 days", th: "30 วัน")

    static let spokenRangeToday = Phrase(en: "today", th: "วันนี้")
    static let spokenRangeSevenDays = Phrase(en: "the last 7 days", th: "7 วันล่าสุด")
    static let spokenRangeThirtyDays = Phrase(en: "the last 30 days", th: "30 วันล่าสุด")

    static let historyRange = Phrase(en: "History range", th: "ช่วงเวลาประวัติ")
    static let oneSession = Phrase(en: "1 session", th: "1 session")
    static let sessionCount = Phrase(en: "%@ sessions", th: "%@ session")
    static let summaryWithTokens = Phrase(en: "%@ · %@ tokens", th: "%@ · %@ token")
    static let spokenNoSessions = Phrase(en: "No sessions in %@.", th: "ไม่มี session ใน%@")
    static let spokenSummary = Phrase(
        en: "%@ in %@, %@ tokens.",
        th: "%@ ใน%@ จำนวน %@ token"
    )

    static let noHistoryRecorded = Phrase(
        en: "No session history recorded",
        th: "ยังไม่มีประวัติ session บันทึกไว้"
    )
    static let sessionsAppearHere = Phrase(
        en: "Sessions appear here once they finish",
        th: "Session จะปรากฏที่นี่เมื่อจบการทำงานแล้ว"
    )
    static let noSessionsInRange = Phrase(en: "No sessions in %@", th: "ไม่มี session ใน%@")

    static let columnStarted = Phrase(en: "Started", th: "เริ่มเมื่อ")
    static let columnProject = Phrase(en: "Project", th: "โปรเจกต์")
    static let columnModel = Phrase(en: "Model", th: "โมเดล")
    static let columnDuration = Phrase(en: "Duration", th: "ระยะเวลา")
    static let columnTokens = Phrase(en: "Tokens", th: "Token")
    static let unavailable = Phrase(en: "unavailable", th: "ไม่มีข้อมูล")

    static let spokenStarted = Phrase(en: "Started %@.", th: "เริ่มเมื่อ %@")
    static let spokenRanFor = Phrase(en: "Ran for %@.", th: "ทำงานนาน %@")
    static let spokenTokens = Phrase(en: "%@ tokens.", th: "%@ token")
    static let spokenModel = Phrase(en: "Model %@.", th: "โมเดล %@")
    static let spokenModelUnavailable = Phrase(en: "Model unavailable.", th: "ไม่มีข้อมูลโมเดล")
}
