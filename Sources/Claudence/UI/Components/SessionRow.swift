import SwiftUI
import ClaudenceCore

/// One session as a card.
///
/// Five rows, in the order design section 5.5 fixes and spec section 7.2
/// agrees with: header, path, activity, energy, then the quiet meta line.
/// The card is a real container now, with its own surface, border and radius,
/// which is what lets several of them stack in a list and still read as
/// separate machines rather than as one long column of text.
///
/// The row has two behaviours, chosen by whether a caller passes `onOpen`.
/// With one, the row is a door: the whole header opens the detail overlay,
/// which is where the breakdown, the subagent split and the facts now live.
/// Without one it keeps its original in-place disclosure, which is what the
/// previews and the dashboard grid still use.
///
/// Those two behaviours are also why the energy row has two forms. A door's
/// energy row is the design's: a bar and a right-aligned total on one line. A
/// disclosing row's energy is `TokenBar`, which owns the only definition of the
/// four-way token breakdown in the product; giving this file its own copy so
/// both forms could look identical would have created a second place for the
/// cache split to drift out of step with the bill.
///
/// `isCompact` is the design's `Compact rows` setting. It hides the trailing
/// line only, which is what that setting's own explanation promises: duration,
/// rate and sparkline. Design section 5.5 says the setting hides the energy row
/// as well; the two disagree, and the explanation wins, because it is the text
/// the person reading the switch actually sees. The energy row also stays
/// because a session list with no energy in it is no longer the thing this
/// product is.
///
/// The bar measures `combinedUsage`, not `usage`. A session's subagents have no
/// process of their own and their tokens are billed to the parent, so the parent
/// transcript alone under-reports: measured on this repository, by 41%.
struct SessionRow: View {
    let session: AISession
    /// The branch the session is working on, shown after the path exactly as
    /// the design has it: `~/project/Claudence \u{00B7} main`.
    ///
    /// A parameter rather than a field read off `session`, so a caller with a
    /// better source than the transcript can supply one. `AISession.gitBranch`
    /// is the ordinary source and is what `MenuBarContent` passes; nil renders
    /// the path alone, which is also correct for a directory that is not a git
    /// working tree. It never invents a branch, and there is no default that
    /// could.
    let gitBranch: String?
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
    @Environment(\.liveIndicators) private var liveIndicators

    init(
        session: AISession,
        gitBranch: String? = nil,
        tokenScaleMaximum: Int? = nil,
        burnRatePerMinute: Double? = nil,
        burnHistory: [Double] = [],
        startsExpanded: Bool = false,
        isCompact: Bool = false,
        isLive: Bool = true,
        onOpen: (() -> Void)? = nil
    ) {
        self.session = session
        self.gitBranch = gitBranch
        self.tokenScaleMaximum = tokenScaleMaximum
        self.burnRatePerMinute = burnRatePerMinute
        self.burnHistory = burnHistory
        self.isCompact = isCompact
        self.isLive = isLive
        self.onOpen = onOpen
        _isExpanded = State(initialValue: startsExpanded)
    }

