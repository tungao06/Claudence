import SwiftUI
import ClaudenceCore

/// One session rendered as a compact energy cell.
///
/// Priority order, top to bottom, fixed by spec section 7.2:
/// status, project, working directory, activity, token energy, then duration
/// and burn rate on one quiet trailing line.
///
/// The row has two behaviours, chosen by whether a caller passes `onOpen`.
/// With one, the row is a door: the whole header opens the detail overlay,
/// which is where the breakdown, the subagent split and the facts now live.
/// Without one it keeps its original in-place disclosure, which is what the
/// previews and the dashboard grid still use.
///
/// `isCompact` is the design's `Compact rows` setting. It hides the trailing
/// line only, which is what that setting's own explanation promises: duration,
/// rate and sparkline. The energy bar stays, because a session list with no
/// energy in it is no longer the thing this product is.
///
/// The bar measures `combinedUsage`, not `usage`. A session's subagents have no
/// process of their own and their tokens are billed to the parent, so the parent
/// transcript alone under-reports: measured on this repository, by 41%.
struct SessionRow: View {
    let session: AISession
    /// Value that fills the token bar. Nil draws no bar rather than a ratio we
    /// cannot justify.
    let tokenScaleMaximum: Int?
    /// Tokens per minute over a rolling window. Nil is an ordinary state.
    let burnRatePerMinute: Double?
    /// Recent burn samples for the sparkline. Fewer than two draws nothing.
    let burnHistory: [Double]
    /// Hides duration, rate and sparkline. Taken as a parameter rather than
    /// read from `Preferences` so the flag has one owner and a preview can
    /// drive it.
    let isCompact: Bool
    /// Opens the detail overlay. Nil keeps the row's original in-place
    /// disclosure instead.
    let onOpen: (() -> Void)?
    /// The user's `Live indicators` setting. Off stills the status glyph.
    let isLive: Bool

    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: AISession,
        tokenScaleMaximum: Int? = nil,
        burnRatePerMinute: Double? = nil,
        burnHistory: [Double] = [],
        startsExpanded: Bool = false,
        isCompact: Bool = false,
        isLive: Bool = true,
        onOpen: (() -> Void)? = nil
    ) {
        self.session = session
        self.tokenScaleMaximum = tokenScaleMaximum
        self.burnRatePerMinute = burnRatePerMinute
        self.burnHistory = burnHistory
        self.isCompact = isCompact
        self.isLive = isLive
        self.onOpen = onOpen
        _isExpanded = State(initialValue: startsExpanded)
    }

    /// A three-second bucket of the last activity, not the timestamp itself.
    ///
    /// The pulse means "something just happened", and it is a 0.55 s dip. Fed
    /// the raw `lastActivityAt`, it retriggered on every transcript event,
    /// which is about four a second while a session streams: the dip never
    /// completed and the glyph stayed dim, which says the opposite of what the
    /// motion is for. Bucketing gives at most one dip per bucket and leaves the
    /// glyph at rest in between.
    private var activityToken: AnyHashable {
        Int(session.lastActivityAt.timeIntervalSince1970 / 3)
    }

    /// A row that opens a detail view has nothing left to disclose in place, so
    /// its trailing line is governed by the compact setting alone.
    private var showsTrailingLine: Bool {
        guard !isCompact else { return false }
        return onOpen == nil ? isExpanded : true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            header
            path
            activity
            TokenBar(
                usage: session.combinedUsage,
                scaleMaximum: tokenScaleMaximum,
                isExpandable: onOpen == nil,
                expansion: onOpen == nil ? $isExpanded : nil
            )
            .padding(.top, Theme.Space.xxs)
            if showsTrailingLine {
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
            if let onOpen { onOpen() } else { isExpanded.toggle() }
        } label: {
            HStack(spacing: Theme.Space.s) {
                StatusIndicator(
                    session.status,
                    showsText: false,
                    activityToken: activityToken,
                    isLive: isLive
                )
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
                    .rotationEffect(
                        .degrees(onOpen == nil && isExpanded ? Theme.Motion.disclosureRotation : 0)
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerLabel)
        .accessibilityHint(headerHint)
        .accessibilityAddTraits(.isButton)
    }

    private var headerHint: String {
        guard onOpen == nil else { return "Opens the full detail for this session" }
        return isExpanded ? "Collapse session details" : "Expand session details"
    }

    private var headerLabel: String {
        let state = session.status.isDerivable
            ? Theme.name(for: session.status)
            : "state unsupported"
        return "\(session.projectName), \(state), \(Format.tokens(session.combinedUsage.total)) tokens"
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
