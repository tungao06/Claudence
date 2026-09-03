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

// MARK: - Session detail

/// Everything Claudence knows about one session, in one scroll.
///
/// ## Structure
///
/// The order is the design file's, not a rearrangement of it:
///
/// ```
/// header
/// energy panel
/// TOKEN BREAKDOWN + context well  |  RECENT ACTIVITY
/// COST & EFFICIENCY               |  TOOL MIX
/// FILES TOUCHED
/// transcript facts bar
/// SESSION FACTS
/// SUBAGENTS
/// action row
/// ```
///
/// Two pairs of sections are genuine two-column rows in `Claudence-UI.dc.html`
/// (`grid-template-columns: 1fr 1fr`) and are two-column rows here. The design
/// sheet is 760 pt wide and this popover is 420, so each column is about 186 pt
/// rather than 355; labels wrap and paths truncate where they would not in the
/// mockup. That is a width difference, not a structural one, and the pairing is
/// what the reading depends on: the breakdown answers "where did the tokens go"
/// and the timeline answers "doing what", and they are meant to be read across.
///
/// The action row is last, as the design has it. It was at the top, which put
/// the one destructive control in the sheet above every number a reader opens
/// the sheet to see.
///
/// ## What is not the design's
///
/// `WHERE THE TOKENS WENT`, a three-row parent/subagent/combined split, was an
/// addition and is gone as a section. Its one irreplaceable fact — that the
/// subagents are a large fraction of the true total, measured at 41% on this
/// repository — now rides on the SUBAGENTS header, where it is next to the rows
/// that explain it. A top-level `CONTEXT WINDOW` section was also an addition;
/// the design puts that meter inside the token-breakdown column as an inset
/// well, and so does this.
///
/// ## Presentation
///
/// The overlay lives inside the popover rather than in a sheet or a window. A
/// `MenuBarExtra(style: .window)` popover is not an ordinary window, its content
/// stays mounted after dismissal, and every extra layer of presentation is
/// another thing holding state while nothing is on screen. Swapping the
/// popover's content costs nothing when closed. Opening a subagent does the same
/// thing one level down: `openSubagent` swaps this view for the subagent's own,
/// which is what the design's `‹ parent` back link returns from.
///
/// Nothing here repeats. The design fills every bar from zero on open and draws
/// the sparkline in; both would be one-shot and therefore permissible, but this
/// view is rebuilt on every snapshot the engine pushes, so "on open" is not a
/// moment SwiftUI can distinguish from "on update" without holding a flag that
/// would then be wrong.
struct SessionDetailView: View {

    let session: AISession
    let subagents: [AISubagent]
    /// Shared denominator for the energy bar, so its length means the same
    /// thing here as it does in the list. Nil draws no bar.
    let tokenScaleMaximum: Int?
    let burnRatePerMinute: Double?
    let burnHistory: [Double]
    /// This session's share of the tokens spent inside the recent window, from
    /// `AnalyticsService.shareOfWindowTokens`. A share of the work done in those
    /// five hours, never of the allowance they belong to, which is a quantity
    /// nothing reports. Nil is unavailable, which covers both a window that
    /// measured nothing and a session whose samples cannot be differenced across
    /// it, and it is nil by default because the figure reads the database and a
    /// view must not.
    let windowShare: Double?
    /// The design's `Show subagents` setting. False omits the list entirely
    /// rather than rendering it empty, because "no subagents spawned" would be
    /// a claim about the session when it is only a claim about the setting.
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

    /// The subagent whose own sheet is open, if any. Local state: drilling into
    /// a subagent and coming back is a reading move inside this sheet, and the
    /// popover above has no business knowing about it.
    @State private var openSubagentID: String?
    /// Set only by `--render-ui`. See `RenderableScrollView`.
    @Environment(\.isOffscreenRender) private var isOffscreenRender
    /// Whether persistence is off, which decides whether the stored-history row
    /// in the metric column exists at all. See `EnvironmentValues.liveOnlyMode`.
    @Environment(\.liveOnlyMode) private var liveOnlyMode

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

    /// How tall the detail's *scrolling body* may grow before it scrolls. The
    /// design's sheet takes 88% of the viewport; a popover has no viewport, so
    /// this is a fixed cap chosen to leave the menu bar and the screen edge
    /// alone. The header and the action bar are pinned outside it and add their
    /// own height on top.
    static let maximumHeight: CGFloat = Theme.Layout.detailScrollHeight

    private var identity: Theme.SessionIdentity { Theme.identity(forSessionID: session.id) }
    private var total: TokenUsage { session.combinedUsage }

    private var openSubagent: AISubagent? {
        guard let openSubagentID else { return nil }
        return subagents.first { $0.id == openSubagentID }
    }

