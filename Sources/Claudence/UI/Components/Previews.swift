import SwiftUI
import ClaudenceCore

// MARK: - Fixtures
//
// Every mock value in the visual system lives here and nowhere else. No other
// component file contains an invented number, name, or path. Larger fixtures
// are composed from the small named ones below so a reviewer can see exactly
// what each preview is exercising.

/// Percentages chosen to sit one on each side of every usage threshold.
private enum PercentFixture {
    static let healthy = 18.0
    static let attention = 64.0
    static let warning = 83.0
    static let critical = 97.0
    static let empty = 0.0
    static let full = 100.0
    /// A source reporting a value outside 0...100; the bar must clamp it.
    static let overflowing = 118.0
    static let unavailable: Double? = nil
}

/// Offsets used to build reset dates relative to render time.
private enum ClockFixture {
    static let twoHoursFourteen: TimeInterval = 2 * 3_600 + 14 * 60
    static let elevenMinutes: TimeInterval = 11 * 60
    static let fourDays: TimeInterval = 4 * 86_400
    static let oneHour: TimeInterval = 3_600
    static let thirtySevenMinutes: TimeInterval = 37 * 60
    static let sixHours: TimeInterval = 6 * 3_600

    static var soon: Date { Date().addingTimeInterval(twoHoursFourteen) }
    static var veryClose: Date { Date().addingTimeInterval(elevenMinutes) }
    static var distant: Date { Date().addingTimeInterval(fourDays) }
    /// A reset that has already happened. `Format.timeUntil` returns nil, so no
    /// caption should appear.
    static var passed: Date { Date().addingTimeInterval(-oneHour) }
}

/// Token shapes with a realistic cache-heavy profile, per spec section 5.2.
private enum UsageFixture {
    static let none = TokenUsage.zero

    static let small = TokenUsage(
        freshInput: 2_100,
        cacheCreation: 22_018,
        cacheRead: 24_858,
        output: 8_200,
        thinking: 640
    )

    static let medium = TokenUsage(
        freshInput: 9_400,
        cacheCreation: 128_000,
        cacheRead: 310_500,
        output: 41_200,
        thinking: 5_100
    )

    /// Deliberately past the million mark so the "M" formatting and the
    /// right-hand column width are both exercised.
    static let enormous = TokenUsage(
        freshInput: 812_000,
        cacheCreation: 4_300_000,
        cacheRead: 18_640_000,
        output: 2_450_000,
        thinking: 380_000
    )

    /// Scale maxima the bars are measured against.
    static let smallScale = 200_000
    static let mediumScale = 1_000_000
    static let enormousScale = 40_000_000
}

/// Burn-rate series for the sparkline.
private enum SeriesFixture {
    static let rising: [Double] = [1_200, 1_800, 1_500, 2_400, 3_100, 2_900, 4_200, 5_600]
    static let noisy: [Double] = [8_100, 2_300, 9_400, 1_100, 7_700, 3_200, 9_900, 4_400, 6_100]
    /// A real, measured, unchanging rate. Must draw a centred flat line.
    static let flat: [Double] = [3_000, 3_000, 3_000, 3_000, 3_000]
    static let singlePoint: [Double] = [4_800]
    static let empty: [Double] = []

    static let rate = 12_400.0
    static let slowRate = 240.0
}

private enum PathFixture {
    static let short = "/Users/preview/code/claudence"
    /// Long enough to force head truncation inside a 300 pt popover.
    static let veryLong =
        "/Users/preview/Development/clients/northwind/platform/services/"
        + "billing/apps/reconciliation-worker/packages/core-domain"
}

private enum ActivityFixture {
    static let editing = Activity(verb: "Editing", subject: "SessionStore.swift")
    static let testing = Activity(verb: "Running tests")
    static let longSubject = Activity(
        verb: "Editing",
        subject: "ReconciliationWorkerConfigurationBuilder+Defaults.swift"
    )
}

/// A single assistant record's own usage block, for the context-window meter.
/// `AISession.usage` is a running total across the whole session and is the
/// wrong number for this; see the note atop `ContextWindow.swift`. Kept in its
/// own fixture, with numbers distinct from every `UsageFixture` entry, so
/// nobody mistakes a session total for a single request's input.
private enum RequestUsageFixture {
    static let single = TokenUsage(
        freshInput: 7_777,
        cacheCreation: 61_111,
        cacheRead: 233_333,
        output: 9_999,
        thinking: 1_111
    )
}

/// Tool-call counts for the tool-mix section. Names only, per the privacy
/// allowlist; the numbers are invented and unordered on purpose, so the view's
/// own sort (busiest first) is what puts them in order rather than the fixture.
private enum ToolMixFixture {
    static let varied: [String: Int] = [
        "Edit": 19,
        "Read": 41,
        "Bash": 12,
        "Grep": 7,
        "Write": 3,
    ]
}

/// Distinct file paths for the files-touched section. Fake project, fake
/// filenames, so nothing here reads as a real measurement of this repository.
private enum FilePathFixture {
    static let several: [String] = [
        "/Users/preview/code/widgetco/Sources/Widget/Engine/Processor.swift",
        "/Users/preview/code/widgetco/Sources/Widget/UI/DetailView.swift",
        "/Users/preview/code/widgetco/Tests/WidgetTests/ProcessorTests.swift",
    ]
}

