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
    /// What to say when there is nothing. A session with an empty trail and a
    /// subagent that keeps no trail at all are different absences, and the line
    /// should say which one it is.
    let emptyMessage: Phrase

    @Environment(\.appLanguage) private var language

    init(
        trail: [TimedActivity],
        limit: Int = 8,
        now: Date = Date(),
        emptyMessage: Phrase = Self.defaultEmptyMessage
    ) {
        self.trail = trail
        self.limit = limit
        self.now = now
        self.emptyMessage = emptyMessage
    }

    static let defaultEmptyMessage = Phrase(en: "No activity recorded yet", th: "ยังไม่มีกิจกรรมที่บันทึกไว้")

    static let footnote = Phrase(
        en: "Derived from tool name and file path only. Message text and command strings are never read.",
        th: "มาจากชื่อ tool และ path ของไฟล์เท่านั้น ไม่มีการอ่านข้อความ message หรือคำสั่งเลย"
    )

    private var rows: [TimedActivity] {
        Array(trail.reversed().prefix(limit))
    }

    private static let sectionTitle = Phrase(en: "RECENT ACTIVITY", th: "กิจกรรมล่าสุด")

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionEyebrow(Self.sectionTitle)
                .tooltip(tip: "activity", edge: .leading)

            if rows.isEmpty {
                // A session that has done nothing we could read is ordinary:
                // a fresh session, or one whose transcript has not been
                // written to since Claudence started watching.
                UnavailableView(emptyMessage, compact: true)
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

            PhraseText(Self.footnote)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// Fixed so every verb starts on the same left edge, which is what makes
    /// the list scannable.
    ///
    /// The design's 34 pt was measured against a 420 pt popover and truncated
    /// the moment a duration reached six characters, which is most of them:
    /// `1m 12s` renders `1m 1...`, and the elapsed time is half of what a
    /// timeline row says. `Format.duration`'s widest output is seven
    /// characters -- `12m 34s`, `12h 34m` and `12d 23h` all measure 43.3 pt at
    /// 10 pt monospaced -- so this is that measurement with a little slack, not
    /// a guess. The detail is 760 pt wide now and the column it sits in has the
    /// room.
    private static let timeColumn: CGFloat = 46

    private func row(_ entry: TimedActivity) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
            Text(elapsed(entry.at))
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
                .lineLimit(1)
                .frame(width: Self.timeColumn, alignment: .leading)
            Text(entry.activity.display(in: language))
                .font(Theme.Typography.eventBody)
                .foregroundStyle(Theme.textPrimarySoft)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Self.agoLabel.format(
                in: language,
                elapsed(entry.at),
                entry.activity.display(in: language)
            )
        )
    }

    private static let agoLabel = Phrase(en: "%@ ago, %@", th: "%@ ที่แล้ว, %@")

    /// Age of an entry. A record stamped in the future is a clock skew, not a
    /// negative age, so `Format.duration` floors it at zero.
    private func elapsed(_ date: Date) -> String {
        Format.duration(now.timeIntervalSince(date))
    }
}
