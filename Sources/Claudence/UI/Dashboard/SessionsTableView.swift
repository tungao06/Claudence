import SwiftUI
import ClaudenceCore

/// Every live session, one row each.
///
/// The dashboard's whole reason to exist: Claude Code's own status line sees
/// only the session it runs inside, and this is the view that sees all of them
/// at once. It sits directly under the power meter and above everything
/// analytical, which is the product's fixed visual priority.
///
/// The row is four columns because the four things a reader wants are of four
/// different kinds: what it is, how much energy it has spent, the total, and
/// how fast it is spending. Only the first column truncates; a number that
/// shrank to fit would be harder to read than a name that lost its head.
///
/// Colour in a row is *identity*, not state. The tint and border come from
/// `Theme.identity(forSessionID:)`, which is a stable function of the session
/// id, so the same session is the same colour on every launch and two rows can
/// be told apart at a glance. State is carried by the status pill, which is a
/// glyph and a word, and by the dimming of a finished row.
///
/// A completed session is dimmed rather than dropped. It still spent what it
/// spent, and a list that removed rows as they finished would keep changing
/// height under the reader for no informational gain.
struct SessionsTableView: View {
    let sessions: [AISession]
    /// Denominator for the energy bars. Nil draws no bar: a fill without a
    /// denominator is a ratio nobody agreed to.
    let tokenScaleMaximum: Int?
    let burnRates: [String: BurnSample]
    /// Reference time for the "ended 34m ago" line on a finished session.
    let now: Date
    /// The user's `Compact rows` setting, whose explanation promises to "hide
    /// duration, rate and sparkline until a row is opened".
    ///
    /// All three of those are here, so the setting applies and the card is no
    /// longer a surface the switch silently skips. Rate and sparkline are the
    /// whole fourth column and it goes; duration is the `12m run` half of a
    /// finished row's activity line and that goes with it. What stays is what
    /// the card exists for: which session, what it is doing, how much energy it
    /// has spent. The row still opens, and the detail sheet still carries every
    /// figure the compact row dropped, which is the "until a row is opened"
    /// half of the promise.
    let isCompact: Bool
    /// Opens a row. Nil makes rows inert and drops the promise of a detail from
    /// the card's subtitle, so the copy can never outrun the behaviour.
    let onSelect: ((AISession) -> Void)?

    init(
        sessions: [AISession],
        tokenScaleMaximum: Int?,
        burnRates: [String: BurnSample],
        now: Date,
        isCompact: Bool = false,
        onSelect: ((AISession) -> Void)? = nil
    ) {
        self.sessions = sessions
        self.tokenScaleMaximum = tokenScaleMaximum
        self.burnRates = burnRates
        self.now = now
        self.isCompact = isCompact
        self.onSelect = onSelect
    }

    /// The design's em dash, U+2014, for a value that does not exist.
    private static let absent = "\u{2014}"

    var body: some View {
        DashboardCard(
            title: "Active sessions",
            subtitle: subtitle,
            headerLayout: .inline,
            horizontalPadding: DashboardMetrics.chartCardPaddingHorizontal,
            contentGap: Theme.Space.l
        ) {
            if sessions.isEmpty {
                // Zero sessions is an ordinary state, not an error.
                UnavailableView(
                    "No active sessions",
                    reason: "Claude Code is not running, or no session is interactive"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: DashboardMetrics.sessionRowGap) {
                    ForEach(sessions) { session in
                        row(session)
                    }
                }
            }
        }
    }

    /// The design's note, minus the half of it this card cannot honour when no
    /// handler was supplied.
    private var subtitle: String {
        let hover = "hover any value for what it means"
        guard onSelect != nil else { return hover.prefix(1).uppercased() + hover.dropFirst() }
        return "Click a row for full detail · " + hover
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ session: AISession) -> some View {
        if let onSelect {
            Button {
                onSelect(session)
            } label: {
                rowBody(session)
            }
            // `ElevatedRowButtonStyle` stands in for `.plain`, which it matches
            // in every respect but one: a held row gives back the lift the
            // pointer gave it, so a click has a physical answer and not only a
            // consequence. Both styles render the label with no chrome and no
            // tint, and every run of text in the row sets its own colour.
            .buttonStyle(ElevatedRowButtonStyle())
            .accessibilityAddTraits(.isButton)
        } else {
            rowBody(session)
        }
    }