/// Recent activities for the timeline. Built independent of `ActivityMapper`
/// so a change to the real verb wording cannot silently start passing here.
private enum TrailFixture {
    /// Nothing read yet: the timeline's own unavailable state.
    static let empty: [TimedActivity] = []

    /// Exactly the engine's cap of 24 (`MonitorEngine.accumulatedTrail`),
    /// oldest first the way the engine stores it, so the view's own
    /// reverse-then-prefix logic is what puts "just now" at the top.
    static let atCap: [TimedActivity] = (0..<24).map { index in
        TimedActivity(
            at: Date().addingTimeInterval(-Double(24 - index) * 150),
            activity: entry(index)
        )
    }

    private static func entry(_ index: Int) -> Activity {
        switch index % 4 {
        case 0: return Activity(verb: "Editing", subject: "Handler\(index).swift")
        case 1: return Activity(verb: "Running a command")
        case 2: return Activity(verb: "Searching", subject: "codebase")
        default: return Activity(verb: "Reading", subject: "Config\(index).json")
        }
    }
}

/// One session's cost as a share of Claudence's recent-window total. A
/// fraction, not a token count, so it lives apart from `UsageFixture`.
private enum WindowShareFixture {
    static let strong = 0.18
}

/// Subagents spawned by `SessionFixture.withSubagents`. Four rows: three with
/// full labels and one whose `meta.json` never resolved, so the list's two
/// label states and its share arithmetic all have something to draw.
private enum SubagentFixture {
    static let editor = AISubagent(
        id: "preview-subagent-editor",
        parentSessionID: "preview-with-subagents",
        agentType: "code-editor",
        taskDescription: "Refactor the token formatter to share one code path",
        usage: TokenUsage(freshInput: 3_000, cacheCreation: 12_000, cacheRead: 40_000, output: 5_000, thinking: 500),
        lastActivityAt: Date().addingTimeInterval(-90)
    )

    static let researcher = AISubagent(
        id: "preview-subagent-researcher",
        parentSessionID: "preview-with-subagents",
        agentType: "researcher",
        taskDescription: "Survey how the registry handles a reaped process",
        usage: TokenUsage(freshInput: 1_500, cacheCreation: 8_000, cacheRead: 22_000, output: 3_000, thinking: 200),
        lastActivityAt: Date().addingTimeInterval(-420)
    )

    static let reviewer = AISubagent(
        id: "preview-subagent-reviewer",
        parentSessionID: "preview-with-subagents",
        agentType: "reviewer",
        taskDescription: "Check the new adapter against the privacy allowlist",
        usage: TokenUsage(freshInput: 900, cacheCreation: 4_000, cacheRead: 9_000, output: 1_800, thinking: 100),
        lastActivityAt: Date().addingTimeInterval(-1_800)
    )

    /// `meta.json` went unread this pass: both labels fall back to the
    /// unavailable wording rather than to a guess.
    static let unlabeled = AISubagent(
        id: "preview-subagent-unlabeled",
        parentSessionID: "preview-with-subagents",
        agentType: nil,
        taskDescription: nil,
        usage: TokenUsage(freshInput: 400, cacheCreation: 1_000, cacheRead: 2_000, output: 600),
        lastActivityAt: Date().addingTimeInterval(-60)
    )

    static let empty: [AISubagent] = []
    static let several: [AISubagent] = [editor, researcher, reviewer]
    static let withUnlabeled: [AISubagent] = [editor, unlabeled]

    static var severalTotal: TokenUsage { several.reduce(.zero) { $0 + $1.usage } }
    static var withUnlabeledTotal: TokenUsage { withUnlabeled.reduce(.zero) { $0 + $1.usage } }

    /// Parent totals for a standalone `SubagentListView` preview: comfortably
    /// above the sum of the rows above, so every share renders under 100%.
    static let severalParentTotal = 200_000
    static let withUnlabeledParentTotal = 120_000
}

/// `SessionActions` for `QuickActionsMenu`. Every closure is a pure return —
/// no Terminal, no Finder, no pasteboard, no signal — and each button is wired
/// to a different `SessionActionOutcome` case, so all four outcome tones are
/// reachable from one fixture without ever touching the real machine.
private enum QuickActionsFixture {
    @MainActor static let mixedOutcomes = SessionActions(
        // Directory "exists" so Terminal reaches the next check instead of
        // failing early on a missing folder.
        terminalApplicationURL: { nil }, // Terminal -> .unavailable
        openDirectory: { _, _ in nil }, // never reached in this fixture
        revealInFinder: { _ in true }, // Project -> .done
        directoryExists: { _ in true },
        copyToPasteboard: { _ in false }, // Copy Path -> .failed
        isAlive: { _, _ in false }, // Stop -> .alreadyStopped
        terminate: { _ in 0 } // never reached: isAlive already said no
    )
}