    var body: some View {
        Group {
            if let subagent = openSubagent {
                SubagentDetailView(
                    subagent: subagent,
                    parent: session,
                    parentTotal: total.total,
                    costEstimator: costEstimator,
                    now: now,
                    onBack: { openSubagentID = nil },
                    onClose: onClose
                )
            } else {
                sessionBody
            }
        }
        // The detail is presented as its own window when the dashboard opens
        // it, so it carries its own layer rather than borrowing the one on the
        // window behind it.
        .tooltipLayer()
    }

    private var sessionBody: some View {
        DetailScaffold(onBack: nil, parentName: nil, onClose: onClose) {
            header
        } content: {
            scrollingSessionBody
        } footer: {
            QuickActionsMenu(session: session, actions: actions)
        }
    }

    private var header: DetailHeader {
        DetailHeader(
            dot: identity.dot,
            name: session.projectName,
            status: StatusPill(status: session.status, identity: identity),
            statusWord: Theme.name(for: session.status),
            path: session.displayPath,
            activity: session.currentActivity?.display
        )
    }

    private var scrollingSessionBody: some View {
        RenderableScrollView(heightCap: Theme.Layout.detailScrollHeight) {
            VStack(alignment: .leading, spacing: Theme.DetailSheet.bodyGap) {
                EnergyPanel(
                    total: total.total,
                    burnRatePerMinute: burnRatePerMinute,
                    burnHistory: burnHistory,
                    fraction: energyFraction,
                    identity: identity
                )

                DetailColumns {
                    TokenBreakdownColumn(usage: total) {
                        contextWell
                    }
                } trailing: {
                    ActivityTimelineView(trail: session.activityTrail, now: now)
                }

                DetailColumns {
                    MetricColumn(title: "COST & EFFICIENCY", rows: costRows, footnote: Self.costFootnote)
                } trailing: {
                    ToolMixColumn(mix: session.toolMix)
                }

                FilesTouchedSection(paths: session.filePaths)

                TranscriptFactsBar(
                    records: session.recordsParsed,
                    serviceTier: session.serviceTier
                )

                SessionFactsView(session: session, now: now)

                if showsSubagents {
                    SubagentListView(
                        subagents: subagents,
                        parentTotal: total.total,
                        subagentTotal: session.subagentUsage.total,
                        onOpen: { openSubagentID = $0.id }
                    )
                }
            }
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollHeightCap(Self.maximumHeight, isOffscreenRender: isOffscreenRender)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Session detail for \(session.projectName)")
    }

    // MARK: - Energy

    /// Nil when there is no scale to measure against. A bar without a
    /// denominator is a ratio nobody can defend.
    private var energyFraction: Double? {
        guard let tokenScaleMaximum, tokenScaleMaximum > 0 else { return nil }
        return min(1, max(0, Double(total.total) / Double(tokenScaleMaximum)))
    }

    // MARK: - Context window

    /// The design's inset well, inside the token-breakdown column.
    ///
    /// Always an estimate, and for a reason worth stating rather than hiding. A
    /// context window bounds ONE request's input. `AISession.usage` is a running
    /// total across every request the session ever made, which on a long session
    /// is an order of magnitude past any published limit; dividing it by a limit
    /// yields a percentage in the thousands that looks like a measurement and is
    /// not one. So the numerator is `session.lastRequestUsage`, the newest single
    /// record's own usage block. The denominator is `ContextWindowTable`, which
    /// is this application's claim rather than the transcript's, which is why
    /// the reading is labelled Estimated. See PLAN-UI decision 1.
    ///
    /// Three states, not two, and the third is the interesting one: when the
    /// request size is known and the model's limit is not, the figure is still
    /// printed, with no bar and no percentage. Which state applies is decided by
    /// `ContextWindowTable.reading`, in the domain, where it is testable; this
    /// property owns the wording and the layout only.
    @ViewBuilder
    private var contextWell: some View {
        switch contextWindows.reading(requestUsage: session.lastRequestUsage, model: session.model) {
        case let .measured(fraction, requestInputTokens, maximumInputTokens):
            ContextWell(
                fraction: fraction,
                detail: "\(Format.tokens(requestInputTokens)) of \(Format.tokens(maximumInputTokens))"
            )
        case let .amountOnly(requestInputTokens):
            ContextWell.amountOnly(
                amount: "\(Format.tokens(requestInputTokens)) in the last request",
                reason: Self.limitUnknownReason
            )
        case .noRequestRead:
            ContextWell.unavailable(reason: Self.noRequestReason)
        }
    }

    /// Why there is no bar although there is a figure. Deliberately a different
    /// sentence from `noRequestReason`: one says the reading is incomplete, the
    /// other says there is no reading at all.
    static let limitUnknownReason =
        "This model's limit is not in the context-limit table, and a guessed limit is worse than none"

    static let noRequestReason = "No request with a usage block has been read yet"

    // MARK: - Cost and efficiency

    static let costFootnote = "Cost is estimated from a per-model price table, never a billed amount."

    private var costRows: [MetricColumn.Row] {
        [
            MetricColumn.Row(
                name: "Estimated cost",
                value: costEstimator.estimate(usage: total, model: session.model).map(Format.cost),
                tip: "cost",
                unavailable: "Cost unavailable",
                estimated: true
            ),
            MetricColumn.Row(
                name: "Input served from cache",
                value: session.cacheServedFraction.map { Format.percent($0 * 100) },
                tip: "cr",
                unavailable: "Unavailable"
            ),
            MetricColumn.Row(
                name: "Tokens per hour",
                value: session.tokensPerHour(now: now).map { "\(Format.tokens(Int($0.rounded())))/h" },
                tip: "burn",
                unavailable: "Unavailable"
            ),
        ]
        // Dropped rather than shown unavailable in live-only mode. The share
        // differences stored samples across five hours, and in that mode the
        // samples begin when the mode did, so the row would either read
        // `Unavailable` in a display that hides every other stored figure or,
        // worse, print a percentage of a window it does not cover.
        + (liveOnlyMode ? [] : [
            MetricColumn.Row(
                name: "Share of the 5h window",
                value: windowShare.map { Format.percent($0 * 100) },
                tip: nil,
                unavailable: "Unavailable"
            ),
        ])
    }
}

// MARK: - Subagent detail

/// The same sheet, one level down.
///
/// The design draws exactly one detail overlay with a `sub` flag on it: a way
/// back to the parent and a `SUBAGENT` badge above the name, and otherwise the
/// same shape. This is that variant. The back link the mockup draws as text is
/// a round button in the title bar here, beside close and the same size as it;
/// see `DetailScaffold`. It exists because without it the
/// subagent rows are a list that leads nowhere, which is what the mockup's
/// `onClick` on every row is for.
///
/// Four of the panels the parent sheet fills have no source for a subagent, and
/// each says so rather than showing a plausible figure:
///
/// - Burn rate: no rate is sampled per subagent.
/// - Context window: `AISubagent` carries no per-request usage block.
/// - Tool mix and files touched: `AISubagent` carries no tool counts and no
///   file list. Its `Tool calls` fact is unavailable for the same reason.
/// - Started, duration and `Spawned by`: a subagent has no process, no recorded
///   start, and nothing stores which tool call spawned it.
///
/// What IS measured is the part that matters: its own token breakdown, its
/// share of the parent, its record count, its model and its estimated cost.
struct SubagentDetailView: View {
    let subagent: AISubagent
    let parent: AISession
    /// The parent's combined total, the denominator of the share.
    let parentTotal: Int
    let costEstimator: CostEstimator
    let now: Date
    let onBack: () -> Void
    let onClose: () -> Void

