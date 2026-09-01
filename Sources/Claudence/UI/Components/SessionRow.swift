import SwiftUI
import ClaudenceCore

/// One session rendered as a compact energy cell.
///
/// Priority order, top to bottom, fixed by spec section 7.2:
/// status, project, working directory, activity, token energy, then duration
/// and burn rate on one quiet trailing line. Everything below the activity line
/// is progressively disclosed, so at rest the row answers "what is it doing and
/// how much energy has it used" and nothing more.
struct SessionRow: View {
    let session: AISession
    /// Value that fills the token bar. Nil draws no bar rather than a ratio we
    /// cannot justify.
    let tokenScaleMaximum: Int?
    /// Tokens per minute over a rolling window. Nil is an ordinary state.
    let burnRatePerMinute: Double?
    /// Recent burn samples for the sparkline. Fewer than two draws nothing.
    let burnHistory: [Double]

    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: AISession,
        tokenScaleMaximum: Int? = nil,
        burnRatePerMinute: Double? = nil,
        burnHistory: [Double] = [],
        startsExpanded: Bool = false
    ) {
        self.session = session
        self.tokenScaleMaximum = tokenScaleMaximum
        self.burnRatePerMinute = burnRatePerMinute
        self.burnHistory = burnHistory
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            header
            path
            activity
            TokenBar(
                usage: session.usage,
                scaleMaximum: tokenScaleMaximum,
                expansion: $isExpanded
            )
            .padding(.top, Theme.Space.xxs)
            if isExpanded {
                trailingLine
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(
            Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
            value: isExpanded
        )
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: Theme.Space.s) {
                StatusIndicator(session.status, showsText: false)
                Text(session.projectName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Theme.Space.xs)
                // The status word travels with the header so the glyph is never
                // the only thing carrying the state.
                Text(Theme.name(for: session.status))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    // Outranks the project name for space: the state word is
                    // what keeps the glyph from being colour alone, so it must
                    // survive even when the project name has to truncate.
                    .layoutPriority(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? Theme.Motion.disclosureRotation : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerLabel)
        .accessibilityHint(isExpanded ? "Collapse session details" : "Expand session details")
        .accessibilityAddTraits(.isButton)
    }

    private var headerLabel: String {
        let state = session.status.isDerivable
            ? Theme.name(for: session.status)
            : "state unsupported"
        return "\(session.projectName), \(state), \(Format.tokens(session.usage.total)) tokens"
    }

    // MARK: - Path

    private var path: some View {
        // Truncate from the head: the tail of a path is the part that
        // identifies the project.
        Text(session.displayPath)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Working directory \(session.displayPath)")
    }

    // MARK: - Activity

    @ViewBuilder
    private var activity: some View {
        if let activity = session.currentActivity {
            Text(activity.display)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Activity, \(activity.display)")
        } else {
            UnavailableView("Activity unavailable", compact: true)
        }
    }

    // MARK: - Trailing line

    private var trailingLine: some View {
        HStack(spacing: Theme.Space.s) {
            Text(Format.duration(session.duration))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Text("·")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Text(burnRateText)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            if Sparkline.canRender(burnHistory) {
                Sparkline(burnHistory, label: "Token rate")
                    .frame(width: Theme.Bar.sparklineWidth)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Running for \(Format.duration(session.duration)). \(burnRateSpokenText)"
        )
    }

    private var burnRateText: String {
        guard let rate = burnRatePerMinute else { return "Rate unavailable" }
        return "\(Format.tokens(Int(rate.rounded())))/min"
    }

    private var burnRateSpokenText: String {
        guard let rate = burnRatePerMinute else { return "Burn rate unavailable." }
        return "Burn rate \(Format.tokens(Int(rate.rounded()))) tokens per minute."
    }
}