private enum SessionFixture {
    private static func make(
        id: String,
        projectName: String,
        workingDirectory: String,
        status: SessionStatus,
        activity: Activity?,
        usage: TokenUsage,
        age: TimeInterval,
        model: String? = "claude-sonnet-5",
        lastRequestUsage: TokenUsage? = nil,
        subagentUsage: TokenUsage = .zero,
        subagentCount: Int = 0,
        serviceTier: String? = nil,
        pid: Int32 = 42_541,
        recordsParsed: Int = 0,
        toolCounts: [String: Int] = [:],
        filePaths: [String] = [],
        activityTrail: [TimedActivity] = []
    ) -> AISession {
        AISession(
            id: id,
            pid: pid,
            procStart: "Tue Sep  1 19:27:02 2026",
            projectName: projectName,
            workingDirectory: workingDirectory,
            status: status,
            currentActivity: activity,
            startedAt: Date().addingTimeInterval(-age),
            lastActivityAt: Date(),
            usage: usage,
            subagentUsage: subagentUsage,
            subagentCount: subagentCount,
            model: model,
            claudeCodeVersion: "2.1.257",
            toolCounts: toolCounts,
            filePaths: filePaths,
            activityTrail: activityTrail,
            serviceTier: serviceTier,
            recordsParsed: recordsParsed,
            lastRequestUsage: lastRequestUsage
        )
    }

    static var working: AISession {
        make(
            id: "preview-working",
            projectName: "claudence-06",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: ActivityFixture.editing,
            usage: UsageFixture.small,
            age: ClockFixture.thirtySevenMinutes
        )
    }

    static var idle: AISession {
        make(
            id: "preview-idle",
            projectName: "hr-leave-management-14",
            workingDirectory: PathFixture.short,
            status: .idle,
            activity: ActivityFixture.testing,
            usage: UsageFixture.medium,
            age: ClockFixture.sixHours
        )
    }

    static var completed: AISession {
        make(
            id: "preview-completed",
            projectName: "invoice-reconciler",
            workingDirectory: PathFixture.short,
            status: .completed,
            activity: nil,
            usage: UsageFixture.small,
            age: ClockFixture.fourDays
        )
    }

    /// A status with no proven data source. Must render the explicit fallback.
    static var underivableStatus: AISession {
        make(
            id: "preview-underivable",
            projectName: "permission-probe",
            workingDirectory: PathFixture.short,
            status: .permission,
            activity: nil,
            usage: UsageFixture.small,
            age: ClockFixture.elevenMinutes
        )
    }

    static var longPath: AISession {
        make(
            id: "preview-long-path",
            projectName: "reconciliation-worker-integration-suite",
            workingDirectory: PathFixture.veryLong,
            status: .running,
            activity: ActivityFixture.longSubject,
            usage: UsageFixture.medium,
            age: ClockFixture.sixHours
        )
    }

    static var enormousTokens: AISession {
        make(
            id: "preview-enormous",
            projectName: "monorepo-migration",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: ActivityFixture.editing,
            usage: UsageFixture.enormous,
            age: ClockFixture.fourDays
        )
    }

    /// No transcript has been read yet, so there are no tokens and no activity.
    static var noData: AISession {
        make(
            id: "preview-no-data",
            projectName: "fresh-session",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: nil,
            usage: UsageFixture.none,
            age: ClockFixture.elevenMinutes
        )
    }

    /// Carries subagents plus a populated facts panel, tool mix, file list and
    /// timeline, so the "has subagents" preview does not incidentally look
    /// like `noData` everywhere else on the screen.
    static var withSubagents: AISession {
        make(
            id: "preview-with-subagents",
            projectName: "claudence-survey",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: ActivityFixture.editing,
            usage: UsageFixture.small,
            age: ClockFixture.thirtySevenMinutes,
            subagentUsage: SubagentFixture.severalTotal,
            subagentCount: SubagentFixture.several.count,
            serviceTier: "standard",
            recordsParsed: 214,
            toolCounts: ToolMixFixture.varied,
            filePaths: FilePathFixture.several,
            activityTrail: TrailFixture.atCap
        )
    }

    /// A model the context table sizes, with a single request's usage on
    /// record: the meter has both halves it needs and renders filled.
    static var contextFilled: AISession {
        make(
            id: "preview-context-filled",
            projectName: "context-meter-demo",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: ActivityFixture.editing,
            usage: UsageFixture.medium,
            age: ClockFixture.sixHours,
            model: "claude-opus-5",
            lastRequestUsage: RequestUsageFixture.single,
            serviceTier: "standard",
            recordsParsed: 58,
            toolCounts: ToolMixFixture.varied,
            filePaths: FilePathFixture.several,
            activityTrail: TrailFixture.atCap
        )
    }

    /// Same known model, but no assistant record with a usage block has been
    /// read yet: the *other* unavailable reason, not the table-coverage one.
    static var contextNoRequestYet: AISession {
        make(
            id: "preview-context-no-request",
            projectName: "context-meter-demo",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: ActivityFixture.editing,
            usage: UsageFixture.small,
            age: ClockFixture.elevenMinutes,
            model: "claude-opus-5",
            lastRequestUsage: nil
        )
    }

    /// A model this build's context table does not size at all.
    /// `lastRequestUsage` is still populated, to make plain that the gap is
    /// the model, not a missing request: the well shows the amount in use with
    /// no bar and no percentage, which is the third `ContextReading`.
    static var contextUnknownModel: AISession {
        make(
            id: "preview-context-unknown-model",
            projectName: "context-meter-demo",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: ActivityFixture.editing,
            usage: UsageFixture.small,
            age: ClockFixture.elevenMinutes,
            model: "claude-preview-9",
            lastRequestUsage: RequestUsageFixture.single
        )
    }

