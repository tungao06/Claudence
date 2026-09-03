import SwiftUI
import ClaudenceCore

/// The dashboard window: the same reading as the popover, with room to explain
/// itself.
///
/// Composition, top to bottom:
///
///     shell header                   mark, identity, window picker, refresh
///     power meter + usage chart      372 pt column beside the remainder
///     sessions + token breakdown     the remainder beside a 340 pt column
///     stat tiles                     four across
///     projects
///     history
///     monthly usage
///
/// The two-column rows and their fixed widths are the design's, measured off
/// `Design/Claudence-UI.dc.html` section 1a: `372px 1fr` then `1fr 340px`, both
/// at an 18 pt gap.
///
/// One thing is deliberately not the design's: the four stat tiles sit *below*
/// the sessions row rather than above the power meter. The product's visual
/// priority is fixed at `power meter -> active sessions -> analytics`, and
/// three of the four tiles are analytics: tokens today, burn rate, estimated
/// cost. Opening the window on them would put the analytics above both the
/// meter and the sessions, which is the one reordering `CLAUDE.md` rules out.
/// The tiles keep their design metrics and open the analytics band instead.
///
/// The view is otherwise pure. It takes one `DashboardData`, holds only the
/// selection state the design's own controls imply, and touches no file,
/// process or network.
///
/// Nothing on this window animates on a timer. The design's liveness language,
/// pulsing dots and glowing fills and a glint sweeping every bar and tube, is
/// nine repeating animations, and a repeat inside mounted content costs a
/// layout and display pass at the screen refresh rate for the life of the
/// process. What replaces it is what the design already carries redundantly: a
/// status pill that says the word, a dimmed row for a finished session, and a
/// fill that moves only when its value does.
struct DashboardView: View {
    let data: DashboardData
    /// Reference time for every relative label on the window.
    let now: Date
    /// The user's `Compact rows` setting, which reaches the sessions card and
    /// nothing else on this window. Taken as a parameter for the same reason
    /// `SessionRow` takes one: the flag has a single owner and a preview can
    /// drive it. Default off, which is the window's normal state.
    let isCompact: Bool
    /// The header's refresh control. Nil hides the button rather than drawing a
    /// control that does nothing: the dashboard cannot reach the store itself,
    /// so the action has to arrive from the composition root.
    let onRefresh: (() -> Void)?
    /// Where a clicked session row goes. Nil falls back to the window's own
    /// detail sheet, which is built from the row's session alone and therefore
    /// carries no subagent list; a host that has one should pass this instead.
    let onSelectSession: ((AISession) -> Void)?

    /// Which usage window the header's picker has selected. The design's
    /// `5h / 7d / Fable` control, bound to the one thing this view can honestly
    /// change: which tube the power meter emphasises. It selects a window, it
    /// does not filter a measurement, so no figure on the window moves with it.
    @State private var selectedWindowName: String?
    /// The row whose detail is open, when the host supplied no handler.
    @State private var detailSession: AISession?

    /// Whether `Preferences.liveOnlyMode` is on. Read from the environment,
    /// the same route `liveIndicators` uses: this view has no other reason to
    /// know a preference exists, and the flag reaches every surface it hides
    /// through the one mechanism rather than a mix of parameters and reads.
    ///
    /// Live-only mode has nothing to write to disk, so nothing here can be
    /// computed from stored history: the daily and hourly chart, the project
    /// totals card and the session history table all disappear rather than
    /// render `Usage unavailable`, because the mode is a deliberate choice and
    /// not a degraded state. `DashboardAdapter.refreshDashboard` already skips
    /// asking the store for the figures these surfaces would have shown.
    @Environment(\.liveOnlyMode) private var liveOnlyMode
    @Environment(\.appLanguage) private var language

    init(
        data: DashboardData,
        now: Date = Date(),
        isCompact: Bool = false,
        onRefresh: (() -> Void)? = nil,
        onSelectSession: ((AISession) -> Void)? = nil
    ) {
        self.data = data
        self.now = now
        self.isCompact = isCompact
        self.onRefresh = onRefresh
        self.onSelectSession = onSelectSession
    }