    /// Set only by `--render-ui`. See `RenderableScrollView`.
    @Environment(\.isOffscreenRender) private var isOffscreenRender

    private var identity: Theme.SessionIdentity { Theme.identity(forSessionID: subagent.id) }
    private var isActive: Bool { subagent.isActive(now: now) }
    private var status: SessionStatus { isActive ? .running : .completed }

    /// The name the design puts in the title. A subagent has no project name;
    /// the label Claude Code wrote for it at spawn time is the closest thing,
    /// and it is the same field the list rows are named by.
    private var name: String {
        if let task = subagent.taskDescription, !task.isEmpty { return task }
        if let type = subagent.agentType, !type.isEmpty { return type }
        return subagent.id
    }

    var body: some View {
        DetailScaffold(
            onBack: onBack,
            parentName: parent.projectName,
            onClose: onClose
        ) {
            header
        } content: {
            scrollingBody
        } footer: {
            EmptyView()
        }
    }

    private var header: DetailHeader {
        DetailHeader(
            dot: identity.dot,
            name: name,
            status: StatusPill(status: status, identity: identity),
            statusWord: Theme.name(for: status),
            path: parent.displayPath,
            activity: subagent.currentActivity?.display
        )
    }

    private var scrollingBody: some View {
        RenderableScrollView(heightCap: Theme.Layout.detailScrollHeight) {
            VStack(alignment: .leading, spacing: Theme.DetailSheet.bodyGap) {
                EnergyPanel(
                    total: subagent.usage.total,
                    burnRatePerMinute: nil,
                    burnHistory: [],
                    fraction: subagent.share(ofParentTotal: parentTotal),
                    identity: identity
                )

                DetailColumns {
                    TokenBreakdownColumn(usage: subagent.usage) {
                        ContextWell.unavailable(
                            reason: "A subagent's per-request usage is not kept, so there is no numerator"
                        )
                    }
                } trailing: {
                    ActivityTimelineView(
                        trail: currentTrail,
                        now: now,
                        emptyMessage: "No activity trail for a subagent"
                    )
                }

                DetailColumns {
                    MetricColumn(
                        title: "COST & EFFICIENCY",
                        rows: costRows,
                        footnote: SessionDetailView.costFootnote
                    )
                } trailing: {
                    ToolMixColumn(
                        mix: [],
                        emptyMessage: "Tool counts are not kept per subagent"
                    )
                }

                TranscriptFactsBar(records: subagent.recordsParsed, serviceTier: nil)

                SubagentFactsView(
                    subagent: subagent,
                    parentName: parent.projectName,
                    parentTotal: parentTotal
                )
            }
            .padding(.vertical, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollHeightCap(SessionDetailView.maximumHeight, isOffscreenRender: isOffscreenRender)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Subagent detail for \(name), spawned by \(parent.projectName)")
    }

    /// A subagent keeps only what it is doing now, not a trail. One entry is
    /// still a truthful timeline; none is an honest gap.
    private var currentTrail: [TimedActivity] {
        guard let activity = subagent.currentActivity, let at = subagent.lastActivityAt else { return [] }
        return [TimedActivity(at: at, activity: activity)]
    }

    private var costRows: [MetricColumn.Row] {
        [
            MetricColumn.Row(
                name: "Estimated cost",
                value: costEstimator.estimate(usage: subagent.usage, model: subagent.model).map(Format.cost),
                tip: "cost",
                unavailable: "Cost unavailable",
                estimated: true
            ),
            MetricColumn.Row(
                name: "Input served from cache",
                value: cacheServed.map { Format.percent($0 * 100) },
                tip: "cr",
                unavailable: "Unavailable"
            ),
            MetricColumn.Row(
                name: "Tokens per hour",
                value: nil,
                tip: "burn",
                unavailable: "Unavailable"
            ),
            MetricColumn.Row(
                name: "Share of the parent",
                value: subagent.share(ofParentTotal: parentTotal).map { Format.percent($0 * 100) },
                tip: nil,
                unavailable: "Unavailable"
            ),
        ]
    }

    /// The same ratio `AISession.cacheServedFraction` reports, over this
    /// subagent's own usage, and over `billableInput` rather than a locally
    /// re-derived sum so the one definition of billable input still holds.
    private var cacheServed: Double? {
        let billable = subagent.usage.billableInput
        guard billable > 0 else { return nil }
        return Double(subagent.usage.cacheRead) / Double(billable)
    }
}

// MARK: - Header

/// The sheet's title block, in both of the design's variants.
///
/// It owns neither round control nor the subagent eyebrow. Both used to be
/// here, and both were wrong here. The back link was a text row, which made it
/// a small target sitting a line below the close button rather than beside it,
/// and it scrolled away with the rest of the header while close stayed pinned.
/// The eyebrow then shared a row with this whole block, so on a subagent the
/// title started to the right of the back button and lost that much width to
/// it -- on a long task description, which is what a subagent is named by, that
/// read as the button crowding the name. `DetailScaffold` draws the controls
/// and the eyebrow on their own row above; what is left here is the title, the
/// path and the activity, each with the full width of the bar.
struct DetailHeader: View {
    let dot: Color
    let name: String
    let status: StatusPill
    /// The status as a word, for the spoken label. The pill already carries it
    /// visibly; this is so the header reads as one sentence.
    let statusWord: String
    let path: String
    let activity: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Circle()
                    .fill(dot)
                    .frame(width: Theme.Bar.statusGlyph, height: Theme.Bar.statusGlyph)
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    .accessibilityHidden(true)
                // Two lines, because one truncated the name. A subagent is
                // named by the task description Claude Code wrote for it, which
                // is a sentence, not a label, and a session's project name can
                // be a long directory. Two lines is a bounded amount of chrome
                // and covers every fixture here; past that it still elides.
                Text(name)
                    .font(Theme.Typography.sheetTitle)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                status
                    .fixedSize()
                    .tooltip(tip: "status")
                Spacer(minLength: 0)
            }

            Text(path)
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel("Working directory \(path)")

            if let activity {
                Text(activity)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .tooltip(tip: "activity", edge: .leading)
                    .accessibilityLabel("Activity, \(activity)")
            } else {
                UnavailableView("Activity unavailable", compact: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), \(statusWord)")
    }
}

// MARK: - Scaffold

/// The pinned chrome around a detail: a title bar above the scroll and, when
/// there is one, an action bar below it.
///
/// ## Why the bars are pinned
///
/// Everything here used to be the first and last item *inside* the scroll, with
/// only the close button floating over it. Three things followed from that, and
/// all three were reported:
///
/// - The back link scrolled away. Close stayed pinned, so on a long subagent
///   detail the two ways out were in different places and only one of them was
///   reachable without scrolling back to the top.
/// - The back link was a bare text run, so its target was the width of a name
///   and the height of a line, next to a round button it did not match.
/// - The title and the action row sat on the sheet's own surface with nothing
///   between them and the body, so they read as the top and bottom of the
///   scrolled content rather than as the frame around it.
///
/// The bars now carry their own ground and their own border, which is what
/// separates chrome from content here. They are inset rather than bled to the
/// sheet's edge on purpose: the two hosts give this view different gutters --
/// `detailSheetChrome()` in a window, `Theme.Layout.popoverPadding` in the
/// popover -- and a bar that assumed either number would be wrong in the other.
struct DetailScaffold<Header: View, Content: View, Footer: View>: View {
    /// Nil in the session variant, which has nowhere to go back to.
    let onBack: (() -> Void)?
    /// The parent session's name, which draws the subagent eyebrow and names
    /// the back button. Nil whenever `onBack` is.
    let parentName: String?
    let onClose: () -> Void
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    /// Whether the caller passed a footer at all. A type comparison rather than
    /// a flag the caller has to keep in step with what it passes.
    private var showsFooter: Bool { Footer.self != EmptyView.self }

