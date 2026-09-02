import SwiftUI
import ClaudenceCore

/// Where a session's tokens actually went.
///
/// A subagent has no process of its own and its transcript is a separate file,
/// so until `SubagentTracker` landed none of this was visible at all. Measured
/// on this repository's own session, subagents were 41% of the true total, which
/// is why this list is a section of the detail view rather than a footnote to
/// it: without it the headline number is not slightly optimistic, it is wrong.
/// That aggregate now rides on this section's own subtitle, where it sits beside
/// the rows that explain it, instead of in a separate summary panel the design
/// does not have.
///
/// ## The row
///
/// The design's row is a four-column grid, `1fr 116px 78px 22px`, and every one
/// of those columns is here: the identity dot, the name, the agent-type pill,
/// the status pill and the activity line on the left; the share bar and its
/// caption next; the total; then the chevron that says the row opens something.
/// An earlier build drew none of the four — no dot, no status, no activity, no
/// chevron — collapsed the name and the agent type into one field, and made the
/// row inert, which left the subagent's own sheet with nothing that could reach
/// it.
///
/// `onOpen` is what the chevron promises. The sheet it opens is
/// `SubagentDetailView`, and four of its nine facts are unavailable; that is an
/// argument for saying so on the sheet, not for making the row a dead end.
///
/// ## Privacy
///
/// `agentType` and `taskDescription` both come from the `meta.json` Claude Code
/// writes beside the transcript, so they are tool-written labels rather than
/// message content; the total and the share are measured here. An earlier
/// version of this comment said those two labels sat inside the privacy
/// allowlist. They did not: section 3.1 is a positive list and it named neither.
/// The allowlist was amended on 2026-09-02 to cover exactly the four fields
/// `SubagentLocator.Meta` decodes, `description` among them, and to record the
/// argument against as well as the argument for, `description` being free text
/// whose content nothing constrains. It is covered now because the contract was
/// changed to say so, not because it always was.
struct SubagentListView: View {

    let subagents: [AISubagent]
    /// The parent's combined total, which is the denominator of every share.
    /// Passed in rather than recomputed so this view and the energy panel above
    /// it cannot disagree about what the session spent.
    let parentTotal: Int
    /// Every subagent's tokens added together, from the session that measured
    /// them. Nil omits the aggregate rather than summing the rows here, which
    /// would disagree with the session the moment a subagent is filtered out.
    let subagentTotal: Int?
    /// Rendering clock, so a preview's liveness does not drift.
    let now: Date
    /// Opens one subagent's own sheet. Nil leaves the rows inert, which is what
    /// a standalone preview wants.
    let onOpen: ((AISubagent) -> Void)?

    init(
        subagents: [AISubagent],
        parentTotal: Int,
        subagentTotal: Int? = nil,
        now: Date = Date(),
        onOpen: ((AISubagent) -> Void)? = nil
    ) {
        self.subagents = subagents
        self.parentTotal = parentTotal
        self.subagentTotal = subagentTotal
        self.now = now
        self.onOpen = onOpen
    }

    static let caption = "spawned by this session \u{00B7} tokens billed to the parent"

