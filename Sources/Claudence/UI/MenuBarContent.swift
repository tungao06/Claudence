import SwiftUI
import ClaudenceCore

/// The popover. Fixed visual priority, never reordered: power meter, then
/// active sessions, then today's totals. See spec section 1.4.
struct MenuBarContent: View {
    let model: MonitorViewModel

    var body: some View {
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
        .padding(Theme.Layout.popoverPadding)
        .frame(width: Theme.Layout.popoverWidth)
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
                        burnHistory: rate.samples
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
            Spacer()
            Button("Quit Claudence") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.textTertiary)
            .keyboardShortcut("q")
        }
    }
}
