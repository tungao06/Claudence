import SwiftUI
import ClaudenceCore

/// An uppercase section header. Small enough to live here rather than earn its
/// own file, and shared so the tracking is set once.
struct SectionEyebrow: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(Theme.Typography.section)
            .tracking(Theme.sectionTracking)
            .foregroundStyle(Theme.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Everything Claudence knows about one session, in one scroll.
///
/// The row above it answers "what is running and how much has it spent". This
/// answers "where did that go", and the section it exists for is the subagent
/// split: `usage` is the parent transcript, `subagentUsage` is every subagent
/// it spawned, and only `combinedUsage` is what the session actually cost.
/// Measured on this repository, the split was 41% of the true total, so a
/// detail view that showed only the parent figure would be wrong by more than a
/// third while looking precise.
///
/// The overlay lives inside the popover rather than in a sheet or a window. A
/// `MenuBarExtra(style: .window)` popover is not an ordinary window, its content
/// stays mounted after dismissal, and every extra layer of presentation is
/// another thing holding state while nothing is on screen. Swapping the
/// popover's content costs nothing when closed.
///
/// Nothing here is animated. The design fills every bar from zero on open and
/// draws the sparkline in; both would be one-shot and therefore permissible, but
/// this view is rebuilt on every snapshot the engine pushes, so "on open" is not
/// a moment SwiftUI can distinguish from "on update" without holding a flag that
/// would then be wrong.
struct SessionDetailView: View {

    let session: AISession
    let subagents: [AISubagent]
    /// Shared denominator for the energy bar, so its length means the same
    /// thing here as it does in the list. Nil draws no bar.
    let tokenScaleMaximum: Int?
    let burnRatePerMinute: Double?
    let burnHistory: [Double]
    /// This session's share of the tokens Claudence measured over the recent
    /// window, from `AnalyticsService.shareOfRecentTokens`. Nil is unavailable,
    /// and it is nil by default because the figure reads the database and a
    /// view must not.
    let windowShare: Double?
    /// The design's `Show subagents` setting. False omits the list entirely
    /// rather than rendering it empty, because "no subagents spawned" would be
    /// a claim about the session when it is only a claim about the setting. The
    /// token split above it stays either way: those figures are accounting, not
    /// a list, and hiding them would make the headline total unexplained.
    let showsSubagents: Bool
    let costEstimator: CostEstimator
    let contextWindows: ContextWindowTable
    /// Rendering clock, so previews and tests do not drift.
    let now: Date
    /// The quick actions' side effects. Injectable for the same reason
    /// `SessionActions` stores them as closures at all: a preview that embedded
    /// `.system` would carry live buttons that open Terminal and signal a real
    /// process, and a preview is not a place to discover that.
    let actions: SessionActions
    let onClose: () -> Void

    init(
        session: AISession,
        subagents: [AISubagent] = [],
        tokenScaleMaximum: Int? = nil,
        burnRatePerMinute: Double? = nil,
        burnHistory: [Double] = [],
        windowShare: Double? = nil,
        showsSubagents: Bool = true,
        costEstimator: CostEstimator = CostEstimator(),
        contextWindows: ContextWindowTable = .current,
        now: Date = Date(),
        actions: SessionActions = .system,
        onClose: @escaping () -> Void
    ) {
        self.session = session
        self.subagents = subagents
        self.tokenScaleMaximum = tokenScaleMaximum
        self.burnRatePerMinute = burnRatePerMinute
        self.burnHistory = burnHistory
        self.windowShare = windowShare
        self.showsSubagents = showsSubagents
        self.costEstimator = costEstimator
        self.contextWindows = contextWindows
        self.now = now
        self.actions = actions
        self.onClose = onClose
    }

    /// How tall the detail may grow before it scrolls. The design's sheet takes
    /// 88% of the viewport; a popover has no viewport, so this is a fixed cap
    /// chosen to leave the menu bar and the screen edge alone.
    static let maximumHeight: CGFloat = 520

    private var identity: Theme.SessionIdentity { Theme.identity(forSessionID: session.id) }
    private var total: TokenUsage { session.combinedUsage }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                QuickActionsMenu(session: session, actions: actions)
                energyPanel
                breakdownSection
                subagentSplit
                contextSection
                costSection
                toolMixSection
                filesSection
                ActivityTimelineView(trail: session.activityTrail, now: now)
                SessionFactsView(session: session, now: now)
                if showsSubagents {
                    SubagentListView(subagents: subagents, parentTotal: total.total)
                }
            }
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.maximumHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session detail for \(session.projectName)")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                StatusIndicator(
                    session.status,
                    showsText: false,
                    activityToken: session.lastActivityAt
                )
                Text(session.projectName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Space.xs)
                // The status word carries the state; the dot only decorates it.
                Text(Theme.name(for: session.status))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(identity.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .tooltip(tip: "status")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close session detail")
                .keyboardShortcut(.escape, modifiers: [])
            }

            Text(session.displayPath)
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel("Working directory \(session.displayPath)")

            if let activity = session.currentActivity {
                Text(activity.display)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tooltip(tip: "activity")
                    .accessibilityLabel("Activity, \(activity.display)")
            } else {
                UnavailableView("Activity unavailable", compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Energy

    private var energyPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Token energy")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.textSecondary)
                    Text(Format.tokens(total.total))
                        .font(Theme.Typography.statValue)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .tooltip(tip: "energy")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Token energy, \(Format.tokens(total.total)) tokens")

                Spacer(minLength: Theme.Space.s)

                VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                    Text("Burn rate")
                        .font(Theme.Typography.label)
                        .foregroundStyle(Theme.textSecondary)
                    if let rate = burnRatePerMinute {
                        Text("\(Format.tokens(Int(rate.rounded())))/min")
                            .font(Theme.Typography.value)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text("Unavailable")
                            .font(Theme.Typography.value)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if Sparkline.canRender(burnHistory) {
                        Sparkline(burnHistory, label: "Token rate")
                            .frame(width: Theme.Bar.sparklineWidth)
                    }
                }
                .tooltip(tip: "burn")
            }

            if let fraction = energyFraction {
                energyBar(fraction)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRecessed, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    /// Nil when there is no scale to measure against. A bar without a
    /// denominator is a ratio nobody can defend.
    private var energyFraction: Double? {
        guard let tokenScaleMaximum, tokenScaleMaximum > 0 else { return nil }
        return min(1, max(0, Double(total.total) / Double(tokenScaleMaximum)))
    }

    private func energyBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(identity.track)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [identity.lightStop, identity.dot],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // The floor keeps a live but tiny reading visible. It is
                    // applied only above zero: a session that has spent nothing
                    // draws nothing, because a sliver would be a fill nobody
                    // measured.
                    .frame(
                        width: fraction <= 0
                            ? 0
                            : max(Theme.Bar.minimumVisibleFill, fraction) * geo.size.width
                    )
            }
        }
        .frame(height: Theme.Bar.row)
        .accessibilityHidden(true)
    }

    // MARK: - Breakdown

    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("TOKEN BREAKDOWN")
            ForEach(Theme.TokenCategory.allCases, id: \.self) { category in
                breakdownRow(category)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cache read and cache write keep their own rows for the whole life of
    /// this view. A cache read costs roughly a tenth of a fresh input token, so
    /// folding the three into one "input" figure would make the display
    /// disagree with the bill by an order of magnitude on the cheap part.
    private func value(for category: Theme.TokenCategory) -> Int {
        switch category {
        case .freshInput: return total.freshInput
        case .cacheWrite: return total.cacheCreation
        case .cacheRead: return total.cacheRead
        case .output: return total.output
        }
    }

    private func breakdownRow(_ category: Theme.TokenCategory) -> some View {
        let amount = value(for: category)
        let fraction = total.total > 0 ? Double(amount) / Double(total.total) : nil
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.color(for: category))
                    .frame(width: Theme.Bar.micro, height: Theme.Bar.micro)
                Text(category.label)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                if category == .output, total.thinking > 0 {
                    Text("(\(Format.tokens(total.thinking)) thinking)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textQuaternary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.s)
                Text(Format.tokens(amount))
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(Theme.track)
                        Capsule(style: .continuous)
                            .fill(Theme.color(for: category))
                            .frame(width: fraction * geo.size.width)
                    }
                }
                .frame(height: Theme.Bar.micro)
            }
        }
        .tooltip(breakdown: category.label, value: amount, of: total.total)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(breakdownLabel(category, amount: amount, fraction: fraction))
    }

    private func breakdownLabel(
        _ category: Theme.TokenCategory,
        amount: Int,
        fraction: Double?
    ) -> String {
        var text = "\(category.label), \(Format.tokens(amount)) tokens"
        if let fraction { text += ", \(Format.percent(fraction * 100)) of the session total" }
        return text
    }

    // MARK: - Subagent split

    /// The point of the whole panel. `usage` alone reads as the session's cost
    /// and is not: on this repository the subagents were 41% of the true total.
    private var subagentSplit: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionEyebrow("WHERE THE TOKENS WENT")
            splitRow("This session", session.usage.total)
            splitRow(
                session.subagentCount == 1 ? "1 subagent" : "\(session.subagentCount) subagents",
                session.subagentUsage.total
            )
            Divider().overlay(Theme.separator)
            splitRow("Combined", total.total, emphasised: true)
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    private func splitRow(_ name: String, _ amount: Int, emphasised: Bool = false) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(name)
                .font(emphasised ? Theme.Typography.label : Theme.Typography.body)
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.s)
            Text(Format.tokens(amount))
                .font(Theme.Typography.numeric)
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(Format.tokens(amount)) tokens")
    }

    // MARK: - Context window

    /// Always unavailable in this build, and for a reason worth stating rather
    /// than hiding.
    ///
    /// A context window bounds ONE request's input. `AISession.usage` is a
    /// running total across every request the session ever made, which on a long
    /// session is an order of magnitude past any published limit; dividing it by
    /// a limit yields a percentage in the thousands that looks like a
    /// measurement and is not one. `ContextWindowTable` says so at length and
    /// deliberately offers no `AISession` overload.
    ///
    /// So the numerator here is `session.lastRequestUsage`, the newest single
    /// record's own usage block, which the reader now keeps beside the running
    /// sum for exactly this. Two things can still be missing, and they are
    /// reported as different reasons rather than as one blank: the model may not
    /// be in our table, or no record with a usage block has been read yet.
    ///
    /// The reading is labelled Estimated because the limit is our table's claim,
    /// not something the transcript said. See PLAN-UI decision 1.
    @ViewBuilder
    private var contextSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionEyebrow("CONTEXT WINDOW")
            if let fraction = contextFraction, let window = contextWindows.window(for: session.model) {
                contextMeter(fraction: fraction, window: window)
            } else {
                UnavailableView("Context window unavailable", reason: contextReason)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceInset, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
    }

    /// Fraction of the model's context window the newest request occupied. Nil
    /// whenever either half is missing, never a substituted zero.
    private var contextFraction: Double? {
        guard let request = session.lastRequestUsage else { return nil }
        return contextWindows.fractionUsed(requestUsage: request, model: session.model)
    }

    private func contextMeter(fraction: Double, window: ModelContextWindow) -> some View {
        let percent = fraction * 100
        let severity = Constants.ContextThreshold.severity(forPercent: percent)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text(Format.percent(percent))
                    .font(Theme.Typography.value)
                    .foregroundStyle(Theme.textPrimary)
                Text("used")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
                Spacer(minLength: Theme.Space.xs)
                // Glyph and word together: severity is never colour alone.
                Image(systemName: Theme.glyph(for: severity))
                    .font(.system(size: Theme.Bar.severityGlyph))
                    .foregroundStyle(Theme.color(for: severity))
                Text(Theme.name(for: severity).capitalized)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(Theme.color(for: severity))
                        .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                }
            }
            .frame(height: Theme.Bar.row)
            Text("\(Format.tokens(session.lastRequestUsage?.billableInput ?? 0)) of \(Format.tokens(window.maximumInputTokens)) \u{00B7} Estimated")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textQuaternary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Context window, estimated \(Format.percent(percent)) used, \(Theme.name(for: severity)). "
            + "The limit comes from Claudence's own model table, not from the transcript."
        )
    }

    private var contextReason: String {
        guard contextWindows.covers(session.model) else {
            return "This model is not in the context-limit table, and a guessed limit is worse than none"
        }
        return "No request with a usage block has been read yet"
    }

    // MARK: - Cost and efficiency

    private var costSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("COST & EFFICIENCY")

            metricRow(
                "Estimated cost",
                value: estimatedCost.map(Format.cost),
                tip: "cost",
                unavailable: "Cost unavailable",
                estimated: true
            )
            metricRow(
                "Input served from cache",
                value: session.cacheServedFraction.map { Format.percent($0 * 100) },
                tip: "cr",
                unavailable: "Unavailable"
            )
            metricRow(
                "Tokens per hour",
                value: session.tokensPerHour(now: now).map { "\(Format.tokens(Int($0.rounded())))/h" },
                tip: "burn",
                unavailable: "Unavailable"
            )
            metricRow(
                "Share of the 5h window",
                value: windowShare.map { Format.percent($0 * 100) },
                tip: nil,
                unavailable: "Unavailable"
            )

            Text("Cost is estimated from a per-model price table, never a billed amount.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var estimatedCost: Double? {
        costEstimator.estimate(usage: total, model: session.model)
    }

    /// One label and one value. `estimated` adds the word the spec requires on
    /// every derived money figure, and it is a word rather than a colour or an
    /// icon so it survives being read aloud.
    private func metricRow(
        _ name: String,
        value: String?,
        tip: String?,
        unavailable: String,
        estimated: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(name)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if estimated, value != nil {
                Text("Estimated")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.vertical, Theme.Space.xxs)
                    .background(
                        Capsule(style: .continuous).fill(Theme.surfaceControl)
                    )
            }
            Spacer(minLength: Theme.Space.s)
            Text(value ?? unavailable)
                .font(Theme.Typography.numeric)
                .foregroundStyle(value == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
        }
        .tooltip(tip.flatMap(TooltipText.tip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metricLabel(name, value: value, unavailable: unavailable, estimated: estimated))
    }

    private func metricLabel(
        _ name: String,
        value: String?,
        unavailable: String,
        estimated: Bool
    ) -> String {
        guard let value else { return "\(name), \(unavailable.lowercased())" }
        return estimated ? "\(name), \(value), estimated" : "\(name), \(value)"
    }

    // MARK: - Tool mix

    /// Counts by tool name, and nothing about what the tool was given. A Bash
    /// call contributes one to `Bash` and nothing else, because command strings
    /// routinely carry API keys and connection strings.
    private var toolMixSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("TOOL MIX")
            let mix = Array(session.toolMix.prefix(6))
            if mix.isEmpty {
                UnavailableView("No tool calls recorded yet", compact: true)
            } else {
                let peak = mix.first?.count ?? 0
                ForEach(Array(mix.enumerated()), id: \.element.name) { index, entry in
                    toolRow(entry.name, count: entry.count, peak: peak, index: index)
                }
            }
            Text("Counted by tool name only. Arguments are never read.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toolRow(_ name: String, count: Int, peak: Int, index: Int) -> some View {
        // The design cycles the four category colours through the tool bars.
        // They carry no meaning here beyond telling one row from the next.
        let palette = Theme.TokenCategory.allCases
        let colour = Theme.color(for: palette[index % palette.count])
        let fraction = peak > 0 ? Double(count) / Double(peak) : 0
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(name)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.s)
                Text("\(count)")
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(Theme.track)
                    Capsule(style: .continuous)
                        .fill(colour)
                        .frame(width: fraction * geo.size.width)
                }
            }
            .frame(height: Theme.Bar.micro)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count) calls")
    }

    // MARK: - Files touched

    /// File paths are on the allowlist; file contents are not, and nothing here
    /// opens a file. The chip shows the name and the full path is available to
    /// the pointer and to a screen reader.
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("FILES TOUCHED")
            if session.filePaths.isEmpty {
                UnavailableView("No files touched yet", compact: true)
            } else {
                FlowLayout(spacing: Theme.Space.s) {
                    ForEach(session.filePaths, id: \.self) { path in
                        fileChip(path)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileChip(_ path: String) -> some View {
        Text((path as NSString).lastPathComponent)
            .font(Theme.Typography.numeric)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.surfaceInset)
            )
            .help(path)
            .accessibilityLabel("File \(path)")
    }
}

// MARK: - Flow layout

/// Wrapping chips, laid out left to right.
///
/// `LazyVGrid` cannot do this: its columns are fixed, and a file name is as
/// wide as the file name. The layout is pure arithmetic over the subviews'
/// ideal sizes, so it holds no state and does no work when nothing changes.
struct FlowLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, projected > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = projected
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