    /// As little as this build can derive: no model record, no pid, nothing.
    /// Exercises the facts tiles that depend on a fact other than status ever
    /// having been read, as opposed to `noData`, which still has a pid and a
    /// model.
    static var noProcessRecord: AISession {
        make(
            id: "preview-no-process",
            projectName: "orphaned-transcript",
            workingDirectory: PathFixture.short,
            status: .running,
            activity: nil,
            usage: UsageFixture.none,
            age: ClockFixture.elevenMinutes,
            model: nil,
            pid: 0
        )
    }

    static let all: [AISession] = []
}

/// Wraps a preview at the real popover width so layout problems show up here
/// rather than in the shipped app.
private struct PreviewFrame<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            Text(title.uppercased())
                .font(Theme.Typography.section)
                .tracking(Theme.sectionTracking)
                .foregroundStyle(Theme.textTertiary)
            content
        }
        .padding(Theme.Layout.popoverPadding)
        .frame(width: Theme.Layout.popoverWidth)
        .background(Theme.surface)
    }
}

// MARK: - PowerHero

struct PowerHeroSeverityRampPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "PowerHero severity") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PowerHero(
                    title: "Claude Power \u{00B7} 5h window",
                    percentUsed: PercentFixture.healthy,
                    resetsAt: ClockFixture.soon
                )
                PowerHero(
                    title: "Claude Power \u{00B7} 5h window",
                    percentUsed: PercentFixture.attention,
                    resetsAt: ClockFixture.veryClose
                )
                PowerHero(
                    title: "Claude Power \u{00B7} 5h window",
                    percentUsed: PercentFixture.warning,
                    resetsAt: ClockFixture.distant
                )
                PowerHero(
                    title: "Claude Power \u{00B7} 5h window",
                    percentUsed: PercentFixture.critical,
                    resetsAt: ClockFixture.soon
                )
            }
        }
        .previewDisplayName("PowerHero / severity ramp")
    }
}

struct PowerHeroExtremesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "PowerHero extremes") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // Exactly zero: an empty track, no minimum dot.
                PowerHero(title: "Empty", percentUsed: PercentFixture.empty)
                // Exactly full, and a three-digit number against the pill.
                PowerHero(
                    title: "Full",
                    percentUsed: PercentFixture.full,
                    resetsAt: ClockFixture.veryClose
                )
                // Over 100 from the source: clamps rather than overflowing.
                PowerHero(title: "Overflowing source", percentUsed: PercentFixture.overflowing)
                // Reset already passed: no right-hand column at all, not "0s".
                PowerHero(
                    title: "Reset already passed",
                    percentUsed: PercentFixture.attention,
                    resetsAt: ClockFixture.passed
                )
                // A title long enough to have to truncate beside the reset column.
                PowerHero(
                    title: "7 Day Claude Opus 4 5 Extended Thinking Window",
                    percentUsed: PercentFixture.warning,
                    resetsAt: ClockFixture.soon
                )
            }
        }
        .previewDisplayName("PowerHero / extremes")
    }
}

struct PowerHeroUnavailablePreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "PowerHero unavailable") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // No reading and no rollover: the panel keeps its shape and
                // says so, and draws no track that could read as zero.
                PowerHero(title: "Claude Power", percentUsed: PercentFixture.unavailable)
                // The rollover resolved and the percentage did not. One absent
                // fact is no reason to withhold the other.
                PowerHero(
                    title: "Claude Power",
                    percentUsed: PercentFixture.unavailable,
                    resetsAt: ClockFixture.soon
                )
            }
        }
        .previewDisplayName("PowerHero / unavailable")
    }
}

// MARK: - PowerBar

struct PowerBarSeverityRampPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "PowerBar severity") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PowerBar(
                    title: "Claude Power",
                    percentUsed: PercentFixture.healthy,
                    resetsAt: ClockFixture.soon
                )
                PowerBar(
                    title: "5 Hour",
                    percentUsed: PercentFixture.attention,
                    resetsAt: ClockFixture.veryClose
                )
                PowerBar(
                    title: "7 Day",
                    percentUsed: PercentFixture.warning,
                    resetsAt: ClockFixture.distant
                )
                PowerBar(
                    title: "7 Day Claude Opus 4 5",
                    percentUsed: PercentFixture.critical,
                    resetsAt: ClockFixture.soon
                )
            }
        }
        .previewDisplayName("PowerBar / severity ramp")
    }
}

struct PowerBarExtremesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "PowerBar extremes") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                // Exactly zero: an empty track, no minimum dot.
                PowerBar(title: "Empty", percentUsed: PercentFixture.empty)
                // Exactly full.
                PowerBar(title: "Full", percentUsed: PercentFixture.full)
                // Over 100 from the source: clamps rather than overflowing the row.
                PowerBar(title: "Overflowing source", percentUsed: PercentFixture.overflowing)
                // Reset already passed: no caption at all, not "Reset in 0s".
                PowerBar(
                    title: "Reset already passed",
                    percentUsed: PercentFixture.attention,
                    resetsAt: ClockFixture.passed
                )
                // Long title in a 300 pt popover.
                PowerBar(
                    title: "7 Day Claude Opus 4 5 Extended Thinking Window",
                    percentUsed: PercentFixture.warning,
                    resetsAt: ClockFixture.soon
                )
            }
        }
        .previewDisplayName("PowerBar / extremes")
    }
}