    /// Which of the three identity colours this session carries. Identity, not
    /// state: it answers "whose row is this" across a list, and every reading of
    /// how the session is doing is carried by a glyph and a word instead.
    private var identity: Theme.SessionIdentity {
        Theme.identity(forSessionID: session.id)
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

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Popover.rowGap) {
            header
            path
            activity
            energy
            if showsTrailingLine {
                trailingLine
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Theme.Popover.rowPaddingHorizontal)
        .padding(.vertical, Theme.Popover.rowPaddingVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised, in: cardShape)
        .overlay(cardShape.strokeBorder(Theme.borderCard))
        .contentShape(cardShape)
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
            HStack(spacing: Theme.Popover.headerMarkGap) {
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
                StatusPill(status: session.status, identity: identity)
                    // Outranks the project name for space: the state word is
                    // what keeps the glyph from being colour alone, so it must
                    // survive even when the project name has to truncate.
                    .layoutPriority(1)
                // The design's chevron is the character `\u{203A}`, not an
                // icon, and it is painted in the punctuation ink rather than in
                // a text one: it is structure, not content.
                Text(Theme.Glyph.chevron)
                    .font(Theme.Typography.chevron)
                    .foregroundStyle(Theme.textDisabled)
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
        HStack(spacing: Theme.Popover.rowPathGap) {
            // Truncate from the head: the tail of a path is the part that
            // identifies the project.
            Text(session.displayPath)
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                .truncationMode(.head)
            if let branch = gitBranch, !branch.isEmpty {
                Text(Theme.Glyph.separator)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.textDisabled)
                    .accessibilityHidden(true)
                Text(branch)
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // The branch outranks the path for space. Two sessions in
                    // one project differ only by branch, which is the whole
                    // reason the design puts it on this line.
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pathLabel)
    }

    private var pathLabel: String {
        guard let branch = gitBranch, !branch.isEmpty else {
            return "Working directory \(session.displayPath)"
        }
        return "Working directory \(session.displayPath), on branch \(branch)"
    }

    // MARK: - Activity

    @ViewBuilder
    private var activity: some View {
        if let activity = session.currentActivity {
            Text(attributedActivity(activity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Activity, \(activity.display)")
        } else {
            UnavailableView("Activity unavailable", compact: true)
        }
    }

    /// The design emphasises the filename inside the activity line, so the eye
    /// lands on what is being worked on rather than on the verb, which is the
    /// same word on most rows.
    ///
    /// Built from `Activity`'s two fields rather than by finding the emphasis
    /// inside `display`. A parser would have to guess where the verb ends, and
    /// it would guess wrong on the activities that have no subject at all.
    private func attributedActivity(_ activity: Activity) -> AttributedString {
        var line = AttributedString(activity.verb)
        line.font = Theme.Typography.body
        line.foregroundColor = Theme.textSecondary
        guard let subject = activity.subject, !subject.isEmpty else { return line }

        var separator = AttributedString(" ")
        separator.font = Theme.Typography.body
        var emphasis = AttributedString(subject)
        emphasis.font = Theme.Typography.bodyEmphasis
        emphasis.foregroundColor = Theme.textPrimary

        line.append(separator)
        line.append(emphasis)
        return line
    }

    // MARK: - Energy

    @ViewBuilder
    private var energy: some View {
        if onOpen == nil {
            // The disclosing form. `TokenBar` owns the breakdown this row's
            // chevron reveals, and owns it alone.
            TokenBar(
                usage: session.combinedUsage,
                scaleMaximum: tokenScaleMaximum,
                isExpandable: true,
                expansion: $isExpanded
            )
        } else {
            inlineEnergy
        }
    }

    /// The door form: a bar and its total on one line, which is all a row that
    /// opens a detail sheet needs to say.
    private var inlineEnergy: some View {
        HStack(alignment: .center, spacing: Theme.Popover.rowEnergyGap) {
            if let fraction = energyFraction {
                energyBar(fraction: fraction)
            } else {
                // No scale means no denominator, and a bar without one is a
                // made-up ratio. The total still stands on its own.
                Spacer(minLength: 0)
            }
            Text(Format.tokens(session.combinedUsage.total))
                .font(Theme.Typography.rowValue)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(energyLabel)
    }

    private var energyFraction: Double? {
        guard let tokenScaleMaximum, tokenScaleMaximum > 0 else { return nil }
        return min(1, max(0, Double(session.combinedUsage.total) / Double(tokenScaleMaximum)))
    }

    private func energyBar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(identity.track)
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [identity.lightStop, identity.dot],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: fraction <= 0
                            ? 0
                            : max(Theme.Bar.row, geo.size.width * fraction)
                    )
            }
        }
        .frame(height: Theme.Bar.row)
        // Quantised to whole percent of the scale, not the raw fraction. A
        // transcript event arrives about four times a second while a session
        // streams, and a 0.35 s animation restarted every 0.25 s never lands.
        // See the same note in `TokenBar`.
        .animation(
            Theme.valueAnimation(reduceMotion: reduceMotion, liveIndicators: liveIndicators),
            value: (fraction * 100).rounded()
        )
    }

    private var energyLabel: String {
        var text = "Token energy, \(Format.tokens(session.combinedUsage.total)) total"
        if let fraction = energyFraction {
            text += ", \(Format.percent(fraction * 100)) of scale"
        }
        return text
    }

    // MARK: - Trailing line

    private var trailingLine: some View {
        // Duration, rate, sparkline, left-packed on a 14 pt gap and no
        // separator glyph between them. The middle dot that used to sit between
        // the first two came from reading the transcription's own list
        // separator as content; the HTML sets `gap: 14px` and nothing else.
        HStack(spacing: Theme.Popover.rowMetaGap) {
            Text(Format.duration(session.duration))
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
            Text(burnRateText)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
            // Absent for the first minute or two of a session's life, and that
            // is correct rather than a gap to fill: the tracker needs two
            // samples over time before a series exists, and one point is not a
            // trend. Nothing here fabricates a flat line to fill the space.
            if Sparkline.canRender(burnHistory) {
                Sparkline(
                    burnHistory,
                    stroke: identity.sparkline,
                    label: "Token rate"
                )
                .frame(width: Theme.Bar.sparklineWidth)
            }
            Spacer(minLength: 0)
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
