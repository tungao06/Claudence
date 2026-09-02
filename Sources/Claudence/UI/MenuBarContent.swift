import SwiftUI
import ClaudenceCore

/// The popover. Fixed visual priority, never reordered: power meter, then
/// active sessions, then today's totals. See spec section 1.4.
struct MenuBarContent: View {
    let model: MonitorViewModel
    /// Settings the popover honours: `Compact rows` and `Show subagents`. Held
    /// as the object rather than as loose flags so a new setting does not
    /// change this view's signature, and read at the point of use so only the
    /// part of the tree that depends on a value is invalidated when it moves.
    let preferences: Preferences

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Which session's detail is open, held as an id rather than as a value.
    /// A stored `AISession` would freeze at the moment it was tapped and stop
    /// following the snapshots the engine keeps pushing, so the detail would
    /// quietly show stale tokens for as long as it stayed open.
    @State private var detailSessionID: String?

    /// The open session, or nil when nothing is open or when the session it
    /// pointed at has ended. A session that ends while its detail is open
    /// returns the popover to the list rather than stranding a dead view.
    private var detailSession: AISession? {
        guard let detailSessionID else { return nil }
        return model.sessions.first { $0.id == detailSessionID }
    }

    var body: some View {
        Group {
            if let session = detailSession {
                detail(session)
            } else {
                list
            }
        }
        .padding(Theme.Layout.popoverPadding)
        .frame(width: Theme.Layout.popoverWidth)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            header
            powerSection
            Divider().overlay(Theme.separator)
            sessionSection
            Divider().overlay(Theme.separator)
            todaySection
            if let warning = model.storeWarning {
                Text(warning)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            footer
        }
    }

    /// The detail replaces the popover's content rather than floating over it.
    /// A sheet inside a `MenuBarExtra(style: .window)` popover is a second
    /// window over something that is not an ordinary window, and this content
    /// stays mounted after dismissal, so the cheapest correct presentation is
    /// the one that adds no layer at all.
    private func detail(_ session: AISession) -> some View {
        let rate = model.burnRate(for: session)
        return SessionDetailView(
            session: session,
            subagents: model.subagents(for: session),
            tokenScaleMaximum: model.tokenScaleMaximum,
            burnRatePerMinute: rate.tokensPerMinute > 0 ? rate.tokensPerMinute : nil,
            burnHistory: rate.samples,
            windowShare: model.recentShare(for: session),
            showsSubagents: preferences.showSubagents,
            onClose: { detailSessionID = nil }
        )
        // Subagent lists are pulled when a detail opens, not on every refresh:
        // reading them is cheap, publishing them into the view tree is not, and
        // nothing shows them until asked.
        .task(id: session.id) {
            await model.refreshSubagents(for: session.id)
            await model.refreshRecentShares()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("CLAUDENCE")
                .font(Theme.Typography.section)
                .tracking(1.2)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button {
                Task { await model.refreshUsageNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .accessibilityLabel("Refresh usage")

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .accessibilityLabel("Open settings")
        }
    }

    // MARK: - Power

    @ViewBuilder
    private var powerSection: some View {
        if let reason = model.usageUnavailableReason {
            // Never a fabricated bar at some default fill. See spec section 9.4.
            UnavailableView("Usage unavailable", reason: reason)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                PowerBar(
                    title: "Claude Power",
                    percentUsed: model.primaryWindow?.usedPercent,
                    resetsAt: model.primaryWindow?.resetsAt
                )
                if let weekly = model.weeklyWindow {
                    PowerBar(
                        title: weekly.displayName,
                        percentUsed: weekly.usedPercent,
                        resetsAt: weekly.resetsAt,
                        height: Theme.Bar.row
                    )
                }
                ForEach(model.scopedWindows) { window in
                    PowerBar(
                        title: window.displayName,
                        percentUsed: window.usedPercent,
                        resetsAt: window.resetsAt,
                        height: Theme.Bar.micro
                    )
                }
            }
        }
    }

    // MARK: - Sessions

    @ViewBuilder
    private var sessionSection: some View {
        HStack {
            Text("ACTIVE SESSIONS")
                .font(Theme.Typography.section)
                .tracking(1.0)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(model.sessions.count)")
                .font(Theme.Typography.section)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
        }

        if model.sessions.isEmpty {
            // Zero sessions is an ordinary state, not an error.
            UnavailableView("No active sessions", compact: true)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                ForEach(model.sessions) { session in
                    let rate = model.burnRate(for: session)
                    SessionRow(
                        session: session,
                        tokenScaleMaximum: model.tokenScaleMaximum,
                        burnRatePerMinute: rate.tokensPerMinute > 0 ? rate.tokensPerMinute : nil,
                        burnHistory: rate.samples,
                        isCompact: preferences.compactRows,
                        isLive: preferences.liveIndicators,
                        onOpen: { detailSessionID = session.id }
                    )
                }
            }
        }
    }

    // MARK: - Today

    private var todaySection: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Today")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(Format.tokens(model.todayUsage.total)) tokens")
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today, \(Format.tokens(model.todayUsage.total)) tokens")
    }

    private var footer: some View {
        HStack {
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.textTertiary)
            .keyboardShortcut("q")
            .accessibilityLabel("Quit Claudence")

            Spacer()

            // The popover is deliberately compact; anything that needs room
            // lives in the dashboard. See spec section 1.4 for the ordering
            // this footer is the exit from.
            Button {
                model.refreshDashboard()
                openWindow(id: DashboardWindow.id)
            } label: {
                HStack(spacing: Theme.Space.xxs) {
                    Text("Open Dashboard")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Open the Claudence dashboard")
        }
    }
}
