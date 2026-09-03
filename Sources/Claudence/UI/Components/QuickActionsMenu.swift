import ClaudenceCore
import SwiftUI

/// The four things a user can do to a session from inside Claudence.
///
/// Three of them are harmless and run on the click. The fourth ends a process,
/// so it goes through a confirmation that names both the project and the pid:
/// several sessions of the same project are normal, the popover lists them one
/// under another, and a dialog reading only "Stop this session?" would be an
/// invitation to end the wrong one.
///
/// Feedback is a line of text under the buttons rather than an alert. An alert
/// for "Copied ~/Projects/thing" would cost a dismissal for something the user
/// already knows they asked for. The line appears once, sits for
/// `outcomeLifetime`, and goes; there is no repeating animation here, because
/// `MenuBarExtra(style: .window)` keeps this view mounted after the popover is
/// dismissed and a repeat would then burn a core for the life of the process.
///
/// The only session data displayed is the project name, the abbreviated path
/// and the pid. Nothing else about a session is on the privacy allowlist and
/// nothing else appears here.
struct QuickActionsMenu: View {

    let session: AISession
    /// The side effects. Defaults to the real machine; a preview or a test
    /// passes its own.
    var actions: SessionActions = .system

    /// How long a confirmation line stays before it clears itself. Long enough
    /// to read one short sentence, short enough that it is gone before the user
    /// wonders whether it is stuck.
    static let outcomeLifetime: Duration = .seconds(4)

