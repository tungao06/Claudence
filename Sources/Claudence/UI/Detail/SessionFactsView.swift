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

/// The design's fact-tile grid. `SESSION FACTS` is its only caller now that
/// the subagent variant is gone (stage 2, 9.9): four of its nine tiles were
/// permanent `Unavailable` labels serving a reader `--diagnose --counters`
/// already covers from the terminal, and a fifth read `nil` for a reason that
/// was false — `Git branch`, fixed rather than deleted, is item 4 of the same
/// change. What is left is four facts, so this now lays out two columns
/// rather than three: a 3-column grid of four items left an empty pair of
/// slots in the second row, which read as a gap rather than as a finished
/// layout.
///
/// The popover is 420 pt against the design sheet's 760, so a two-column tile
/// is about 190 pt: a model name is set on one line at 12.5 pt mono and
/// truncated in the middle, which keeps the head and tail legible.
///
/// The tooltip's hanging edge follows the column, because a 320 pt bubble is
/// wider than a tile and has to open away from the nearest window edge.
struct DetailFactsGrid: View {
    let title: String
    let facts: [DetailFact]

    private let columns = [
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
/// Five of the design's nine tiles were removed rather than fixed (stage 2,
/// 9.9): `PID`, `Kind`, `Registry`, `Session id` and `CC version` exist for
/// whoever is debugging the reader, and `--diagnose --counters` already serves
/// that reader from the terminal. Four of the five were permanent `Unavailable`
/// labels in this build regardless.
///
/// `Git branch` survives as the sixth removal candidate turned correction: it
/// used to render `nil` with a reason that was false — `TranscriptReader`
/// collects the branch (`TranscriptReader.swift:216` at the time this was
/// written) and `MonitorEngine` assigns it onto `AISession.gitBranch`
/// (`MonitorEngine.swift:182`), which `SessionRow`'s meta line already
/// displays. This tile reads the same field.
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
            DetailFact("Model", session.model,
                       reason: "No assistant record with a model has been read yet"),
            DetailFact("Git branch", session.gitBranch,
                       reason: "No transcript record carrying a branch has been read yet"),
            DetailFact("Started", session.startedAt.formatted(date: .omitted, time: .standard)),
            DetailFact("Duration", Format.duration(now.timeIntervalSince(session.startedAt))),
        ]
    }

    var body: some View {
        DetailFactsGrid(title: "SESSION FACTS", facts: facts)
    }
}

// MARK: - Transcript facts bar

/// The design's standalone strip of transcript facts: `Transcript`, `Parsed`,
/// `Tail offset`, `Service tier`.
///
/// `Transcript` and `Tail offset` were removed rather than filled in (stage 2,
/// 9.9): the byte offset proves this application is tailing rather than
/// re-parsing, which is a fact worth knowing, but `--diagnose --counters`
/// already reports it from the terminal for the reader who needs it, and a
/// permanent `Unavailable` label here served nobody else. `Parsed` and
/// `Service tier` are the two that had a field all along.
struct TranscriptFactsBar: View {
    let records: Int
    let serviceTier: String?

    private var facts: [DetailFact] {
        [
            DetailFact("Parsed", "\(records) assistant records"),
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