    var body: some View {
        VStack(spacing: Theme.DetailSheet.bodyGap) {
            titleBar
            content
            if showsFooter {
                footer.detailBar()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The controls and the eyebrow get their own row above the title, rather
    /// than a column beside it.
    ///
    /// Beside it was the first attempt and it cost the title real width: the
    /// back button, the gap and the close button together took about 96 pt off
    /// the line the name is on, and a subagent's name is a whole task
    /// description. The name then wrapped or elided early and read as though
    /// the button were shoving it. On their own row they take a row's height,
    /// which is chrome the bar was already tall enough for, and the title,
    /// the path and the activity each get the full width.
    private var titleBar: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            controlRow
            header
        }
        .detailBar()
    }

    private var controlRow: some View {
        HStack(spacing: Theme.Space.m) {
            if let onBack, let parentName {
                DetailBarButton(
                    glyph: "chevron.left",
                    label: "Back to \(parentName)",
                    hint: "Returns to the session that spawned this subagent",
                    action: onBack
                )
                eyebrow(parentName: parentName)
            }

            Spacer(minLength: Theme.Space.m)

            DetailBarButton(
                glyph: "xmark",
                label: "Close session detail",
                hint: nil,
                isEscape: true,
                action: onClose
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Where the subagent variant says whose subagent it is. The back button is
    /// immediately to its left, so the name doubles as that button's visible
    /// label without the button having to reserve room for it.
    private func eyebrow(parentName: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(parentName)
                .font(Theme.Typography.labelEmphasis)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityLabel("Spawned by \(parentName)")

            Text("SUBAGENT")
                .font(Theme.Typography.caption.weight(.bold))
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.m)
                .padding(.vertical, Theme.Space.xxs)
                .background(Capsule(style: .continuous).fill(Theme.surfaceControl))
                .fixedSize()
        }
        .layoutPriority(1)
    }
}

private extension View {

    /// The ground the two pinned bars share.
    func detailBar() -> some View {
        padding(.horizontal, Theme.DetailSheet.barPadding)
            .padding(.vertical, Theme.DetailSheet.barPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.DetailSheet.barRadius, style: .continuous)
                    .fill(Theme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.DetailSheet.barRadius, style: .continuous)
                    .strokeBorder(Theme.borderCard, lineWidth: DashboardMetrics.chartGridStroke)
            )
    }
}

// MARK: - Bar controls

/// A round control in the detail's title bar. Back and close are the same
/// button with a different glyph, which is the point: they used to be a 22 pt
/// circle and a text link on separate lines, and neither was comfortable to
/// hit.
struct DetailBarButton: View {
    let glyph: String
    let label: String
    let hint: String?
    /// True on close, which Escape also triggers. Only one control in a sheet
    /// may claim that key.
    var isEscape = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: glyph)
                .font(.system(size: Theme.DetailSheet.barGlyph, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(
                    width: Theme.DetailSheet.barButtonSize,
                    height: Theme.DetailSheet.barButtonSize
                )
                .background(Circle().fill(Theme.surfaceControl))
                .overlay(
                    Circle().strokeBorder(Theme.borderCard, lineWidth: DashboardMetrics.chartGridStroke)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .modifier(OptionalHint(hint: hint))
        .modifier(EscapeShortcut(isEscape: isEscape))
    }
}

/// `accessibilityHint` takes a value, not an optional, so the absence of a hint
/// is a modifier that does nothing rather than an empty string that reads as
/// one.
private struct OptionalHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

private struct EscapeShortcut: ViewModifier {
    let isEscape: Bool

    func body(content: Content) -> some View {
        if isEscape {
            content.keyboardShortcut(.escape, modifiers: [])
        } else {
            content
        }
    }
}

// MARK: - Sheet chrome

extension View {

    /// What a window host has to supply around a detail, and what the popover
    /// supplies for itself with `popoverPadding`.
    ///
    /// The detail draws no gutters of its own, so a host that presents it in a
    /// sheet and forgets them gets a panel whose title, bars and buttons sit
    /// flush against the window edge. That shipped: the dashboard's sheet set
    /// neither a width nor a padding, so the sheet took the content's own ideal
    /// width and every row touched both edges.
    func detailSheetChrome() -> some View {
        padding(.horizontal, Theme.DetailSheet.horizontal)
            .padding(.top, Theme.DetailSheet.bodyTop)
            .padding(.bottom, Theme.DetailSheet.bodyBottom)
            .frame(width: Theme.Layout.sheetWidth)
            .background(Theme.surface)
    }
}

// MARK: - Two-column row

/// The design's `grid-template-columns: 1fr 1fr` pairing.
///
/// A plain `HStack` rather than a `Grid`: the two columns are independent
/// stacks of different heights and the design aligns them at the top, which is
/// exactly what this does. Named so the pairing is a stated intent rather than
/// an incidental `HStack` somebody later unwraps.
struct DetailColumns<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: Theme.DetailSheet.bodyGap) {
            leading.frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Energy panel

/// The headline: what this session or subagent has spent, and how fast.
struct EnergyPanel: View {
    let total: Int
    let burnRatePerMinute: Double?
    let burnHistory: [Double]
    /// Length of the bar. Nil draws no bar, because a bar without a denominator
    /// is a ratio nobody can defend.
    let fraction: Double?
    let identity: Theme.SessionIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text("Token energy")
                        .font(Theme.Typography.labelEmphasis)
                        .foregroundStyle(Theme.textTertiary)
                        .tooltip(tip: "energy", edge: .leading, underline: .warm)
                    Text(Format.tokens(total))
                        .font(Theme.Typography.sheetTotal)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Token energy, \(Format.tokens(total)) tokens")