    /// The design's `1fr 116px 78px 22px` at popover width.
    ///
    /// The sheet is 760 pt wide and this popover is 420, so the three fixed
    /// columns are taken down by roughly the same ratio rather than kept at
    /// their sheet widths, which would leave 106 pt for a name column that has
    /// to hold a task description. The gap comes down with them.
    /// TODO(theme): exact HTML values live in `Theme.DetailSheet` already
    /// (116 / 78 / 22 / gap 14); a popover-scale set beside them would put
    /// these three numbers in the same file as the ones they derive from.
    private enum Column {
        static let share: CGFloat = 92
        static let total: CGFloat = 56
        static let chevron: CGFloat = 16
        static let gap: CGFloat = Theme.Space.m
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                SectionEyebrow("SUBAGENTS")
                Spacer(minLength: Theme.Space.xs)
                Text(Self.caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            if let aggregate {
                Text(aggregate)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if subagents.isEmpty {
                // Most sessions spawn nothing. That is a fact about the
                // session, not a failure to read one.
                UnavailableView("No subagents spawned", compact: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(subagents) { subagent in
                        row(subagent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// The one fact the removed `WHERE THE TOKENS WENT` panel carried that
    /// nothing else does: how much of the session's true total is down here.
    /// Nil when either half is missing, never a substituted zero.
    private var aggregate: String? {
        guard let subagentTotal, subagentTotal > 0, parentTotal > 0 else { return nil }
        let share = Double(subagentTotal) / Double(parentTotal)
        return "\(Format.tokens(subagentTotal)) of this session's \(Format.tokens(parentTotal)), "
            + "\(Format.percent(share * 100)) of the combined total."
    }

    // MARK: - Row

    private func row(_ subagent: AISubagent) -> some View {
        let identity = Theme.identity(forSessionID: subagent.id)
        let share = subagent.share(ofParentTotal: parentTotal)
        let status: SessionStatus = subagent.isActive(now: now) ? .running : .completed

        return Button {
            onOpen?(subagent)
        } label: {
            HStack(alignment: .center, spacing: Column.gap) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Circle()
                            .fill(identity.dot)
                            .frame(width: Theme.Bar.micro, height: Theme.Bar.micro)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                            .accessibilityHidden(true)
                        // Two lines and first claim on the width. A subagent is
                        // named by the task description Claude Code wrote at
                        // spawn time, which is a sentence; on one line, sharing
                        // a row with a type capsule and a status pill that both
                        // take their full width first, every row elided
                        // mid-word.
                        Text(name(subagent))
                            .font(Theme.Typography.rowLabel)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                        if let type = subagent.agentType, !type.isEmpty {
                            Text(type)
                                .font(Theme.Typography.micro)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, Theme.Space.s)
                                .padding(.vertical, Theme.Space.xxs)
                                .background(Capsule(style: .continuous).fill(Theme.surfaceControl))
                        }
                        // Never squeezed. It is two words and a glyph, and it
                        // is the row's only statement of state; the name has
                        // first claim on the width, so without this the pill
                        // was what elided.
                        StatusPill(status: status, identity: identity)
                            .fixedSize()
                        Spacer(minLength: 0)
                    }

                    Text(activityText(subagent, status: status))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                shareColumn(share, colour: identity.dot)
                    .frame(width: Column.share)

                Text(Format.tokens(subagent.usage.total))
                    .font(Theme.Typography.rowValue)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .frame(width: Column.total, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                    .foregroundStyle(Theme.textQuaternary)
                    .frame(width: Column.chevron, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, Theme.Space.m)
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.surfaceRecessed)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(onOpen == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(subagent, share: share, status: status))
        .accessibilityHint(onOpen == nil ? "" : "Opens this subagent's own detail")
    }

    /// The design names a row by the task the parent gave it, falling back to
    /// the agent type and then to the id. Both labels come from `meta.json`.
    private func name(_ subagent: AISubagent) -> String {
        if let task = subagent.taskDescription, !task.isEmpty { return task }
        if let type = subagent.agentType, !type.isEmpty { return type }
        return subagent.id
    }

    /// Tool name and file path only, exactly as everywhere else. A completed
    /// subagent has no activity, so the row says it finished rather than
    /// leaving a blank line where a verb was.
    private func activityText(_ subagent: AISubagent, status: SessionStatus) -> String {
        if let activity = subagent.currentActivity { return activity.display }
        return status == .running ? "Working" : "Finished"
    }

    /// The bar and its caption, or an honest gap. A share of a zero total is
    /// undefined rather than 0%, so nothing is drawn and the caption says why.
    @ViewBuilder
    private func shareColumn(_ share: Double?, colour: Color) -> some View {
        if let share {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(Theme.track)
                        Capsule(style: .continuous)
                            .fill(colour)
                            .frame(width: max(0, min(1, share)) * geo.size.width)
                    }
                }
                .frame(height: Theme.Bar.micro)
                Text("\(Format.percent(share * 100)) of parent")
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textQuaternary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .accessibilityHidden(true)
        } else {
            Text("Share unavailable")
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityHidden(true)
        }
    }

    private func spoken(_ subagent: AISubagent, share: Double?, status: SessionStatus) -> String {
        var parts: [String] = [name(subagent)]
        if let type = subagent.agentType, !type.isEmpty { parts.append(type) }
        parts.append(Theme.name(for: status))
        parts.append("\(Format.tokens(subagent.usage.total)) tokens")
        if let share {
            parts.append("\(Format.percent(share * 100)) of the parent session")
        } else {
            parts.append("share of parent unavailable")
        }
        return parts.joined(separator: ", ")
    }
}