struct PowerBarUnavailablePreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "PowerBar unavailable") {
            PowerBar(title: "Claude Power", percentUsed: PercentFixture.unavailable)
        }
        .previewDisplayName("PowerBar / unavailable")
    }
}

// MARK: - EnergyRing

struct EnergyRingSeverityRampPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "EnergyRing severity") {
            VStack(spacing: Theme.Space.xl) {
                EnergyRing(
                    title: "Claude Power",
                    percentUsed: PercentFixture.healthy,
                    resetsAt: ClockFixture.soon
                )
                EnergyRing(
                    title: "5 Hour",
                    percentUsed: PercentFixture.attention,
                    resetsAt: ClockFixture.veryClose
                )
                EnergyRing(
                    title: "7 Day",
                    percentUsed: PercentFixture.warning,
                    resetsAt: ClockFixture.distant
                )
                EnergyRing(
                    title: "Weekly cap",
                    percentUsed: PercentFixture.critical,
                    resetsAt: ClockFixture.soon
                )
            }
            .frame(maxWidth: .infinity)
        }
        .previewDisplayName("EnergyRing / severity ramp")
    }
}

struct EnergyRingExtremesAndUnavailablePreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "EnergyRing extremes") {
            VStack(spacing: Theme.Space.xl) {
                EnergyRing(title: "Empty", percentUsed: PercentFixture.empty)
                EnergyRing(title: "Full", percentUsed: PercentFixture.full)
                EnergyRing(title: "Clamped", percentUsed: PercentFixture.overflowing)
                EnergyRing(title: "Claude Power", percentUsed: PercentFixture.unavailable)
            }
            .frame(maxWidth: .infinity)
        }
        .previewDisplayName("EnergyRing / extremes and unavailable")
    }
}

// MARK: - RingMark

struct RingMarkReadingsPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Ring mark") {
            // The header size, then the menu bar size, at each reading. The
            // last column in both rows is the unknown state: a broken ring, so
            // it is told apart from the measured zero beside it by silhouette
            // rather than by hue.
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                HStack(spacing: Theme.Space.xl) {
                    RingMark(percentUsed: PercentFixture.empty, size: Theme.Bar.markHeader, showsCore: true)
                    RingMark(percentUsed: PercentFixture.healthy, size: Theme.Bar.markHeader, showsCore: true)
                    RingMark(percentUsed: PercentFixture.warning, size: Theme.Bar.markHeader, showsCore: true)
                    RingMark(percentUsed: PercentFixture.full, size: Theme.Bar.markHeader, showsCore: true)
                    RingMark(percentUsed: PercentFixture.unavailable, size: Theme.Bar.markHeader, showsCore: true)
                }
                HStack(spacing: Theme.Space.xl) {
                    RingMark(percentUsed: PercentFixture.empty, size: Theme.MenuBar.glyphSize)
                    RingMark(percentUsed: PercentFixture.healthy, size: Theme.MenuBar.glyphSize)
                    RingMark(percentUsed: PercentFixture.warning, size: Theme.MenuBar.glyphSize)
                    RingMark(percentUsed: PercentFixture.full, size: Theme.MenuBar.glyphSize)
                    RingMark(percentUsed: PercentFixture.unavailable, size: Theme.MenuBar.glyphSize)
                }
            }
        }
        .previewDisplayName("RingMark / readings")
    }
}

// MARK: - StatusPill

struct StatusPillPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Status pill") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // Every severity: four glyph shapes, four words.
                HStack(spacing: Theme.Space.m) {
                    ForEach(Severity.allCases, id: \.self) { severity in
                        StatusPill(severity: severity)
                    }
                }
                // Every session state against one identity, including the one
                // with no data source behind it.
                HStack(spacing: Theme.Space.m) {
                    ForEach(SessionFixture.all) { session in
                        StatusPill(
                            status: session.status,
                            identity: Theme.identity(forSessionID: session.id)
                        )
                    }
                    StatusPill(
                        status: SessionFixture.underivableStatus.status,
                        identity: Theme.identity(forSessionID: SessionFixture.underivableStatus.id)
                    )
                }
            }
        }
        .previewDisplayName("StatusPill / severities and statuses")
    }
}

// MARK: - TokenBar

struct TokenBarCollapsedAndExpandedPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "TokenBar") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                TokenBar(
                    usage: UsageFixture.small,
                    scaleMaximum: UsageFixture.smallScale
                )
                TokenBar(
                    usage: UsageFixture.medium,
                    scaleMaximum: UsageFixture.mediumScale,
                    startsExpanded: true
                )
            }
        }
        .previewDisplayName("TokenBar / collapsed and expanded")
    }
}