                Spacer(minLength: Theme.Space.s)

                VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                    Text("Burn rate")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textTertiary)
                        .tooltip(tip: "burn", edge: .trailing, underline: .warm)
                    if let burnRatePerMinute {
                        Text("\(Format.tokens(Int(burnRatePerMinute.rounded())))/min")
                            .font(Theme.Typography.panelValue)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                    } else {
                        Text("Unavailable")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if Sparkline.canRender(burnHistory) {
                        Sparkline(burnHistory, label: "Token rate")
                            .frame(width: Theme.Bar.sparklineWidth)
                    }
                }
            }

            if let fraction {
                energyBar(fraction)
            }
        }
        .padding(.vertical, Theme.DetailSheet.energyPaddingVertical)
        .padding(.horizontal, Theme.DetailSheet.energyPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
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
        .frame(height: Theme.Bar.sheet)
        .accessibilityHidden(true)
    }
}

// MARK: - Token breakdown column

/// The four token categories, each with its own bar, and whatever well the
/// caller hangs underneath — the design puts the context meter there.
///
/// Cache read and cache write keep their own rows for the whole life of this
/// view. A cache read costs roughly a tenth of a fresh input token, so folding
/// the three into one "input" figure would make the display disagree with the
/// bill by an order of magnitude on the cheap part.
struct TokenBreakdownColumn<Well: View>: View {
    let usage: TokenUsage
    @ViewBuilder let well: Well

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("TOKEN BREAKDOWN")
            compositionBar
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                ForEach(Theme.TokenCategory.allCases, id: \.self) { category in
                    row(category)
                }
            }
            well.padding(.top, Theme.Space.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(for category: Theme.TokenCategory) -> Int {
        switch category {
        case .freshInput: return usage.freshInput
        case .cacheWrite: return usage.cacheCreation
        case .cacheRead: return usage.cacheRead
        case .output: return usage.output
        }
    }

    private func fraction(of category: Theme.TokenCategory) -> Double? {
        guard usage.total > 0 else { return nil }
        return Double(value(for: category)) / Double(usage.total)
    }

    // MARK: - The bar

    /// One stacked bar for the whole total, replacing the four proportional
    /// bars this column used to draw under each label.
    ///
    /// The four were the wrong chart for the data, not merely one too many.
    /// Measured on a live session: fresh input 2 k, cache write 2.3 M, cache
    /// read 194.5 M, output 857 k. That is a ratio of about 1 to 97,000 between
    /// the smallest and the largest, so three of the four bars rendered as a
    /// hairline or as nothing at all, every time, on every session -- a linear
    /// bar cannot show three orders of magnitude and was silently refusing to.
    /// Meanwhile each bar sat on its own line under its label, which put a
    /// coloured swatch and a coloured bar around one row and read as two rows.
    ///
    /// Stacked, the proportions are shown in the one place they are meaningful:
    /// against each other, summing to the whole. A segment too small to see is
    /// then a true statement rather than a failed one, and the share column
    /// below carries the figure for it.
    ///
    /// The swatches stay, and stop being decoration: they are now the only
    /// thing tying a table row to a segment of this bar.
    private var compositionBar: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Theme.TokenCategory.allCases, id: \.self) { category in
                    Rectangle()
                        .fill(Theme.color(for: category))
                        .frame(width: (fraction(of: category) ?? 0) * geo.size.width)
                }
                // Whatever the segments did not cover, which is the whole bar
                // when there is no total to divide by.
                Rectangle().fill(Theme.track)
            }
        }
        .frame(height: Theme.Bar.micro)
        .clipShape(Capsule(style: .continuous))
        .accessibilityHidden(true)
    }

    // MARK: - The table

    private func row(_ category: Theme.TokenCategory) -> some View {
        let amount = value(for: category)
        let share = fraction(of: category)
        return HStack(spacing: Theme.Space.s) {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.color(for: category))
                .frame(width: Theme.Bar.micro, height: Theme.Bar.micro)
            Text(category.label)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if category == .output, usage.thinking > 0 {
                Text("(\(Format.tokens(usage.thinking)) thinking)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }
            Spacer(minLength: Theme.Space.s)
            Text(Format.tokens(amount))
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: Theme.DetailSheet.breakdownValueColumn, alignment: .trailing)
            // The share the stacked bar draws, stated. A segment a pixel wide
            // is unreadable by design; this is where its size is actually
            // reported, which is why `Format.share` says `<1%` rather than
            // rounding a real spend down to `0%`.
            Text(share.map(Format.share) ?? "\u{2014}")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                .frame(width: Theme.DetailSheet.breakdownShareColumn, alignment: .trailing)
        }
        .padding(.vertical, Theme.Space.xxs)
        .tooltip(breakdown: category.label, value: amount, of: usage.total)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(category, amount: amount, fraction: share))
    }

    private func label(_ category: Theme.TokenCategory, amount: Int, fraction: Double?) -> String {
        var text = "\(category.label), \(Format.tokens(amount)) tokens"
        if let fraction { text += ", \(Format.share(fraction)) of the total" }
        return text
    }
}