    @State private var outcome: SessionActionOutcome?
    /// Bumped on every result so a new outcome restarts the clearing task even
    /// when it is the same outcome as last time.
    @State private var outcomeToken = 0
    @State private var isConfirmingStop = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            buttons
            if let outcome {
                outcomeLine(outcome)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(
            Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
            value: outcomeToken
        )
        .confirmationDialog(
            confirmationTitle.string(in: language),
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button(Strings.stopSession.string(in: language), role: .destructive) {
                record(actions.stopSession(session))
            }
            Button(Strings.cancel.string(in: language), role: .cancel) {}
                // Cancel is the default action, so a stray Return key does not
                // end a session.
                .keyboardShortcut(.defaultAction)
        } message: {
            PhraseText(confirmationDetail)
        }
        // Clears the confirmation line. A timed clear is not an animation and
        // costs nothing while no outcome is showing.
        .task(id: outcomeToken) {
            guard outcome != nil else { return }
            try? await Task.sleep(for: Self.outcomeLifetime)
            guard !Task.isCancelled else { return }
            outcome = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(quickActionsLabel, in: language)
    }

    private var confirmationTitle: Phrase {
        Phrase(
            en: "Stop \(session.projectName)?",
            th: "หยุด \(session.projectName)?"
        )
    }

    private var quickActionsLabel: Phrase {
        Phrase(
            en: "Quick actions for \(session.projectName)",
            th: "การดำเนินการด่วนสำหรับ \(session.projectName)"
        )
    }

    // MARK: - Buttons

    /// One row, wrapping only if it must, with Stop pushed to the far right.
    ///
    /// The design draws `display: flex; gap: 9px; flex-wrap: wrap` with
    /// `margin-left: auto` on the last chip, and three visually distinct
    /// treatments rather than four identical `.bordered` buttons: an accent
    /// chip for the primary action, two neutral chips, and a destructive one
    /// held apart from them. The separation is the point — a Stop that sits
    /// flush against Copy Path is a misclick waiting to happen — and the visible
    /// labels are the design's full words, `Stop Session\u{2026}` included,
    /// whose ellipsis is the platform's promise that a dialog follows.
    private var buttons: some View {
        HStack(spacing: Theme.Space.m) {
            actionChip(
                title: Strings.openTerminal,
                glyph: "terminal",
                treatment: .accent,
                label: Phrase(
                    en: "Open Terminal at \(session.displayPath)",
                    th: "เปิด Terminal ที่ \(session.displayPath)"
                ),
                hint: Strings.openTerminalHint
            ) {
                Task { record(await actions.openTerminal(for: session)) }
            }
            actionChip(
                title: Strings.openProject,
                glyph: "folder",
                treatment: .neutral,
                label: Phrase(
                    en: "Show \(session.displayPath) in Finder",
                    th: "แสดง \(session.displayPath) ใน Finder"
                ),
                hint: Strings.openProjectHint
            ) {
                record(actions.openProject(for: session))
            }
            actionChip(
                title: Strings.copyPath,
                glyph: "doc.on.doc",
                treatment: .neutral,
                label: Strings.copyPathLabel,
                hint: Strings.copyPathHint
            ) {
                record(actions.copyPath(for: session))
            }

            Spacer(minLength: Theme.Space.s)

            actionChip(
                title: Strings.stopSessionEllipsis,
                glyph: "stop.circle",
                treatment: .destructive,
                label: Phrase(
                    en: "Stop session. Terminates the Claude Code process \(session.pid) for \(session.projectName).",
                    th: "หยุด session ยุติ process \(session.pid) ของ Claude Code สำหรับ \(session.projectName)"
                ),
                hint: Strings.stopSessionHint
            ) {
                isConfirmingStop = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The three treatments the design gives these chips. Colour is never the
    /// only difference: the accent chip is the leftmost and first in reading
    /// order, and the destructive one is the only chip separated from the group
    /// and the only one whose label ends in an ellipsis.
    private enum Treatment {
        case accent
        case neutral
        case destructive

        var fill: Color {
            switch self {
            case .accent: return Theme.Hero.panelTop
            case .neutral: return Theme.surfaceControl
            case .destructive: return Theme.surface
            }
        }

        var border: Color {
            switch self {
            case .accent: return Theme.Hero.panelBorder
            case .neutral: return Theme.separator
            case .destructive: return Theme.borderHover
            }
        }

        var ink: Color {
            switch self {
            case .accent: return Theme.accentDeep
            case .neutral: return Theme.textSecondary
            case .destructive: return Theme.critical
            }
        }
    }

    private func actionChip(
        title: Phrase,
        glyph: String,
        treatment: Treatment,
        label: Phrase,
        hint: Phrase,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: treatment == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: glyph)
                    .font(.system(size: Theme.Bar.severityGlyph))
                PhraseText(title)
                    .font(Theme.Typography.labelEmphasis)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(treatment.ink)
            .padding(.vertical, Theme.Space.m)
            .padding(.horizontal, Theme.Space.l)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.banner, style: .continuous)
                    .fill(treatment.fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.banner, style: .continuous)
                    .strokeBorder(treatment.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label, in: language)
        .accessibilityHint(hint(in: language))
    }

    // MARK: - Confirmation wording

    /// Names the pid as well as the project, and says plainly what the signal
    /// is. No number here is derived or estimated, so nothing needs a label.
    private var confirmationDetail: Phrase {
        Phrase(
            en: """
            Claudence will ask process \(session.pid) in \(session.displayPath) to \
            shut down. Anything that session has not finished will stop.
            """,
            th: """
            Claudence จะขอให้ process \(session.pid) ใน \(session.displayPath) ปิดตัวลง \
            สิ่งที่ session นั้นทำค้างอยู่จะหยุดทันที
            """
        )
    }

    // MARK: - Outcome line

    private func outcomeLine(_ outcome: SessionActionOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: outcome.glyph)
                .font(.system(size: Theme.Bar.severityGlyph))
                .foregroundStyle(color(for: outcome.tone))
            PhraseText(outcome.message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outcome.message, in: language)
    }

    /// The only mapping from tone to colour, and it goes through `Theme`.
    /// Success is `healthy`, the deliberately neutral graphite, because a
    /// completed action is not an event worth colouring.
    private func color(for tone: SessionActionTone) -> Color {
        switch tone {
        case .success: return Theme.color(for: .healthy)
        case .neutral: return Theme.textTertiary
        case .problem: return Theme.color(for: .warning)
        }
    }

    // MARK: - Result plumbing

    private func record(_ result: SessionActionOutcome) {
        outcome = result
        outcomeToken += 1
    }
}

/// Words this file owns: the chip labels and hints, and the confirmation
/// dialog's fixed strings. Everything with a session's own name or path in it
/// is built inline instead, so the interpolation stays in one place per
/// sentence rather than being split between a template here and an argument
/// at the call site.
private enum Strings {
    static let openTerminal = Phrase(en: "Open Terminal", th: "เปิด Terminal")
    static let openTerminalHint = Phrase(
        en: "Opens a Terminal window in this session's working directory",
        th: "เปิดหน้าต่าง Terminal ที่ working directory ของ session นี้"
    )
    static let openProject = Phrase(en: "Open Project", th: "เปิดโปรเจกต์")
    static let openProjectHint = Phrase(
        en: "Opens this session's working directory in Finder",
        th: "เปิด working directory ของ session นี้ใน Finder"
    )
    static let copyPath = Phrase(en: "Copy Path", th: "คัดลอก Path")
    static let copyPathLabel = Phrase(
        en: "Copy the working directory path",
        th: "คัดลอก path ของ working directory"
    )
    static let copyPathHint = Phrase(
        en: "Copies the full path to the clipboard",
        th: "คัดลอก path เต็มไปยังคลิปบอร์ด"
    )
    static let stopSessionEllipsis = Phrase(en: "Stop Session\u{2026}", th: "หยุด Session\u{2026}")
    static let stopSessionHint = Phrase(
        en: "Asks for confirmation first",
        th: "ถามยืนยันก่อน"
    )
    static let stopSession = Phrase(en: "Stop Session", th: "หยุด Session")
    static let cancel = Phrase(en: "Cancel", th: "ยกเลิก")
}