struct TokenBarExtremesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "TokenBar extremes") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                // Millions of tokens: formatting and column width.
                TokenBar(
                    usage: UsageFixture.enormous,
                    scaleMaximum: UsageFixture.enormousScale,
                    startsExpanded: true
                )
                // A real zero reading, which is not the same as no reading.
                TokenBar(
                    usage: UsageFixture.none,
                    scaleMaximum: UsageFixture.smallScale,
                    startsExpanded: true
                )
                // No scale maximum: value only, no bar, because a fill would imply
                // a denominator we do not have.
                TokenBar(usage: UsageFixture.small)
                // Severity supplied by a caller that does have a context percentage.
                TokenBar(
                    usage: UsageFixture.medium,
                    scaleMaximum: UsageFixture.mediumScale,
                    severity: .critical
                )
            }
        }
        .previewDisplayName("TokenBar / extremes")
    }
}

struct TokenBarUnavailablePreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "TokenBar unavailable") {
            TokenBar(usage: nil, scaleMaximum: UsageFixture.smallScale)
        }
        .previewDisplayName("TokenBar / unavailable")
    }
}

// MARK: - Sparkline

struct SparklineShapesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Sparkline") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                Sparkline(SeriesFixture.rising, label: "Token rate")
                Sparkline(SeriesFixture.noisy, style: .bar, label: "Token rate")
                Sparkline(SeriesFixture.flat, label: "Token rate")
                Sparkline(SeriesFixture.flat, style: .bar, label: "Token rate")
                // Neither of the next two draws anything at all.
                Sparkline(SeriesFixture.singlePoint, label: "Token rate")
                Sparkline(SeriesFixture.empty, label: "Token rate")
                // Same series at the small width a session row gives it.
                Sparkline(SeriesFixture.noisy, label: "Token rate")
                    .frame(width: Theme.Bar.sparklineWidth)
            }
        }
        .previewDisplayName("Sparkline / shapes")
    }
}

// MARK: - StatusIndicator

struct StatusIndicatorAllStatesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "StatusIndicator") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // The three states with a proven data source.
                StatusIndicator(.running)
                StatusIndicator(.idle)
                StatusIndicator(.completed)
                // The three that are not derivable: explicit fallback, never a
                // guess dressed up as a state.
                StatusIndicator(.waiting)
                StatusIndicator(.permission)
                StatusIndicator(.error)
                // Glyph-only form used inside a session row header.
                HStack(spacing: Theme.Space.l) {
                    StatusIndicator(.running, showsText: false)
                    StatusIndicator(.idle, showsText: false)
                    StatusIndicator(.completed, showsText: false)
                    StatusIndicator(.error, showsText: false)
                }
            }
        }
        .previewDisplayName("StatusIndicator / all states")
    }
}

// MARK: - UnavailableView

struct UnavailableViewPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Unavailable") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                UnavailableView()
                UnavailableView("Usage unavailable", reason: "Keychain access was denied")
                UnavailableView("Activity unavailable", compact: true)
                UnavailableView(
                    "Usage unavailable",
                    reason: "No network connection since the last successful read",
                    compact: false
                )
            }
        }
        .previewDisplayName("UnavailableView")
    }
}

// MARK: - SessionRow

struct SessionRowStatesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Sessions") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SessionRow(
                    session: SessionFixture.working,
                    tokenScaleMaximum: UsageFixture.smallScale,
                    burnRatePerMinute: SeriesFixture.rate,
                    burnHistory: SeriesFixture.rising
                )
                Divider().overlay(Theme.separator)
                SessionRow(
                    session: SessionFixture.idle,
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    burnRatePerMinute: SeriesFixture.slowRate,
                    burnHistory: SeriesFixture.noisy
                )
                Divider().overlay(Theme.separator)
                SessionRow(
                    session: SessionFixture.completed,
                    tokenScaleMaximum: UsageFixture.smallScale
                )
            }
        }
        .previewDisplayName("SessionRow / states")
    }
}

struct SessionRowExpandedPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session expanded") {
            SessionRow(
                session: SessionFixture.working,
                tokenScaleMaximum: UsageFixture.smallScale,
                burnRatePerMinute: SeriesFixture.rate,
                burnHistory: SeriesFixture.rising,
                startsExpanded: true
            )
        }
        .previewDisplayName("SessionRow / expanded")
    }
}

struct SessionRowExtremesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session extremes") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                // Very long project name and a path that must truncate from the head.
                SessionRow(
                    session: SessionFixture.longPath,
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    burnRatePerMinute: SeriesFixture.rate,
                    burnHistory: SeriesFixture.noisy,
                    startsExpanded: true
                )
                Divider().overlay(Theme.separator)
                // Millions of tokens.
                SessionRow(
                    session: SessionFixture.enormousTokens,
                    tokenScaleMaximum: UsageFixture.enormousScale,
                    burnRatePerMinute: SeriesFixture.rate,
                    burnHistory: SeriesFixture.rising,
                    startsExpanded: true
                )
                Divider().overlay(Theme.separator)
                // Nothing read yet: no activity, no burn rate, no sparkline, and no
                // bar, because there is no scale to measure against.
                SessionRow(session: SessionFixture.noData, startsExpanded: true)
                Divider().overlay(Theme.separator)
                // A status with no data source behind it.
                SessionRow(
                    session: SessionFixture.underivableStatus,
                    tokenScaleMaximum: UsageFixture.smallScale
                )
            }
        }
        .previewDisplayName("SessionRow / extremes")
    }
}

struct SessionRowZeroSessionsPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Live sessions") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(SessionFixture.all) { session in
                    SessionRow(session: session, tokenScaleMaximum: UsageFixture.smallScale)
                }
                if SessionFixture.all.isEmpty {
                    UnavailableView(
                        "No live sessions",
                        reason: "Claude Code is not running, or no session is interactive"
                    )
                }
            }
        }
        .previewDisplayName("SessionRow / zero sessions")
    }
}

// MARK: - Composite

struct PopoverCompositionPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Claudence") {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PowerBar(
                    title: "Claude Power",
                    percentUsed: PercentFixture.warning,
                    resetsAt: ClockFixture.soon
                )
                Divider().overlay(Theme.separator)
                SessionRow(
                    session: SessionFixture.working,
                    tokenScaleMaximum: UsageFixture.smallScale,
                    burnRatePerMinute: SeriesFixture.rate,
                    burnHistory: SeriesFixture.rising
                )
                SessionRow(
                    session: SessionFixture.idle,
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    burnRatePerMinute: SeriesFixture.slowRate,
                    burnHistory: SeriesFixture.noisy
                )
            }
        }
        .previewDisplayName("Popover composition")
    }
}

// MARK: - ActivityTimelineView

struct ActivityTimelineEmptyPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Activity timeline") {
            ActivityTimelineView(trail: TrailFixture.empty)
        }
        .previewDisplayName("ActivityTimelineView / empty")
    }
}

struct ActivityTimelineAtCapPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Activity timeline") {
            // 24 entries in, the engine's own cap; the view's default limit
            // of 8 then trims that down to the newest handful.
            ActivityTimelineView(trail: TrailFixture.atCap)
        }
        .previewDisplayName("ActivityTimelineView / at cap")
    }
}

// MARK: - SessionFactsView

struct SessionFactsPopulatedPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session facts") {
            SessionFactsView(session: SessionFixture.withSubagents)
        }
        .previewDisplayName("SessionFactsView / populated")
    }
}

struct SessionFactsGapsPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session facts") {
            // This fixture has no model and no branch read yet, so both of
            // its non-clock tiles are honest gaps rather than a guess.
            SessionFactsView(session: SessionFixture.noProcessRecord)
        }
        .previewDisplayName("SessionFactsView / gaps")
    }
}

// MARK: - SubagentListView

struct SubagentListEmptyPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Subagents") {
            // Most sessions spawn nothing; the parent total is irrelevant
            // when the list itself is empty.
            SubagentListView(subagents: SubagentFixture.empty, parentTotal: 0)
        }
        .previewDisplayName("SubagentListView / empty")
    }
}

struct SubagentListSeveralPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Subagents") {
            SubagentListView(
                subagents: SubagentFixture.several,
                parentTotal: SubagentFixture.severalParentTotal
            )
        }
        .previewDisplayName("SubagentListView / several")
    }
}

struct SubagentListMissingLabelsPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Subagents") {
            // The second row's `meta.json` never resolved: both its agent
            // type and its task description fall back to unavailable wording.
            SubagentListView(
                subagents: SubagentFixture.withUnlabeled,
                parentTotal: SubagentFixture.withUnlabeledParentTotal
            )
        }
        .previewDisplayName("SubagentListView / missing labels")
    }
}

// MARK: - QuickActionsMenu

struct QuickActionsMenuOutcomesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Quick actions") {
            // Never `.system`: every closure is a pure return, and each
            // button demonstrates a different `SessionActionOutcome` case -
            // Terminal unavailable, Project done, Copy Path failed, Stop
            // already-stopped - so all four tones are visible without this
            // preview ever touching Terminal, Finder, the pasteboard or a
            // real process.
            QuickActionsMenu(session: SessionFixture.working, actions: QuickActionsFixture.mixedOutcomes)
        }
        .previewDisplayName("QuickActionsMenu / every outcome tone")
    }
}

// MARK: - SessionDetailView

struct SessionDetailWithSubagentsPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session detail") {
            SessionDetailView(
                session: SessionFixture.withSubagents,
                subagents: SubagentFixture.several,
                tokenScaleMaximum: UsageFixture.mediumScale,
                burnRatePerMinute: SeriesFixture.rate,
                burnHistory: SeriesFixture.rising,
                windowShare: WindowShareFixture.strong,
                onClose: {}
            )
        }
        .previewDisplayName("SessionDetailView / with subagents")
    }
}

struct SessionDetailNoSubagentsPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session detail") {
            SessionDetailView(
                session: SessionFixture.working,
                subagents: SubagentFixture.empty,
                tokenScaleMaximum: UsageFixture.smallScale,
                burnRatePerMinute: SeriesFixture.rate,
                burnHistory: SeriesFixture.rising,
                onClose: {}
            )
        }
        .previewDisplayName("SessionDetailView / no subagents")
    }
}

struct SessionDetailNothingReadYetPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session detail") {
            // No activity, no tool calls, no files, no burn history: every
            // unavailable state in the scroll at once, plus a real (not
            // unavailable) zero for cost, since a priced model at zero usage
            // is a genuine $0.00, not a gap.
            SessionDetailView(session: SessionFixture.noData, onClose: {})
        }
        .previewDisplayName("SessionDetailView / nothing read yet")
    }
}