// MARK: - Context well

/// The design's inset context meter: a label, a bar and one summary line.
///
/// The reading always carries the word Estimated, because the denominator is
/// Claudence's own model table and not anything the transcript stated.
///
/// Three states, matching `ContextReading`: the meter, the figure with no
/// meter when the model's limit is unknown, and nothing at all when no request
/// has been read. The middle one exists because the amount in use is a
/// measurement in its own right, and withholding it because the ceiling is
/// missing threw away a fact the reader had.
struct ContextWell: View {
    let fraction: Double?
    /// `used of limit`, the design's own sub-line, or nil when there is none.
    let detail: String?
    /// The measured figure shown when there is no limit to measure it against.
    let amount: String?
    let reason: String?

    init(fraction: Double, detail: String) {
        self.fraction = fraction
        self.detail = detail
        self.amount = nil
        self.reason = nil
    }

    private init(amount: String?, reason: String) {
        self.fraction = nil
        self.detail = nil
        self.amount = amount
        self.reason = reason
    }

    static func unavailable(reason: String) -> ContextWell {
        ContextWell(amount: nil, reason: reason)
    }

    /// The amount is known and the limit is not: print the figure, say why
    /// there is no bar, and never divide by a guess.
    static func amountOnly(amount: String, reason: String) -> ContextWell {
        ContextWell(amount: amount, reason: reason)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text("Context window")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textTertiary)
                .tooltip(tip: "ctx", edge: .leading)

