import SwiftUI
import ClaudenceCore

// MARK: - One tile

/// A single fact. `value` nil is the honest gap; `reason` explains it to a
/// screen reader without spending a line of the popover on it.
struct DetailFact: Identifiable {
    let name: String
    let value: String?
    let reason: String?

    var id: String { name }

    init(_ name: String, _ value: String?, reason: String? = nil) {
        self.name = name
        self.value = value
        self.reason = reason
    }
}

/// The design's `repeat(3, 1fr)` grid of fact tiles, used by both the session
/// variant and the subagent variant.
///
/// Three columns, as the design draws them, and not the two an earlier build
/// used. The popover is 420 pt against the design sheet's 760, so a tile is
/// about 120 pt: a session id or a model name is set on one line at 12.5 pt
/// mono and truncated in the middle, which keeps the head and tail of an id
/// legible — the two ends are what a reader matches against a file name.
///
/// The tooltip's hanging edge follows the column, because a 320 pt bubble is
/// wider than a 120 pt tile and has to open away from the nearest window edge.
struct DetailFactsGrid: View {
    let title: String
    let facts: [DetailFact]

    private let columns = [
        GridItem(.flexible(), spacing: Theme.Space.m, alignment: .leading),
        GridItem(.flexible(), spacing: Theme.Space.m, alignment: .leading),
        GridItem(.flexible(), spacing: Theme.Space.m, alignment: .leading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow(title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.m) {
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                    tile(fact, column: index % columns.count)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func tile(_ fact: DetailFact, column: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(fact.name)
                .font(Theme.Typography.tileLabel)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
            Text(fact.value ?? "Unavailable")
                .font(Theme.Typography.factValue)
                .foregroundStyle(fact.value == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surfaceRecessed)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
        .tooltip(fact: fact.name, edge: edge(for: column))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(fact))
    }

    private func edge(for column: Int) -> TooltipEdge {
        if column == 0 { return .leading }
        if column == columns.count - 1 { return .trailing }
        return .center
    }

    private func spoken(_ fact: DetailFact) -> String {
        guard let value = fact.value else {
            guard let reason = fact.reason else { return "\(fact.name), unavailable" }
            return "\(fact.name), unavailable. \(reason)."
        }
        return "\(fact.name), \(value)"
    }
}

// MARK: - Session facts

/// The identifying facts about a session, every one of them on the privacy
/// allowlist.
///
/// Exactly the design's nine tiles, in the design's order, and no more. Two
/// extra fields had been appended here — `Service tier` and `Records` — which
/// belong to the transcript bar the design draws separately; that bar exists
/// again as `TranscriptFactsBar` and they are back inside it.
///
/// Three of the nine have no field in this build and are drawn as explicit gaps
/// rather than dropped, because a missing tile is invisible and an empty one is
/// a question somebody will answer. Each gap carries its reason in the spoken
/// label, so the absence is attributable rather than mysterious:
///
/// - `Kind` — `RegistryRecord` reads a `kind` and the adapter filters on it, but
///   `AISession` does not carry it forward.
/// - `Git branch` — `TranscriptRecord` decodes `gitBranch` and the reader
///   discards it; nothing reaches the domain model.
/// - `Registry` — the adapter maps the raw registry word onto `SessionStatus`
///   and keeps only the mapping. The design wants the unmapped word, which would
///   distinguish `reaped` from an ordinary exit.
struct SessionFactsView: View {

    let session: AISession
    /// Rendering clock, so a preview's duration does not move.
    let now: Date

    init(session: AISession, now: Date = Date()) {
        self.session = session
        self.now = now
    }

    private var facts: [DetailFact] {
        [
            DetailFact("PID", session.pid > 0 ? String(session.pid) : nil,
                       reason: "No live process is recorded for this session"),
            DetailFact("Model", session.model,
                       reason: "No assistant record with a model has been read yet"),
            DetailFact("Kind", nil,
                       reason: "The session model does not carry the registry kind"),
            DetailFact("Started", session.startedAt.formatted(date: .omitted, time: .standard)),
            DetailFact("Duration", Format.duration(now.timeIntervalSince(session.startedAt))),
            DetailFact("Git branch", nil,
                       reason: "The transcript reader does not carry the branch into the session"),
            DetailFact("CC version", session.claudeCodeVersion,
                       reason: "No record carrying a version has been read yet"),
            DetailFact("Session id", session.id),
            DetailFact("Registry", nil,
                       reason: "Only the mapped status is kept, not the raw registry word"),
        ]
    }

    var body: some View {
        DetailFactsGrid(title: "SESSION FACTS", facts: facts)
    }
}

// MARK: - Subagent facts

/// The design's subagent variant of the same grid: `Parent`, `Agent type` and
/// `Spawned by` replace `PID`, `Kind` and `Git branch`, and `Tool calls`,
/// `Records` and `Share` close it out.
///
/// Four of the nine have no source and say so:
///
/// - `Spawned by` — nothing records which tool call created the subagent. The
///   design's own tooltip says it is `Agent` on 2.1.257 and `Task` on older
///   transcripts, which is exactly the kind of thing that must be read rather
///   than assumed.
/// - `Started` and `Duration` — a subagent has no process and no recorded start.
///   `lastActivityAt` is the only clock it carries, and an end without a
///   beginning is not a duration.
/// - `Tool calls` — `AISubagent` carries no tool counts.
struct SubagentFactsView: View {
    let subagent: AISubagent
    let parentName: String
    let parentTotal: Int

    private var facts: [DetailFact] {
        [
            DetailFact("Parent", parentName),
            DetailFact("Agent type", subagent.agentType,
                       reason: "The spawn metadata beside the transcript names no agent type"),
            DetailFact("Spawned by", nil,
                       reason: "Nothing records which tool call spawned this subagent"),
            DetailFact("Started", nil,
                       reason: "A subagent has no process and no recorded start time"),
            DetailFact("Duration", nil,
                       reason: "Without a start time there is no elapsed time to report"),
            DetailFact("Model", subagent.model,
                       reason: "No assistant record with a model has been read yet"),
            DetailFact("Tool calls", nil,
                       reason: "Tool counts are kept per session, not per subagent"),
            DetailFact("Records", String(subagent.recordsParsed)),
            DetailFact("Share", subagent.share(ofParentTotal: parentTotal).map { Format.percent($0 * 100) },
                       reason: "The parent has spent nothing, so a share of it is undefined"),
        ]
    }

    var body: some View {
        DetailFactsGrid(title: "SUBAGENT FACTS", facts: facts)
    }
}

// MARK: - Transcript facts bar

/// The design's standalone strip of transcript facts: `Transcript`, `Parsed`,
/// `Tail offset`, `Service tier`.
///
/// This existed in the design and not in the build; two of its four values were
/// folded into the session grid and the other two vanished. It is back, with
/// the two that have no field saying so, because the reason they are missing is
/// itself worth knowing: this application's whole correctness argument rests on
/// tailing a transcript from a stored byte offset, and the offset is the one
/// number that proves it is doing that. `TranscriptOffset` persists it;
/// `AISession` does not carry it, so the interface cannot show it yet.
struct TranscriptFactsBar: View {
    let records: Int
    let serviceTier: String?

    private var facts: [DetailFact] {
        [
            DetailFact("Transcript", nil,
                       reason: "The session model does not carry the transcript path or its size"),
            DetailFact("Parsed", "\(records) assistant records"),
            DetailFact("Tail offset", nil,
                       reason: "The stored byte offset is not carried into the session model"),
            DetailFact("Service tier", serviceTier,
                       reason: "No record carrying a service tier has been read yet"),
        ]
    }

    var body: some View {
        FlowLayout(spacing: Theme.Space.xxl) {
            ForEach(facts) { fact in
                cell(fact)
            }
        }
        .padding(.vertical, Theme.Space.m)
        .padding(.horizontal, Theme.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.surfaceInset)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func cell(_ fact: DetailFact) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(fact.name)
                .font(Theme.Typography.tileLabel)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
            Text(fact.value ?? "Unavailable")
                .font(Theme.Typography.factValue)
                .foregroundStyle(fact.value == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
        }
        .tooltip(fact: fact.name, edge: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(fact))
    }

    private func spoken(_ fact: DetailFact) -> String {
        guard let value = fact.value else {
            guard let reason = fact.reason else { return "\(fact.name), unavailable" }
            return "\(fact.name), unavailable. \(reason)."
        }
        return "\(fact.name), \(value)"
    }
}
