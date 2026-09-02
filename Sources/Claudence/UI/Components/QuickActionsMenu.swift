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
            "Stop \(session.projectName)?",
            isPresented: $isConfirmingStop,
            titleVisibility: .visible
        ) {
            Button("Stop Session", role: .destructive) {
                record(actions.stopSession(session))
            }
            Button("Cancel", role: .cancel) {}
                // Cancel is the default action, so a stray Return key does not
                // end a session.
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(confirmationDetail)
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
        .accessibilityLabel("Quick actions for \(session.projectName)")
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
                title: "Open Terminal",
                glyph: "terminal",
                treatment: .accent,
                label: "Open Terminal at \(session.displayPath)",
                hint: "Opens a Terminal window in this session's working directory"
            ) {
                Task { record(await actions.openTerminal(for: session)) }
            }
            actionChip(
                title: "Open Project",
                glyph: "folder",
                treatment: .neutral,
                label: "Show \(session.displayPath) in Finder",
                hint: "Opens this session's working directory in Finder"
            ) {
                record(actions.openProject(for: session))
            }
            actionChip(
                title: "Copy Path",
                glyph: "doc.on.doc",
                treatment: .neutral,
                label: "Copy the working directory path",
                hint: "Copies the full path to the clipboard"
            ) {
                record(actions.copyPath(for: session))
            }

            Spacer(minLength: Theme.Space.s)

            actionChip(
                title: "Stop Session\u{2026}",
                glyph: "stop.circle",
                treatment: .destructive,
                label: "Stop session. Terminates the Claude Code process \(session.pid) for \(session.projectName).",
                hint: "Asks for confirmation first"
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
        title: String,
        glyph: String,
        treatment: Treatment,
        label: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: treatment == .destructive ? .destructive : nil, action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: glyph)
                    .font(.system(size: Theme.Bar.severityGlyph))
                Text(title)
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
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }

    // MARK: - Confirmation wording

    /// Names the pid as well as the project, and says plainly what the signal
    /// is. No number here is derived or estimated, so nothing needs a label.
    private var confirmationDetail: String {
        """
        Claudence will ask process \(session.pid) in \(session.displayPath) to \
        shut down. Anything that session has not finished will stop.
        """
    }

    // MARK: - Outcome line

    private func outcomeLine(_ outcome: SessionActionOutcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: outcome.glyph)
                .font(.system(size: Theme.Bar.severityGlyph))
                .foregroundStyle(color(for: outcome.tone))
            Text(outcome.message)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(outcome.message)
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