struct SessionDetailContextFilledPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session detail") {
            SessionDetailView(
                session: SessionFixture.contextFilled,
                tokenScaleMaximum: UsageFixture.mediumScale,
                burnRatePerMinute: SeriesFixture.rate,
                burnHistory: SeriesFixture.rising,
                onClose: {}
            )
        }
        .previewDisplayName("SessionDetailView / context meter filled")
    }
}

struct SessionDetailContextNoRequestYetPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session detail") {
            SessionDetailView(
                session: SessionFixture.contextNoRequestYet,
                tokenScaleMaximum: UsageFixture.smallScale,
                onClose: {}
            )
        }
        .previewDisplayName("SessionDetailView / context, no request yet")
    }
}

struct SessionDetailContextUnknownModelPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session detail") {
            SessionDetailView(
                session: SessionFixture.contextUnknownModel,
                tokenScaleMaximum: UsageFixture.smallScale,
                onClose: {}
            )
        }
        .previewDisplayName("SessionDetailView / context, model not in table")
    }
}

// MARK: - Window identity, caption and label

/// The three usage windows as the design paints them: one identity each, at
/// readings that are all Healthy, so nothing here separates by severity.
struct PowerWindowIdentitiesPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Usage windows") {
            VStack(alignment: .leading, spacing: Theme.Popover.secondaryGap) {
                PowerHero(
                    title: "Claude Power \u{00B7} 5h window",
                    windowName: "five_hour",
                    percentUsed: 24,
                    resetsAt: ClockFixture.soon
                )
                PowerBar(
                    title: "7 day",
                    windowName: "seven_day",
                    percentUsed: 13,
                    resetsAt: ClockFixture.distant
                )
                PowerBar(
                    title: "Fable",
                    caption: "weekly scoped",
                    windowName: "seven_day_fable",
                    percentUsed: 1,
                    resetsAt: ClockFixture.distant
                )
            }
        }
        .previewDisplayName("PowerBar / three window identities")
    }
}

// MARK: - Session row, path line

/// The path line with and without a branch. `AISession.gitBranch` is nil until
/// a transcript record carrying one has been read, so a session shown right
/// after launch renders the second, branchless state honestly rather than
/// waiting to draw the first.
struct SessionRowBranchPreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session row / path line") {
            VStack(spacing: Theme.Popover.listGap) {
                SessionRow(
                    session: SessionFixture.working,
                    gitBranch: "main",
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    burnRatePerMinute: SeriesFixture.rate,
                    burnHistory: SeriesFixture.rising,
                    onOpen: {}
                )
                SessionRow(
                    session: SessionFixture.longPath,
                    gitBranch: "feat/leave-quota-rounding",
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    onOpen: {}
                )
                SessionRow(
                    session: SessionFixture.idle,
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    onOpen: {}
                )
            }
        }
        .previewDisplayName("SessionRow / path with and without a branch")
    }
}

/// The meta line's two honest states. A session under two minutes old has fewer
/// than two burn samples, so the rate reads `Rate unavailable` and no sparkline
/// draws at all. Neither is a defect and neither is filled in with a zero.
struct SessionRowMetaLinePreview: PreviewProvider {
    static var previews: some View {
        PreviewFrame(title: "Session row / meta line") {
            VStack(spacing: Theme.Popover.listGap) {
                SessionRow(
                    session: SessionFixture.working,
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    burnRatePerMinute: SeriesFixture.rate,
                    burnHistory: SeriesFixture.rising,
                    onOpen: {}
                )
                SessionRow(
                    session: SessionFixture.working,
                    tokenScaleMaximum: UsageFixture.mediumScale,
                    burnRatePerMinute: nil,
                    burnHistory: SeriesFixture.singlePoint,
                    onOpen: {}
                )
            }
        }
        .previewDisplayName("SessionRow / meta line, with and without a series")
    }
}

// MARK: - Freshness stamp

/// Every shape the popover header's stamp takes. Rendered from fixed ages so
/// the preview does not move, which is also the only way to see them together.
struct FreshnessStampPreview: PreviewProvider {
    private static let ages: [TimeInterval] = [0, 3, 30, 55, 90, 34 * 60, 2 * 3_600, 3 * 86_400]

    static var previews: some View {
        PreviewFrame(title: "Freshness stamp") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                ForEach(ages, id: \.self) { age in
                    HStack(spacing: Theme.Popover.headerTrailingGap) {
                        Text("\(Int(age))s old")
                            .font(Theme.Typography.help)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: Theme.Space.s)
                        Text(
                            MenuBarContent.freshness(
                                of: Date().addingTimeInterval(-age),
                                at: Date()
                            )
                        )
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.textQuaternary)
                    }
                }
            }
        }
        .previewDisplayName("Popover header / freshness stamp")
    }
}

// MARK: - Render fixtures

/// The session detail the offscreen renderer draws, and the values it needs
/// alongside it. Same seam as `DashboardRenderFixture`, for the same reason.
enum DetailRenderFixture {
    static let session = SessionFixture.withSubagents
    static let subagents = SubagentFixture.several
    static let tokenScaleMaximum = UsageFixture.mediumScale
    static let burnRatePerMinute = SeriesFixture.rate
    static let burnHistory = SeriesFixture.rising
    static let windowShare = WindowShareFixture.strong
}