            if let fraction {
                meter(fraction)
            } else if let amount {
                figureWithoutALimit(amount)
            } else {
                UnavailableView("Context window unavailable", reason: reason, compact: true)
            }
        }
        .padding(Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.surfaceInset)
        )
    }

    /// The amount with no bar behind it. No severity glyph and no colour: both
    /// would be claims about how close this request is to a limit nobody has.
    private func figureWithoutALimit(_ amount: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(amount)
                .font(Theme.Typography.value)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            reason.map { "Context window, \(amount). \($0)" } ?? "Context window, \(amount)"
        )
    }

    private func meter(_ fraction: Double) -> some View {
        let percent = fraction * 100
        let severity = Constants.ContextThreshold.severity(forPercent: percent)
        return VStack(alignment: .leading, spacing: Theme.Space.s) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule()
                        .fill(Theme.color(for: severity))
                        .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                }
            }
            .frame(height: Theme.Bar.row)

            // Glyph, word and colour together: severity is never colour alone.
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: Theme.glyph(for: severity))
                    .font(.system(size: Theme.Bar.statusGlyph))
                    .foregroundStyle(Theme.color(for: severity))
                Text("\(Format.percent(percent)) used \u{00B7} \(Theme.name(for: severity).capitalized) \u{00B7} Estimated")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let detail {
                Text(detail)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Context window, estimated \(Format.percent(percent)) used, \(Theme.name(for: severity)). "
            + "The limit comes from Claudence's own model table, not from the transcript."
        )
    }
}

