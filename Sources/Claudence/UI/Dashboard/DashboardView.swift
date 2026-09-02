import SwiftUI
import ClaudenceCore

/// Which window the hero ring is showing.
enum DashboardRingWindow: String, CaseIterable, Identifiable, Sendable {
    case fiveHour
    case sevenDay

    var id: String { rawValue }

    /// Compact segment text, matching spec section 7.3's `5h | 7d`.
    var segmentTitle: String {
        switch self {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }

    var spokenTitle: String {
        switch self {
        case .fiveHour: return "five hour window"
        case .sevenDay: return "seven day window"
        }
    }

    var counterpart: DashboardRingWindow {
        self == .fiveHour ? .sevenDay : .fiveHour
    }
}

/// The dashboard window: the same reading as the popover, with room to explain
/// itself.
///
/// The section order is the product's fixed visual priority and is never
/// reordered (spec sections 1.4 and 7.3):
///
///     global usage -> active sessions -> today -> usage over time
///                  -> projects -> history
///
/// Analytics never climbs above sessions, and sessions never climb above the
/// meter, however interesting the analytics happen to be.
///
/// The view is pure. It takes one `DashboardData`, holds only its own selection
/// state, and touches no file, process or network.
struct DashboardView: View {
    let data: DashboardData
    /// Reference time for every relative label on the window.
    let now: Date

    @State private var ringWindow: DashboardRingWindow = .fiveHour

    init(data: DashboardData, now: Date = Date()) {
        self.data = data
        self.now = now
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                globalUsageSection
                sectionBreak
                sessionsSection
                sectionBreak
                todaySection
                sectionBreak
                chartSection
                sectionBreak
                projectsSection
                sectionBreak
                historySection
            }
            .padding(DashboardMetrics.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(
            minWidth: DashboardMetrics.minimumWidth,
            idealWidth: DashboardMetrics.windowWidth,
            minHeight: DashboardMetrics.minimumHeight,
            idealHeight: DashboardMetrics.windowHeight
        )
    }

    private var sectionBreak: some View {
        Divider().overlay(Theme.separator)
    }

    // MARK: - Section chrome

    private func sectionHeader(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.m)
            if let trailing {
                Text(trailing)
                    .font(Theme.Typography.section)
                    .tracking(Theme.sectionTracking)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - 1. Global usage
    //
    // The hero. The ring carries whichever window the segmented control
    // selects; the counterpart window keeps a full-height bar beside it, so
    // both primary windows are always on screen and the control only decides
    // which one gets the large reading. Model-scoped weekly caps sit below at
    // row height, in the order the source returned them.

    @ViewBuilder
    private var globalUsageSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            sectionHeader("Global usage")
            if let reason = data.usageUnavailableReason {
                // Never a fabricated meter at some default fill.
                UnavailableView("Usage unavailable", reason: reason)
            } else {
                HStack(alignment: .top, spacing: Theme.Space.xl) {
                    ringColumn
                    barColumn
                }
            }
        }
    }

    private var ringColumn: some View {
        VStack(spacing: Theme.Space.m) {
            Picker("Usage window", selection: $ringWindow) {
                ForEach(DashboardRingWindow.allCases) { option in
                    Text(option.segmentTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: DashboardMetrics.heroRingSize)
            .accessibilityLabel("Usage window shown in the ring")
            .accessibilityValue(ringWindow.spokenTitle)

            EnergyRing(
                title: window(for: ringWindow).displayName,
                percentUsed: window(for: ringWindow).usedPercent,
                resetsAt: window(for: ringWindow).resetsAt,
                size: DashboardMetrics.heroRingSize,
                stroke: DashboardMetrics.heroRingStroke
            )
        }
        .frame(width: DashboardMetrics.heroRingSize)
    }

    private var barColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            let other = window(for: ringWindow.counterpart)
            PowerBar(
                title: other.displayName,
                percentUsed: other.usedPercent,
                resetsAt: other.resetsAt
            )
            if data.scopedWindows.isEmpty {
                // The API returned no model-scoped caps. Absence of a cap is
                // not a cap at zero, so nothing is drawn for it.
                Text("No model-scoped weekly caps reported.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(data.scopedWindows) { scoped in
                    PowerBar(
                        title: scoped.displayName,
                        percentUsed: scoped.usedPercent,
                        resetsAt: scoped.resetsAt,
                        height: Theme.Bar.row
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func window(for selection: DashboardRingWindow) -> UsageWindow {
        switch selection {
        case .fiveHour: return data.fiveHourWindow
        case .sevenDay: return data.sevenDayWindow
        }
    }

    // MARK: - 2. Active sessions
    //
    // Two columns at 336 pt each, wider than the 300 pt a `SessionRow` was
    // designed against, so nothing in the row has to reflow.

    private var sessionColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: DashboardMetrics.sessionColumnSpacing, alignment: .top),
            GridItem(.flexible(), spacing: DashboardMetrics.sessionColumnSpacing, alignment: .top),
        ]
    }

    @ViewBuilder
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            sectionHeader("Active sessions", trailing: "\(data.sessions.count)")
            if data.sessions.isEmpty {
                // Zero sessions is an ordinary state, not an error.
                UnavailableView(
                    "No active sessions",
                    reason: "Claude Code is not running, or no session is interactive"
                )
            } else {
                LazyVGrid(
                    columns: sessionColumns,
                    alignment: .leading,
                    spacing: Theme.Space.xl
                ) {
                    ForEach(data.sessions) { session in
                        let burn = data.burn(for: session)
                        SessionRow(
                            session: session,
                            tokenScaleMaximum: data.tokenScaleMaximum,
                            burnRatePerMinute: burn.tokensPerMinute,
                            burnHistory: burn.samples
                        )
                    }
                }
            }
        }
    }

