import SwiftUI
import ClaudenceCore

/// The popover. Fixed visual priority, never reordered: power meter, then
/// active sessions, then today's totals. See spec section 1.4.
///
/// The shell is banded rather than evenly padded, which is design section 3.3
/// read top to bottom: header, hero, secondary windows, rule, sessions header,
/// list, rule, today strip, footer strip. Two gutters do the work. Chrome and
/// the rules sit on 20 pt; the hero panel and the session cards sit inboard on
/// 14 pt, and that 6 pt inset is the whole reason a card reads as a card rather
/// than as another band of the popover. So the padding lives on the bands, not
/// on this view, and the only thing the outer frame owns is the width.
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
                // The detail is one panel rather than a set of bands, so it
                // keeps the single inset the list gave up.
                detail(session)
                    .padding(Theme.Layout.popoverPadding)
            } else {
                list
            }
        }
        // The list and the detail are not the same width, and forcing them to
        // be made the detail the cramped one. 420 pt is the list's design
        // width; the detail is a two-column layout, so at 420 each column got
        // 187 pt and every metric row, tool name and file path truncated. The
        // detail is one width everywhere now -- the same `sheetWidth` the
        // dashboard's window gives it -- so a reading that fits in one host
        // fits in the other.
        .frame(width: detailSession == nil ? Theme.Layout.popoverWidth : Theme.Layout.sheetWidth)
        // Because that width changes by 340 pt, and AppKit would leave the left
        // edge where it was and put all of it on the right.
        .background(PopoverAnchor().frame(width: 0, height: 0))
        .background(Theme.surface)
        // The cost in the today strip is priced from the database, which the
        // dashboard's aggregates already own, so it is pulled the same way the
        // dashboard pulls it rather than being recomputed here. Keyed on a
        // quantised token count: an unquantised total changes several times a
        // second while a session streams, and this reads SQLite. One read at
        // launch, then one per quarter-million tokens.
        .task(id: costRefreshKey) {
            model.refreshDashboard()
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            powerSection
            rule
            sessionsHeader
            sessionList
            rule.padding(.top, Theme.Popover.dividerTop)
            todayStrip
            if let warning = model.storeWarning {
                Text(warning)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Popover.gutter)
                    .padding(.bottom, Theme.Space.m)
            }
            footer
        }
    }

    /// How far today's token total has to move before the cost is repriced.
    private static let costRefreshQuantum = 250_000

    /// What has to change before today's cost is read again.
    ///
    /// This was `todayUsage.total / costRefreshQuantum` alone until 2026-09-03,
    /// and that number is stuck at zero for the whole of a new day when the
    /// rollups still file an overnight session under yesterday, and stuck at
    /// nothing whenever the aggregate fails. Either way the cost beside it
    /// never refreshed, because the key it was watching had nowhere to move.
    ///
    /// So the key carries three things that move for different reasons: the
    /// local day, which turns over at midnight whatever the store says; the
    /// live sessions' own tokens, which the engine accumulates in memory and
    /// which never depend on a query answering; and today's stored total, still
    /// quantised, when there is one.
    private var costRefreshKey: String {
        let live = model.sessions.reduce(0) { $0 + $1.combinedUsage.total }
        let stored = model.todayUsage.map { "\($0.total / MenuBarContent.costRefreshQuantum)" } ?? "-"
        return "\(ClaudenceStore.dayString(for: Date()))/\(live / MenuBarContent.costRefreshQuantum)/\(stored)"
    }

    /// The section rule. A `Divider` inside a leading-aligned stack sizes to
    /// its content rather than to the band, so the rule is drawn explicitly.
    private var rule: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 1)
            .padding(.horizontal, Theme.Popover.gutter)
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
            windowShare: model.windowShare(for: session),
            showsSubagents: preferences.showSubagents,
            onClose: { detailSessionID = nil }
        )
        // Subagent lists are pulled when a detail opens, not on every refresh:
        // reading them is cheap, publishing them into the view tree is not, and
        // nothing shows them until asked.
        .task(id: session.id) {
            await model.refreshSubagents(for: session.id)
            await model.refreshWindowShares()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Popover.headerMarkGap) {
            // The mark is the same gauge as the menu bar reading, at a size
            // that has room for its core dot. It carries the 5-hour window, so
            // the popover opens with the headline number stated twice, once as
            // a shape and once as a figure.
            RingMark(
                percentUsed: model.primaryWindow?.usedPercent,
                size: Theme.Bar.markHeader,
                showsCore: true
            )
            Text("CLAUDENCE")
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textPrimary)
            planBadge
            Spacer(minLength: Theme.Space.s)
            HStack(spacing: Theme.Popover.headerTrailingGap) {
                freshnessStamp
                refreshButton
            }
        }
        .padding(.horizontal, Theme.Popover.gutter)
        .padding(.top, Theme.Popover.headerTop)
        .padding(.bottom, Theme.Popover.headerBottom)
    }

    /// The subscription the limits below belong to.
    ///
    /// Beside the wordmark because it qualifies everything under it: the power
    /// meter states a percentage and never the size of the thing it is a
    /// percentage of, and 62% means four times as much work on Max 20x as on
    /// Max 5x. Reading the number without knowing the plan is reading a ratio
    /// with an unstated denominator.
    ///
    /// Drawn as a quiet pill rather than as another figure. It is context for
    /// the reading, not a reading of its own, and the popover's visual priority
    /// is fixed: power meter, then sessions, then everything else.
    ///
    /// Absent when Claude Code's account file is missing or names a tier this
    /// does not recognise. Nothing is guessed; see `AccountPlanReader`.
    @ViewBuilder
    private var planBadge: some View {
        if let plan = model.accountPlan {
            Text(plan.displayName)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.xs)
                .padding(.vertical, Theme.Space.xxs)
                .background(
                    Capsule(style: .continuous).fill(Theme.surfaceControl)
                )
                .fixedSize()
                .accessibilityLabel("Plan, \(plan.displayName)")
        }
    }

    /// How old the reading on screen is.
    ///
    /// The design puts it here and it is a real fact: `MonitorSnapshot` stamps
    /// `updatedAt` every time the engine publishes. It is worth having because
    /// every other number in the popover is undated, and a stale popover looks
    /// exactly like a fresh one with a quiet machine behind it.
    ///
    /// Wrapped in a `TimelineView` because the age has to move on its own. The
    /// alternative — computing it once per render — reports the age the
    /// snapshot had the last time something *else* invalidated this view, which
    /// on an idle machine is minutes ago and wrong in the one direction that
    /// matters. See `Theme.Popover.freshnessTick` for why a five-second period
    /// is not the repeating animation this file forbids.
    private var freshnessStamp: some View {
        Text(MenuBarContent.freshness(of: model.snapshot.updatedAt, at: Date()))
            .font(Theme.Typography.micro)
            .foregroundStyle(Theme.textQuaternary)
            .lineLimit(1)
    }

    /// `now`, `30s ago`, `34m ago`, `2h ago`. Rounded to the tick that drives
    /// it, so every recomputation changes the string and none is wasted.
    static func freshness(of stamp: Date, at now: Date) -> String {
        let age = now.timeIntervalSince(stamp)
        guard age >= Theme.Popover.freshnessTick else { return "now" }
        if age < 60 {
            let step = Theme.Popover.freshnessTick
            return "\(Int((age / step).rounded(.down) * step))s ago"
        }
        if age < 3_600 { return "\(Int(age / 60))m ago" }
        if age < 86_400 { return "\(Int(age / 3_600))h ago" }
        return "\(Int(age / 86_400))d ago"
    }

    /// The design's `\u{27F3}` chip: a 24 pt rounded square on the control
    /// surface, not a bare icon. It is the only button in the header now; the
    /// gear that used to sit beside it is chrome the design does not have, and
    /// Settings is reached from the footer strip where the design puts it.
    private var refreshButton: some View {
        Button {
            Task { await model.refreshUsageNow() }
        } label: {
            Text(Theme.Glyph.refresh)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: Theme.Popover.refreshButton, height: Theme.Popover.refreshButton)
                .background(
                    Theme.surfaceControl,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh usage")
    }

    // MARK: - Power

    @ViewBuilder
    private var powerSection: some View {
        if let reason = model.usageUnavailableReason {
            // Never a fabricated bar at some default fill. See spec section 9.4.
            UnavailableView("Usage unavailable", reason: reason)
                .padding(.horizontal, Theme.Popover.margin)
                .padding(.bottom, Theme.Popover.margin)
        } else {
            PowerHero(
                title: "Claude Power \u{00B7} 5h window",
                windowName: model.primaryWindow?.name ?? "five_hour",
                percentUsed: model.primaryWindow?.usedPercent,
                resetsAt: model.primaryWindow?.resetsAt
            )
            .padding(.horizontal, Theme.Popover.margin)
            .padding(.bottom, Theme.Popover.margin)
            secondaryWindows
        }
    }

    @ViewBuilder
    private var secondaryWindows: some View {
        // Nothing at all when the source reported neither: an empty band would
        // still cost a rule's worth of air for no reading.
        if model.weeklyWindow != nil || !model.scopedWindows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Popover.secondaryGap) {
                if let weekly = model.weeklyWindow {
                    PowerBar(
                        // Not `weekly.displayName`, which title-cases to
                        // `7 Day`. The design writes `7 day`, in the HTML and
                        // in the transcription both, and `displayName` is a
                        // core type this file does not own.
                        title: "7 day",
                        windowName: weekly.name,
                        percentUsed: weekly.usedPercent,
                        resetsAt: weekly.resetsAt
                    )
                }
                ForEach(model.scopedWindows) { window in
                    PowerBar(
                        title: window.displayName,
                        // The design captions a model-scoped window so its
                        // single-digit percentage is not read as a share of the
                        // 7-day cap above it. Same size and weight for every
                        // scoped window, because the caption describes the kind
                        // of window and not the model.
                        caption: "weekly scoped",
                        windowName: window.name,
                        percentUsed: window.usedPercent,
                        resetsAt: window.resetsAt,
                        height: Theme.Bar.row
                    )
                }
            }
            .padding(.horizontal, Theme.Popover.gutter)
            .padding(.top, Theme.Space.xxs)
            .padding(.bottom, Theme.Popover.secondaryBottom)
        }
    }

    // MARK: - Sessions

    private var sessionsHeader: some View {
        HStack {
            Text("ACTIVE SESSIONS")
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Text("\(model.sessions.count)")
                .font(Theme.Typography.countPill)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, Theme.Popover.countPillPaddingHorizontal)
                .padding(.vertical, Theme.Popover.countPillPaddingVertical)
                .background(Theme.surfaceControl, in: Capsule(style: .continuous))
        }
        .padding(.horizontal, Theme.Popover.gutter)
        .padding(.top, Theme.Popover.sessionsHeaderTop)
        .padding(.bottom, Theme.Popover.sessionsHeaderBottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Active sessions, \(model.sessions.count)")
    }

    @ViewBuilder
    private var sessionList: some View {
        Group {
            if model.sessions.isEmpty {
                // Zero sessions is an ordinary state, not an error.
                UnavailableView("No active sessions", compact: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Popover.listGap) {
                    ForEach(model.sessions) { session in
                        let rate = model.burnRate(for: session)
                        SessionRow(
                            session: session,
                            gitBranch: session.gitBranch,
                            tokenScaleMaximum: model.tokenScaleMaximum,
                            burnRatePerMinute: rate.tokensPerMinute > 0 ? rate.tokensPerMinute : nil,
                            burnHistory: rate.samples,
                            isCompact: preferences.compactRows,
                            onOpen: { detailSessionID = session.id }
                        )
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Popover.margin)
        .padding(.bottom, Theme.Popover.listBottom)
    }

    // MARK: - Today

    /// `Today  10.7M  tokens \u{00B7} $3.42 est.` on the left, `Dashboard
    /// \u{2192}` on the right, exactly as the design draws it.
    ///
    /// The cost used to be omitted here, on the argument that it was assembled
    /// for the dashboard and stale until that window had been opened. That was
    /// a wiring problem, not a data problem: `AnalyticsService.todayCost()`
    /// prices today's sessions against `ModelPricing.current` and reports what
    /// it could not price, and the list now pulls it on a quantised schedule.
    ///
    /// Three rules ride on the figure and all three are load-bearing. It always
    /// carries `est.`, because it is a model of a bill and not a bill. It is
    /// never a number the price table could not produce: a session whose model
    /// is missing from the table makes `estimatedDollars` nil and this renders
    /// `cost unavailable`, never a zero and never an average. And when only
    /// some sessions are unpriced, the figure is a floor, so the strip says so.
    private var todayStrip: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Popover.todayGap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Popover.todayGap) {
                Text("Today")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textTertiary)
                if let usage = model.todayUsage {
                    Text(Format.tokens(usage.total))
                        .font(Theme.Typography.stripValue)
                        .foregroundStyle(Theme.textPrimary)
                    Text(costLine)
                        .font(Theme.Typography.help)
                        .foregroundStyle(Theme.textQuaternary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    // The aggregate behind this figure did not answer. A zero
                    // here would be a measurement, and the cost beside it would
                    // be a second one derived from the first.
                    UnavailableView("Token usage unavailable", compact: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenToday)
            Spacer(minLength: Theme.Space.s)
            Button {
                openDashboard()
            } label: {
                Text("Dashboard \(Theme.Glyph.arrowRight)")
                    .font(Theme.Typography.labelEmphasis)
                    .foregroundStyle(Theme.accentDeep)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the Claudence dashboard")
        }
        .padding(.horizontal, Theme.Popover.gutter)
        .padding(.vertical, Theme.Popover.todayStrip)
        .accessibilityElement(children: .contain)
    }

    /// The whole today strip, spoken.
    private var spokenToday: String {
        guard let usage = model.todayUsage else {
            return "Today, token usage unavailable"
        }
        return "Today, \(Format.tokens(usage.total)) tokens. \(spokenCost)"
    }

    /// The trailing half of the today strip: `tokens \u{00B7} $3.42 est.`, or
    /// the honest gap in place of the figure.
    private var costLine: String {
        guard let cost = model.dashboard.todayCost else {
            return "tokens \u{00B7} cost unavailable"
        }
        let unpriced = model.dashboard.unpricedSessionCount
        guard unpriced > 0 else {
            return "tokens \u{00B7} \(Format.cost(cost)) est."
        }
        // A partial estimate is a lower bound, and saying only "est." would let
        // it read as the whole day's cost.
        let sessions = unpriced == 1 ? "1 session" : "\(unpriced) sessions"
        return "tokens \u{00B7} \(Format.cost(cost))+ est., \(sessions) unpriced"
    }

    private var spokenCost: String {
        guard let cost = model.dashboard.todayCost else {
            return "Estimated cost unavailable: no price is known for one of today's models."
        }
        let unpriced = model.dashboard.unpricedSessionCount
        guard unpriced > 0 else {
            return "Estimated cost today, \(Format.cost(cost)). This is an estimate, not a bill."
        }
        let sessions = unpriced == 1 ? "1 session" : "\(unpriced) sessions"
        return "Estimated cost today, at least \(Format.cost(cost)); "
            + "\(sessions) could not be priced. This is an estimate, not a bill."
    }

    // MARK: - Footer

    /// The design's second strip: `Settings \u{00B7} Privacy` on the left,
    /// `Quit Claudence` on the right, on its own recessed ground.
    ///
    /// This is where Settings lives now. It used to be a gear in the header,
    /// which the design does not have; the design spends its header on the
    /// mark, the wordmark, the freshness stamp and one refresh chip, and puts
    /// the two links that leave the popover down here where a person looks
    /// after they have finished reading.
    ///
    /// `Privacy` opens the same window as `Settings`, because the privacy
    /// disclosure is a section of that window rather than a tab of its own. The
    /// two are still separate links: the design names Privacy where a reader
    /// will look for it, and a link that lands one scroll away is a better
    /// answer than no link.
    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                footerLink("Settings", hint: "Opens Claudence settings")
                Text(Theme.Glyph.separator)
                    .font(Theme.Typography.help)
                    .foregroundStyle(Theme.textQuaternary)
                    .accessibilityHidden(true)
                footerLink("Privacy", hint: "Opens the privacy disclosure in Claudence settings")
            }

            Spacer(minLength: Theme.Space.m)

            Button("Quit Claudence") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.help)
            .foregroundStyle(Theme.textQuaternary)
            .keyboardShortcut("q")
            .accessibilityLabel("Quit Claudence")
        }
        .padding(.horizontal, Theme.Popover.gutter)
        .padding(.top, Theme.Popover.footerTop)
        .padding(.bottom, Theme.Popover.footerBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceFooter)
        // The design rules this strip off across the full width rather than
        // inside the 20 pt gutter the other dividers sit in, because the strip
        // has its own ground and the rule is the edge of that ground.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 1)
        }
    }

    private func footerLink(_ title: String, hint: String) -> some View {
        Button(title) {
            dismissMenuBarPopover()
            openSettings()
            // An accessory app does not come forward on its own, so the
            // settings window would open behind the frontmost app.
            presentWindow(
                sceneIdentifier: "com_apple_SwiftUI_Settings_window",
                title: "Claudence Settings"
            )
        }
        .buttonStyle(.plain)
        .font(Theme.Typography.help)
        .foregroundStyle(Theme.textQuaternary)
        .accessibilityHint(hint)
    }

    private func openDashboard() {
        dismissMenuBarPopover()
        model.refreshDashboard()
        openWindow(id: DashboardWindow.id)
        presentWindow(
            sceneIdentifier: DashboardWindow.id,
            title: "Claudence Dashboard"
        )
    }
}
