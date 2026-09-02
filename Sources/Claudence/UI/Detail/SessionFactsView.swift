import SwiftUI
import ClaudenceCore

/// The identifying facts about a session, every one of them on the privacy
/// allowlist.
///
/// The design draws nine tiles and assumes a field behind each. Four of them
/// have none in this build, and they are drawn as explicit gaps rather than
/// dropped, because a missing tile is invisible and an empty one is a question
/// somebody will answer. Each gap carries its reason in the spoken label, so the
/// absence is attributable rather than mysterious:
///
/// - `Kind` - `RegistryRecord` reads a `kind` and the adapter filters on it, but
///   `AISession` does not carry it forward.
/// - `Git branch` - `TranscriptRecord` decodes `gitBranch` and the reader
///   discards it; nothing reaches the domain model.
/// - `Registry` - the adapter maps the raw registry word onto `SessionStatus`
///   and keeps only the mapping. The design wants the unmapped word, which would
///   distinguish `reaped` from an ordinary exit.
///
/// Two facts the design puts in a separate transcript bar are folded in here
/// instead: `Service tier` and `Records` have fields, while that bar's other two
/// values (transcript size and tail offset) do not, and a four-value bar that is
/// half empty is worse than two more tiles.
struct SessionFactsView: View {

    let session: AISession
    /// Rendering clock, so a preview's duration does not move.
    let now: Date

    init(session: AISession, now: Date = Date()) {
        self.session = session
        self.now = now
    }

    /// One tile. `value` nil is the honest gap; `reason` explains it to a
    /// screen reader without spending a line of the popover on it.
    private struct Fact: Identifiable {
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

    private var facts: [Fact] {
        [
            Fact("PID", session.pid > 0 ? String(session.pid) : nil,
                 reason: "No live process is recorded for this session"),
            Fact("Model", session.model,
                 reason: "No assistant record with a model has been read yet"),
            Fact("Kind", nil,
                 reason: "The session model does not carry the registry kind"),
            Fact("Started", session.startedAt.formatted(date: .abbreviated, time: .shortened)),
            Fact("Duration", Format.duration(now.timeIntervalSince(session.startedAt))),
            Fact("Git branch", nil,
                 reason: "The transcript reader does not carry the branch into the session"),
            Fact("CC version", session.claudeCodeVersion,
                 reason: "No record carrying a version has been read yet"),
            Fact("Session id", session.id),
            Fact("Registry", nil,
                 reason: "Only the mapped status is kept, not the raw registry word"),
            Fact("Service tier", session.serviceTier,
                 reason: "No record carrying a service tier has been read yet"),
            Fact("Records", String(session.recordsParsed)),
        ]
    }

    /// Two columns, not the design's three: the popover is a third of the
    /// design sheet's width and a three-way split leaves no room for a session
    /// id or a model name.
    private let columns = [
        GridItem(.flexible(), spacing: Theme.Space.m, alignment: .leading),
        GridItem(.flexible(), spacing: Theme.Space.m, alignment: .leading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            SectionEyebrow("SESSION FACTS")
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.m) {
                ForEach(facts) { fact in
                    tile(fact)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func tile(_ fact: Fact) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(fact.name)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Text(fact.value ?? "Unavailable")
                .font(Theme.Typography.numeric)
                .foregroundStyle(fact.value == nil ? Theme.textTertiary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Space.xs)
        .padding(.horizontal, Theme.Space.m)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .tooltip(fact: fact.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken(fact))
    }

    private func spoken(_ fact: Fact) -> String {
        guard let value = fact.value else {
            guard let reason = fact.reason else { return "\(fact.name), unavailable" }
            return "\(fact.name), unavailable. \(reason)."
        }
        return "\(fact.name), \(value)"
    }
}
