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

private enum SessionFixture {
    private static func make(
        id: String,
        projectName: String,
        workingDirectory: String,
        status: SessionStatus,
        activity: Activity?,
        usage: TokenUsage,
        age: TimeInterval
    ) -> AISession {
        AISession(
            id: id,
            pid: 42_541,
            procStart: "Tue Sep  1 19:27:02 2026",
            projectName: projectName,
            workingDirectory: workingDirectory,
            status: status,
            currentActivity: activity,
            startedAt: Date().addingTimeInterval(-age),
            lastActivityAt: Date(),
            usage: usage,
            model: "claude-sonnet-5",
            claudeCodeVersion: "2.1.257"
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
        PreviewFrame(title: "Active sessions") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                ForEach(SessionFixture.all) { session in
                    SessionRow(session: session, tokenScaleMaximum: UsageFixture.smallScale)
                }
                if SessionFixture.all.isEmpty {
                    UnavailableView(
                        "No active sessions",
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