// MARK: - Metric column

/// A column of label / value pairs with a footnote. The design's COST &
/// EFFICIENCY block, and anything else shaped like it.
struct MetricColumn: View {
    struct Row: Identifiable {
        let name: String
        let value: String?
        let tip: String?
        let unavailable: String
        var estimated: Bool = false

        var id: String { name }
    }

    let title: String
    let rows: [Row]
    let footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow(title)
            ForEach(rows) { row in
                metricRow(row)
                if row.id != rows.last?.id {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: 1)
                }
            }
            Text(footnote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One label and one value. `estimated` adds the word the spec requires on
    /// every derived money figure, and it is a word rather than a colour or an
    /// icon so it survives being read aloud.
    private func metricRow(_ row: Row) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(row.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Space.xs)
                Text(row.value ?? row.unavailable)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(row.value == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
            }
            if row.estimated, row.value != nil {
                Text("Estimated")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
                    .padding(.horizontal, Theme.Space.s)
                    .padding(.vertical, Theme.Space.xxs)
                    .background(Capsule(style: .continuous).fill(Theme.surfaceControl))
            }
        }
        .tooltip(row.tip.flatMap(TooltipText.tip))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(row))
    }

    private func spoken(_ row: Row) -> String {
        guard let value = row.value else { return "\(row.name), \(row.unavailable.lowercased())" }
        return row.estimated ? "\(row.name), \(value), estimated" : "\(row.name), \(value)"
    }
}

// MARK: - Tool mix

/// Counts by tool name, and nothing about what the tool was given. A Bash call
/// contributes one to `Bash` and nothing else, because command strings
/// routinely carry API keys and connection strings.
struct ToolMixColumn: View {
    let mix: [(name: String, count: Int)]
    var emptyMessage: String = "No tool calls recorded yet"

    static let footnote = "Counted by tool name only. Arguments are never read."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("TOOL MIX")
            let rows = Array(mix.prefix(6))
            if rows.isEmpty {
                UnavailableView(emptyMessage, compact: true)
            } else {
                let peak = rows.first?.count ?? 0
                ForEach(Array(rows.enumerated()), id: \.element.name) { index, entry in
                    row(entry.name, count: entry.count, peak: peak, index: index)
                }
            }
            Text(Self.footnote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ name: String, count: Int, peak: Int, index: Int) -> some View {
        // The design cycles the four category colours through the tool bars.
        // They carry no meaning here beyond telling one row from the next.
        let palette = Theme.TokenCategory.allCases
        let colour = Theme.color(for: palette[index % palette.count])
        let fraction = peak > 0 ? Double(count) / Double(peak) : 0
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Text(name)
                    .font(Theme.Typography.toolValue)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                Text("\(count)")
                    .font(Theme.Typography.toolValue)
                    .foregroundStyle(Theme.textQuaternary)
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
}

// MARK: - Files touched

/// File paths are on the allowlist; file contents are not, and nothing here
/// opens a file. The chip shows the name and the full path is available to the
/// pointer and to a screen reader.
struct FilesTouchedSection: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("FILES TOUCHED")
            if paths.isEmpty {
                UnavailableView("No files touched yet", compact: true)
            } else {
                FlowLayout(spacing: Theme.Space.s) {
                    ForEach(paths, id: \.self) { path in
                        chip(path)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ path: String) -> some View {
        Text((path as NSString).lastPathComponent)
            .font(Theme.Typography.numeric)
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .fill(Theme.surfaceInset)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
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