    // MARK: - 3. Today
    //
    // Tokens and an estimate. The estimate is labelled as one everywhere it
    // appears, and when any session had no price the count says so in words.
    // Nothing on this window is a billing amount. See spec section 9.2.

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            sectionHeader("Today")
            HStack(alignment: .top, spacing: Theme.Space.l) {
                tokensTile
                costTile
            }
            // Reuses the popover's breakdown: no scale maximum, so it shows the
            // value and the cache split without drawing a ratio it cannot back.
            TokenBar(usage: data.todayUsage, unavailableMessage: "Token usage unavailable")
        }
    }

    private var tokensTile: some View {
        tile(title: "Tokens") {
            if let usage = data.todayUsage {
                Text(Format.tokens(usage.total))
                    .font(Theme.Typography.hero)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("across all projects")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                UnavailableView("Token usage unavailable", compact: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            data.todayUsage.map { "Today, \(Format.tokens($0.total)) tokens across all projects." }
                ?? "Today, token usage unavailable."
        )
    }

    private var costTile: some View {
        tile(title: "Estimated cost") {
            if let cost = data.todayCost {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                    Text(Format.cost(cost))
                        .font(Theme.Typography.hero)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    // The word travels with the number, always.
                    Text("estimated")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(costCaption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                UnavailableView(
                    "Cost unavailable",
                    reason: unpricedReason ?? "No price is known for one of today's models",
                    compact: false
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenCost)
    }

    private var unpricedReason: String? {
        guard data.unpricedSessionCount > 0 else { return nil }
        return data.unpricedSessionCount == 1
            ? "1 session has no price for its model"
            : "\(data.unpricedSessionCount) sessions have no price for their model"
    }

    private var costCaption: String {
        guard data.unpricedSessionCount > 0 else { return "Estimated, all sessions priced" }
        return data.unpricedSessionCount == 1
            ? "Estimated, 1 session unpriced"
            : "Estimated, \(data.unpricedSessionCount) sessions unpriced"
    }

    private var spokenCost: String {
        guard let cost = data.todayCost else {
            return "Estimated cost unavailable. "
                + (unpricedReason ?? "No price is known for one of today's models") + "."
        }
        return "Estimated cost today, \(Format.cost(cost)). \(costCaption). "
            + "This is an estimate, not a billing amount."
    }

    private func tile<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title.uppercased())
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textTertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: DashboardMetrics.chartGridStroke)
        )
    }

    // MARK: - 4. Usage over time

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            sectionHeader("Usage over time")
            UsageChart(
                points: data.series,
                outputTokens: data.seriesOutput,
                title: "Usage over time",
                unavailableMessage: "No usage history",
                unavailableReason: data.seriesUnavailableReason
            )
        }
    }

    // MARK: - 5. Projects

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            sectionHeader("Projects", trailing: "\(data.projects.count)")
            ProjectBreakdownView(rows: data.projects, now: now)
        }
    }

    // MARK: - 6. History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            sectionHeader("History")
            SessionHistoryView(rows: data.history, now: now)
        }
    }
}