    var body: some View {
        VStack(spacing: 0) {
            shellHeader
            Divider().overlay(Theme.separator)
            RenderableScrollView {
                VStack(alignment: .leading, spacing: DashboardMetrics.rowGap) {
                    meterRow
                    sessionsRow
                    StatTilesView(data: data)
                    // All three cards are history end to end -- a chart of
                    // days gone by, a table of sessions that already ended,
                    // and a month of per-project totals -- so live-only mode
                    // omits them rather than opening on an `Usage unavailable`
                    // card with nothing behind it.
                    if !liveOnlyMode {
                        projectsCard
                        historyCard
                        monthlyUsageCard
                    }
                }
                .padding(.horizontal, DashboardMetrics.shellPaddingHorizontal)
                .padding(.top, DashboardMetrics.shellPaddingVertical)
                .padding(.bottom, DashboardMetrics.bodyBottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The design's dashboard is one cream panel, not a card on a canvas:
        // this window *is* the panel.
        .background(Theme.surface)
        // Every tooltip in this window is drawn here, last, over everything.
        .tooltipLayer()
        .frame(
            minWidth: DashboardMetrics.minimumWidth,
            idealWidth: DashboardMetrics.windowWidth,
            minHeight: DashboardMetrics.minimumHeight,
            idealHeight: DashboardMetrics.windowHeight
        )
        .sheet(item: $detailSession) { session in
            // Built from the row alone. `showsSubagents` is off because this
            // view has no subagent list to show and an empty one would claim
            // the session spawned none.
            SessionDetailView(
                session: session,
                tokenScaleMaximum: data.tokenScaleMaximum,
                burnRatePerMinute: data.burn(for: session).tokensPerMinute,
                burnHistory: data.burn(for: session).samples,
                showsSubagents: false,
                now: now,
                onClose: { detailSession = nil }
            )
            .detailSheetChrome()
        }
    }

    // MARK: - Shell header

    /// Mark, identity block, window picker, refresh. The design's own header,
    /// which the previous composition had reduced to a title and one line.
    private var shellHeader: some View {
        HStack(alignment: .center, spacing: Theme.Space.l) {
            HStack(alignment: .center, spacing: DashboardMetrics.headerMarkGap) {
                RingMark(
                    percentUsed: data.fiveHourWindow.usedPercent,
                    size: DashboardMetrics.headerMarkSize,
                    showsCore: true
                )
                identityBlock
            }
            Spacer(minLength: Theme.Space.l)
            HStack(spacing: DashboardMetrics.headerControlGap) {
                windowPicker
                refreshButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DashboardMetrics.shellPaddingVertical)
        .padding(.horizontal, DashboardMetrics.shellPaddingHorizontal)
        .background(Theme.surface)
    }

    private var identityBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            PhraseText(.untranslated("Claudence"))
                .font(Theme.Typography.windowTitle)
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            PhraseText(Strings.tagline)
                .font(Theme.Typography.help)
                .foregroundStyle(Theme.textQuaternary)
            PhraseText(Strings.presenceLine)
                .font(Theme.Typography.help)
                .foregroundStyle(Theme.textQuinary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: Window picker

    /// One segment per usage window the payload actually carried.
    ///
    /// The design draws three fixed segments. Building them from the payload
    /// instead means a machine with no Fable cap does not get a segment that
    /// selects a window nobody reported, and a machine with two model-scoped
    /// caps gets both.
    private var pickerWindows: [UsageWindow] {
        guard data.usageUnavailableReason == nil else { return [] }
        return data.meterWindows
    }

    @ViewBuilder
    private var windowPicker: some View {
        let windows = pickerWindows
        if windows.count > 1 {
            HStack(spacing: DashboardMetrics.segmentedInnerGap) {
                ForEach(windows) { window in
                    segment(window, isSelected: window.name == effectiveSelection(in: windows))
                }
            }
            .padding(DashboardMetrics.segmentedTroughPadding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.surfaceControl)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Strings.highlightedUsageWindow, in: language)
        }
    }

    /// Nothing selected yet means the first window, which is the five hour one.
    /// A selection that no longer exists falls back the same way rather than
    /// leaving the control with no segment lit.
    private func effectiveSelection(in windows: [UsageWindow]) -> String? {
        if let selectedWindowName, windows.contains(where: { $0.name == selectedWindowName }) {
            return selectedWindowName
        }
        return windows.first?.name
    }

    private func segment(_ window: UsageWindow, isSelected: Bool) -> some View {
        Button {
            selectedWindowName = window.name
        } label: {
            PhraseText(Self.shortName(window))
                .font(Theme.Typography.bodyEmphasis)
                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                .padding(.vertical, DashboardMetrics.segmentPaddingVertical)
                .padding(.horizontal, DashboardMetrics.segmentPaddingHorizontal)
                .background(segmentBackground(isSelected: isSelected))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.highlightWindow.format(in: language, window.displayName))
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// Only the selected segment is painted. An unselected one draws nothing at
    /// all rather than a transparent fill, so no colour is decided here.
    @ViewBuilder
    private func segmentBackground(isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.surface)
                .shadow(
                    color: Theme.Shadow.segment.color,
                    radius: Theme.Shadow.segment.radius,
                    x: Theme.Shadow.segment.x,
                    y: Theme.Shadow.segment.y
                )
        }
    }

    /// The picker's own abbreviations, which the design writes as `5h` and `7d`
    /// where the tube caption underneath writes them out in full.
    private static func shortName(_ window: UsageWindow) -> Phrase {
        switch window.name {
        case DashboardData.WindowKey.fiveHour: return Strings.fiveHourShort
        case DashboardData.WindowKey.sevenDay: return Strings.sevenDayShort
        default: return .untranslated(window.displayName)
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        if let onRefresh {
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: Theme.Bar.severityGlyph, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(
                        width: DashboardMetrics.refreshButtonSize,
                        height: DashboardMetrics.refreshButtonSize
                    )
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                            .strokeBorder(
                                Theme.borderShell,
                                lineWidth: DashboardMetrics.chartGridStroke
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Strings.refresh, in: language)
        }
    }

    // MARK: - 1. Power meter, and the series behind it

    @ViewBuilder
    private var meterRow: some View {
        if liveOnlyMode {
            // The chart is a history of days gone by, which live-only mode has
            // nothing to draw: no fixed column beside it for the meter to keep
            // clear of, so the meter takes the row it would have shared.
            PowerMeterView(
                data: data,
                now: now,
                highlightedWindowName: effectiveSelection(in: pickerWindows)
            )
        } else {
            HStack(alignment: .top, spacing: DashboardMetrics.rowGap) {
                PowerMeterView(
                    data: data,
                    now: now,
                    highlightedWindowName: effectiveSelection(in: pickerWindows)
                )
                .frame(width: DashboardMetrics.powerMeterColumnWidth)
                chartCard
            }
        }
    }

    /// The chart supplies its own header, because its readout replaces itself
    /// with the day under the pointer and a static card title would print the
    /// same words a second time.
    ///
    /// The title names the range it was actually given rather than the design's
    /// hard-coded seven days: the adapter chooses the range, and a card that
    /// said "last 7 days" over fourteen columns would be wrong on the screen it
    /// was describing.
    private var chartCard: some View {
        DashboardCard(
            horizontalPadding: DashboardMetrics.chartCardPaddingHorizontal,
            contentGap: DashboardMetrics.cardContentGapTight
        ) {
            UsageChart(
                points: showsHourlySeries ? data.hourlySeries : data.series,
                outputTokens: showsHourlySeries ? data.hourlySeriesOutput : data.seriesOutput,
                title: chartTitle,
                caption: chartCaption,
                // The series runs up to the current bucket, so the final column
                // is the one still in progress. The chart cannot prove that
                // from the points alone, which is why the word arrives here.
                latestLabel: showsHourlySeries ? Strings.thisHour : Strings.today,
                unavailableMessage: Strings.noUsageHistory,
                unavailableReason: showsHourlySeries
                    ? data.hourlySeriesUnavailableReason
                    : data.seriesUnavailableReason
            )
        }
    }

    /// Whether the header's picker has the five-hour window selected.
    ///
    /// That window is the one selection the daily series cannot say anything
    /// about: five hours is shorter than one of its columns, so the whole
    /// window sits inside today's bar and every segment drew the same chart.
    /// The seven-day windows are already the range the daily series covers.
    ///
    /// A model-scoped window keeps the all-model daily series and says so in
    /// the caption. `daily_rollups` has no model column, so a per-model series
    /// would have to be rebuilt from session rows, and a session that spans
    /// midnight cannot be split across two days from what those rows hold. A
    /// caption that names the limit beats a chart that quietly answers a
    /// different question.
    ///
    /// The five-hour selection also has to have something to draw (9.10). The
    /// hourly series is sampled while Claudence itself is running — the
    /// chart's own caption says so — so on a fresh launch, or any capture
    /// taken before a five-hour window has elapsed with the app open, it is
    /// empty even on a machine with a full history of real usage. The chart
    /// card was defaulting to that empty series on every first run, because
    /// the picker's own default selection is the five-hour window: every
    /// screenshot taken soon after launch showed `No usage history` over a
    /// card occupying half the top row, regardless of how much the daily
    /// series, measured from the transcripts rather than sampled, actually
    /// had to show.
    ///
    /// The fallback chosen is to fall through to the daily series rather than
    /// collapse the card: the daily series is real, already computed for this
    /// same row, and losing the chart entirely on every fresh launch is a
    /// worse default than showing seven days of transcript-measured history
    /// under its own honest title instead of five hours of nothing. Nothing
    /// downstream needs a second flag for this — `chartTitle`, `chartCaption`
    /// and the chart's own `unavailableReason` all key off this one property,
    /// so a fallback here already carries the right title ("last N days"
    /// instead of "This hour") and the right caption ("measured from
    /// transcripts" instead of "sampled while running") to the rest of the
    /// card. The picker segment itself still shows 5h highlighted, because
    /// that segment is also the meter's own selection and the tube it
    /// outlines is reading correctly; only the chart beside it substitutes a
    /// series with something to draw.
    ///
    /// "Has something to draw" is `UsageChart.hasAnythingToDraw` restated
    /// rather than `data.hourlySeriesUnavailableReason == nil`: the reason
    /// string is only as honest as whatever built the `DashboardData`, and
    /// `DashboardRenderFixture.populated`, the fixture `--render-ui` draws
    /// from, is exactly the case that defect hid — it leaves both
    /// `hourlySeries` and the reason at their empty defaults, so a check
    /// against the reason read that fixture as fine and kept rendering
    /// nothing under a populated dashboard on every capture. Checking the
    /// points directly is the same test `UsageChart` itself applies before
    /// it decides whether to draw the chart or the empty state, so the two
    /// can no longer disagree about which series is present.
    private var showsHourlySeries: Bool {
        effectiveSelection(in: pickerWindows) == DashboardData.WindowKey.fiveHour
            && data.hourlySeries.contains { !$0.isMissing }
    }

    private var chartTitle: Phrase {
        if showsHourlySeries {
            let hours = data.hourlySeries.count
            guard hours > 0 else { return Strings.tokenUsage }
            return hours == 1
                ? Strings.tokenUsageLastHour
                : Strings.tokenUsageLastHours(hours)
        }
        let days = data.series.count
        guard days > 0 else { return Strings.tokenUsage }
        return days == 1 ? Strings.tokenUsageLastDay : Strings.tokenUsageLastDays(days)
    }

    /// Which source is behind the columns.
    ///
    /// The hourly series is differentiated from samples rather than summed from
    /// the rollups, and the two do not carry the same guarantee: an hour
    /// Claudence was not running to watch has no measurement at all. Naming the
    /// source is what makes those gaps legible instead of puzzling.
    private var chartCaption: Phrase {
        if showsHourlySeries { return Strings.sampledWhileRunning }
        if let selected = effectiveSelection(in: pickerWindows),
           selected.hasPrefix(DashboardData.WindowKey.modelScopedPrefix) {
            return Strings.measuredFromTranscriptsAllModels
        }
        return Strings.measuredFromTranscripts
    }

    // MARK: - 2. Sessions, and where their tokens went

    private var sessionsRow: some View {
        HStack(alignment: .top, spacing: DashboardMetrics.rowGap) {
            SessionsTableView(
                sessions: data.sessions,
                tokenScaleMaximum: data.tokenScaleMaximum,
                burnRates: data.burnRates,
                now: now,
                isCompact: isCompact,
                onSelect: { session in
                    if let onSelectSession {
                        onSelectSession(session)
                    } else {
                        detailSession = session
                    }
                }
            )
            // Today's breakdown is a rollup read, so it is hidden rather than
            // shown empty in live-only mode, and the sessions table takes the
            // width it leaves.
            if !liveOnlyMode {
                TokenBreakdownCard(usage: data.todayUsage)
                    .frame(width: DashboardMetrics.breakdownColumnWidth)
            }
        }
    }

    // MARK: - 3. Analytics

    /// The subtitle names the range, and it has to: these rows cover every
    /// session ever stored, while the cost tile three cards up covers today.
    /// Both drew a dollar figure with neither one saying so, and a $3.42 tile
    /// over project rows summing to $5.43 reads as an arithmetic error rather
    /// than as two different questions.
    private var projectsCard: some View {
        DashboardCard(
            title: Strings.projectsTitle,
            subtitle: Strings.projectsSubtitle,
            headerLayout: .inline,
            horizontalPadding: DashboardMetrics.chartCardPaddingHorizontal,
            contentGap: Theme.Space.l
        ) {
            ProjectBreakdownView(rows: data.projects, now: now)
        }
    }

    private var historyCard: some View {
        DashboardCard(
            title: Strings.historyTitle,
            subtitle: Strings.historySubtitle,
            headerLayout: .inline,
            horizontalPadding: DashboardMetrics.chartCardPaddingHorizontal,
            contentGap: Theme.Space.l
        ) {
            SessionHistoryView(rows: data.history, now: now)
        }
    }

    /// The last card in the analytics band (spec 9.13), below `historyCard`
    /// rather than above it or either card in the row above: the product's
    /// visual priority is fixed at `power meter -> active sessions ->
    /// analytics`, and every card already in this band is analytics, so a new
    /// one only has to keep its place at the bottom of that group, not argue
    /// for one above the meter or the sessions row.
    ///
    /// The subtitle names the range for the same reason `projectsCard`'s
    /// does: this table covers the trailing month, not today and not all
    /// time, and a dollar or token figure with an unstated range reads as
    /// disagreeing with whichever other range-labelled figure sits nearest it
    /// on screen.
    private var monthlyUsageCard: some View {
        DashboardCard(
            title: Strings.monthlyUsageTitle,
            subtitle: Strings.monthlyUsageSubtitle,
            headerLayout: .inline,
            horizontalPadding: DashboardMetrics.chartCardPaddingHorizontal,
            contentGap: Theme.Space.l
        ) {
            MonthlyUsageTableView(
                rows: data.monthlyUsage,
                includesSubagentTokens: data.monthlyUsageIncludesSubagentTokens,
                emptyReason: data.monthlyUsageUnavailableReason
            )
        }
    }
}

// MARK: - Strings

private enum Strings {
    static let tagline = Phrase(
        en: "AI Coding Agent Monitor · local only",
        th: "ตัวติดตาม AI Coding Agent · เก็บข้อมูลในเครื่องเท่านั้น"
    )
    static let presenceLine = Phrase(
        en: "Claude + Presence — Claude is always in the workflow; "
            + "this makes that presence visible.",
        th: "Claude + Presence — Claude อยู่ในขั้นตอนการทำงานเสมอ นี่คือสิ่งที่ทำให้เห็นการมีอยู่นั้น"
    )
    static let highlightedUsageWindow = Phrase(
        en: "Highlighted usage window",
        th: "หน้าต่างการใช้งานที่เลือกไว้"
    )
    static let highlightWindow = Phrase(
        en: "Highlight the %@ window",
        th: "เลือกหน้าต่าง %@"
    )
    static let refresh = Phrase(en: "Refresh", th: "รีเฟรช")
    static let fiveHourShort = Phrase(en: "5h", th: "5 ชม.")
    static let sevenDayShort = Phrase(en: "7d", th: "7 วัน")

    static let projectsTitle = Phrase(en: "Projects", th: "โปรเจกต์")
    static let projectsSubtitle = Phrase(
        en: "all time · where the energy went",
        th: "ทุกช่วงเวลา · พลังงานถูกใช้ไปที่ไหน"
    )
    static let historyTitle = Phrase(en: "Session history", th: "ประวัติ session")
    static let historySubtitle = Phrase(en: "newest first", th: "ล่าสุดก่อน")
    static let monthlyUsageTitle = Phrase(en: "Monthly usage", th: "การใช้งานรายเดือน")
    static let monthlyUsageSubtitle = Phrase(
        en: "last 30 days · Opus vs Sonnet, by project",
        th: "30 วันล่าสุด · Opus เทียบ Sonnet แยกตามโปรเจกต์"
    )

    static let thisHour = Phrase(en: "This hour", th: "ชั่วโมงนี้")
    static let today = Phrase(en: "Today", th: "วันนี้")
    static let noUsageHistory = Phrase(en: "No usage history", th: "ยังไม่มีประวัติการใช้งาน")

    static let tokenUsage = Phrase(en: "Token usage", th: "การใช้งาน token")
    static let tokenUsageLastHour = Phrase(
        en: "Token usage · last hour",
        th: "การใช้งาน token · ชั่วโมงล่าสุด"
    )
    static let tokenUsageLastDay = Phrase(
        en: "Token usage · last day",
        th: "การใช้งาน token · วันล่าสุด"
    )

    static func tokenUsageLastHours(_ hours: Int) -> Phrase {
        Phrase(
            en: "Token usage · last \(hours) hours",
            th: "การใช้งาน token · \(hours) ชั่วโมงล่าสุด"
        )
    }

    static func tokenUsageLastDays(_ days: Int) -> Phrase {
        Phrase(
            en: "Token usage · last \(days) days",
            th: "การใช้งาน token · \(days) วันล่าสุด"
        )
    }

    static let sampledWhileRunning = Phrase(
        en: "sampled while running",
        th: "สุ่มตัวอย่างขณะแอปทำงานอยู่"
    )
    static let measuredFromTranscriptsAllModels = Phrase(
        en: "measured from transcripts · all models",
        th: "วัดจาก transcript · ทุกโมเดล"
    )
    static let measuredFromTranscripts = Phrase(
        en: "measured from transcripts",
        th: "วัดจาก transcript"
    )
}
