import SwiftUI
import ClaudenceCore

/// The last few things a session did, newest first.
///
/// The engine keeps the trail oldest-last and caps it at 24 entries, so this
/// reverses it and takes the head: a timeline that reads downwards from "just
/// now" answers "what is it doing" before it answers "what did it do", which is
/// the order the popover is read in.
///
/// Every line here is a verb and at most a file name, because that is all an
/// `Activity` carries. A Bash call reads `Running a command` and never the
/// command, since command strings routinely carry API keys and connection
/// strings. The footnote says so on screen rather than leaving the user to
/// infer it, which is the design's own wording and the reason it exists.
struct ActivityTimelineView: View {
    let trail: [TimedActivity]
    /// How many rows fit before the list stops being a glance. The popover is
    /// narrow and the detail view already scrolls; more than this turns a
    /// timeline into a log.
    let limit: Int
    /// Rendering clock, so the relative times in a preview are deterministic.
    let now: Date

    init(trail: [TimedActivity], limit: Int = 8, now: Date = Date()) {
        self.trail = trail
        self.limit = limit
        self.now = now
    }

    static let footnote =
        "Derived from tool name and file path only. Message text and command strings are never read."

    private var rows: [TimedActivity] {
        Array(trail.reversed().prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionEyebrow("RECENT ACTIVITY")
                .tooltip(tip: "activity")

            if rows.isEmpty {
                // A session that has done nothing we could read is ordinary:
                // a fresh session, or one whose transcript has not been
                // written to since Claudence started watching.
                UnavailableView("No activity recorded yet", compact: true)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                        row(entry)
                        if index < rows.count - 1 {
                            Divider().overlay(Theme.separator)
                        }
                    }
                }
            }

            Text(Self.footnote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func row(_ entry: TimedActivity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(elapsed(entry.at))
                .font(Theme.Typography.numeric)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
            Text(entry.activity.display)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(elapsed(entry.at)) ago, \(entry.activity.display)")
    }

    /// Age of an entry. A record stamped in the future is a clock skew, not a
    /// negative age, so `Format.duration` floors it at zero.
    private func elapsed(_ date: Date) -> String {
        Format.duration(now.timeIntervalSince(date))
    }
}