    private func rowBody(_ session: AISession) -> some View {
        let identity = Theme.identity(forSessionID: session.id)
        let isCompleted = session.status == .completed
        return HStack(alignment: .top, spacing: DashboardMetrics.sessionRowColumnGap) {
            identityColumn(session, identity: identity, isCompleted: isCompleted)
                .frame(maxWidth: .infinity, alignment: .leading)
            energyColumn(session, identity: identity)
                .frame(width: DashboardMetrics.sessionEnergyColumn, alignment: .leading)
            Text(Format.tokens(session.combinedUsage.total))
                .font(Theme.Typography.value)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: DashboardMetrics.sessionTotalColumn, alignment: .trailing)
                .tooltip(tip: "energy")
            if !isCompact {
                burnColumn(session)
                    .frame(width: DashboardMetrics.sessionBurnColumn, alignment: .trailing)
            }
        }
        .padding(.vertical, DashboardMetrics.sessionRowPaddingVertical)
        .padding(.horizontal, DashboardMetrics.sessionRowPaddingHorizontal)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(identity.tint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .strokeBorder(identity.track, lineWidth: DashboardMetrics.chartGridStroke)
        )
        .opacity(isCompleted ? DashboardMetrics.completedRowOpacity : 1)
        .contentShape(Rectangle())
        // The row level, not the card level: this is one of a list, and a list
        // whose rows each rose as far as the card holding them would heave. The
        // row's own identity tint is opaque and drawn in front of the hover
        // ground, so what changes under the pointer is the shadow and a point
        // of height, never the row's colour, which is identity and must not
        // move.
        .elevates(.row, cornerRadius: Theme.Radius.row)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenRow(session))
    }

    // MARK: Column 1: what it is

    private func identityColumn(
        _ session: AISession,
        identity: Theme.SessionIdentity,
        isCompleted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                // The design's leading dot: identity, and static in every
                // state. It pulses on a live row there, which is one of the
                // nine repeating animations `CLAUDE.md` forbids, and the state
                // it was carrying is on the pill beside it in a glyph and a
                // word either way.
                Circle()
                    .fill(identity.dot)
                    .frame(
                        width: DashboardMetrics.sessionDotSize,
                        height: DashboardMetrics.sessionDotSize
                    )
                Text(session.projectName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                statusPill(session)
                Spacer(minLength: 0)
            }
            Text(session.displayPath)
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                // The tail of a path identifies the checkout, so a long one
                // loses its head rather than its name.
                .truncationMode(.head)
            activityLine(session, isCompleted: isCompleted)
        }
    }

    private func statusPill(_ session: AISession) -> some View {
        StatusIndicator(
            session.status,
            activityToken: Self.activityToken(session)
        )
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xxs)
        .background(Capsule(style: .continuous).fill(Theme.surfaceRaised))
        .tooltip(tip: "status")
    }

    /// A three-second bucket of the last activity, not the timestamp itself, so
    /// the status glyph dips once per burst rather than restarting a 0.55 s
    /// animation four times a second. `SessionRow.activityToken` explains the
    /// measurement behind the number.
    private static func activityToken(_ session: AISession) -> AnyHashable {
        Int(session.lastActivityAt.timeIntervalSince1970 / 3)
    }

    @ViewBuilder
    private func activityLine(_ session: AISession, isCompleted: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Text(activityText(session, isCompleted: isCompleted))
                .font(Theme.Typography.help)
                .foregroundStyle(isCompleted ? Theme.textQuaternary : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .tooltip(tip: "activity")
            if session.subagentCount > 0 {
                Text(
                    session.subagentCount == 1
                        ? "1 subagent"
                        : "\(session.subagentCount) subagents"
                )
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(Theme.surfaceControl))
            }
            Spacer(minLength: 0)
        }
    }

    /// A finished session reports how long ago it stopped and how long it ran.
    /// A live one reports what it is doing, at tool-name granularity: the
    /// privacy contract keeps command strings and message text out of here.
    private func activityText(_ session: AISession, isCompleted: Bool) -> String {
        guard !isCompleted else {
            let ended = max(0, now.timeIntervalSince(session.lastActivityAt))
            let endedText = "ended \(Format.duration(ended)) ago"
            // How long ago it stopped is when, not how long, so it survives a
            // compact row. The run length is the duration the setting names.
            guard !isCompact else { return endedText }
            let ran = max(0, session.lastActivityAt.timeIntervalSince(session.startedAt))
            return endedText + " · \(Format.duration(ran)) run"
        }
        return session.currentActivity?.display ?? "No activity recorded"
    }

    // MARK: Column 2: energy

    private func energyColumn(
        _ session: AISession,
        identity: Theme.SessionIdentity
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            energyBar(session, identity: identity)
            Text("token energy")
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
        }
        .tooltip(tip: "energy")
    }

    @ViewBuilder
    private func energyBar(
        _ session: AISession,
        identity: Theme.SessionIdentity
    ) -> some View {
        if let scale = tokenScaleMaximum, scale > 0 {
            let raw = Double(session.combinedUsage.total) / Double(scale)
            let fraction = min(1, max(0, raw))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(identity.track)
                    Capsule(style: .continuous)
                        .fill(identity.dot)
                        // The same minimum-fill rule the tubes use: a session
                        // that has spent a little must not read as one that has
                        // spent nothing.
                        .frame(
                            width: fraction <= 0
                                ? 0
                                : geo.size.width
                                    * CGFloat(max(fraction, Theme.Bar.minimumVisibleFill))
                        )
                }
            }
            .frame(height: Theme.Bar.row)
        } else {
            // No denominator, so no bar. The total is still in column three.
            Text(Self.absent)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
                .frame(height: Theme.Bar.row, alignment: .center)
        }
    }

    // MARK: Column 4: rate

    private func burnColumn(_ session: AISession) -> some View {
        let burn = burnRates[session.id] ?? .unavailable
        return VStack(alignment: .trailing, spacing: Theme.Space.xs) {
            Text(burn.tokensPerMinute.map { "\(Format.tokens(Int($0.rounded())))/min" } ?? Self.absent)
                .font(Theme.Typography.numeric)
                .foregroundStyle(
                    burn.tokensPerMinute == nil ? Theme.textQuaternary : Theme.textSecondary
                )
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if Sparkline.canRender(burn.samples) {
                Sparkline(
                    burn.samples,
                    height: Theme.Dashboard.sparklineHeight,
                    label: "Token rate"
                )
                .frame(width: Theme.Dashboard.sparklineWidth)
            } else {
                // Fewer than two samples is not a trend. The design puts an em
                // dash here for exactly this case.
                Text(Self.absent)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textQuaternary)
                    .frame(height: Theme.Dashboard.sparklineHeight, alignment: .center)
            }
        }
        .tooltip(tip: "burn")
    }

    // MARK: - Spoken label

    private func spokenRow(_ session: AISession) -> String {
        let isCompleted = session.status == .completed
        var parts = [
            "\(session.projectName).",
            "\(Theme.name(for: session.status)).",
            "\(activityText(session, isCompleted: isCompleted)).",
            "\(Format.tokens(session.combinedUsage.total)) tokens.",
        ]
        if let scale = tokenScaleMaximum, scale > 0 {
            let share = min(1, Double(session.combinedUsage.total) / Double(scale))
            parts.append("\(Format.percent(share * 100)) of the busiest session.")
        }
        // A compact row does not draw the rate, so it does not speak one
        // either. VoiceOver hears the row that is there, not the row that would
        // be there with the setting off.
        if !isCompact {
            let burn = burnRates[session.id] ?? .unavailable
            if let rate = burn.tokensPerMinute {
                parts.append("\(Format.tokens(Int(rate.rounded()))) tokens per minute.")
            } else {
                parts.append("Burn rate unavailable.")
            }
        }
        if session.subagentCount > 0 {
            parts.append(
                session.subagentCount == 1
                    ? "1 subagent."
                    : "\(session.subagentCount) subagents."
            )
        }
        return parts.joined(separator: " ")
    }
}
