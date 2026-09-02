import SwiftUI
import ClaudenceCore

/// Where a session's tokens actually went.
///
/// A subagent has no process of its own and its transcript is a separate file,
/// so until `SubagentTracker` landed none of this was visible at all. Measured
/// on this repository's own session, subagents were 41% of the true total, which
/// is why this list is a section of the detail view rather than a footnote to
/// it: without it the headline number is not slightly optimistic, it is wrong.
///
/// Four things are shown per row and nothing else. `agentType` and
/// `taskDescription` both come from the `meta.json` Claude Code writes beside
/// the transcript, so they are tool-written labels rather than message content;
/// the total and the share are measured here.
///
/// An earlier version of this comment said those two labels sat inside the
/// privacy allowlist. They did not: section 3.1 is a positive list and it named
/// neither. The allowlist was amended on 2026-09-02 to cover exactly the four
/// fields `SubagentLocator.Meta` decodes, `description` among them, and to
/// record the argument against as well as the argument for, `description` being
/// free text whose content nothing constrains. It is covered now because the
/// contract was changed to say so, not because it always was.
///
/// No row is clickable: the design drills into a subagent sheet with nine
/// facts, and five of those have no field behind them today.
struct SubagentListView: View {

    let subagents: [AISubagent]
    /// The parent's combined total, which is the denominator of every share.
    /// Passed in rather than recomputed so this view and the energy panel above
    /// it cannot disagree about what the session spent.
    let parentTotal: Int

    static let caption = "spawned by this session · tokens billed to the parent"

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                SectionEyebrow("SUBAGENTS")
                Text(Self.caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if subagents.isEmpty {
                // Most sessions spawn nothing. That is a fact about the
                // session, not a failure to read one.
                UnavailableView("No subagents spawned", compact: true)
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(subagents) { subagent in
                        row(subagent)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Row

    private func row(_ subagent: AISubagent) -> some View {
        let share = subagent.share(ofParentTotal: parentTotal)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                Text(subagent.agentType ?? "Agent type unavailable")
                    .font(Theme.Typography.title)
                    .foregroundStyle(subagent.agentType == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tooltip(fact: "Agent type")
                Spacer(minLength: Theme.Space.xs)
                Text(Format.tokens(subagent.usage.total))
                    .font(Theme.Typography.numeric)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            if let task = subagent.taskDescription, !task.isEmpty {
                Text(task)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            shareLine(share)
        }
        .padding(Theme.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(subagent, share: share))
    }

    /// The bar and its caption, or an honest gap. A share of a zero total is
    /// undefined rather than 0%, so nothing is drawn and the caption says why.
    @ViewBuilder
    private func shareLine(_ share: Double?) -> some View {
        if let share {
            HStack(spacing: Theme.Space.s) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(Theme.track)
                        Capsule(style: .continuous)
                            .fill(Theme.color(for: .healthy))
                            .frame(width: max(0, min(1, share)) * geo.size.width)
                    }
                }
                .frame(height: Theme.Bar.micro)
                Text("\(Format.percent(share * 100)) of parent")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .accessibilityHidden(true)
        } else {
            UnavailableView("Share unavailable", compact: true)
                .accessibilityHidden(true)
        }
    }

    private func spoken(_ subagent: AISubagent, share: Double?) -> String {
        var parts: [String] = []
        parts.append(subagent.agentType ?? "Agent type unavailable")
        if let task = subagent.taskDescription, !task.isEmpty { parts.append(task) }
        parts.append("\(Format.tokens(subagent.usage.total)) tokens")
        if let share {
            parts.append("\(Format.percent(share * 100)) of the parent session")
        } else {
            parts.append("share of parent unavailable")
        }
        return parts.joined(separator: ", ")
    }
}
