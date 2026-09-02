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

    private var buttons: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                actionButton(
                    title: "Terminal",
                    glyph: "terminal",
                    label: "Open Terminal at \(session.displayPath)",
                    hint: "Opens a Terminal window in this session's working directory"
                ) {
                    Task { record(await actions.openTerminal(for: session)) }
                }
                actionButton(
                    title: "Project",
                    glyph: "folder",
                    label: "Show \(session.displayPath) in Finder",
                    hint: "Opens this session's working directory in Finder"
                ) {
                    record(actions.openProject(for: session))
                }
            }
            HStack(spacing: Theme.Space.s) {
                actionButton(
                    title: "Copy Path",
                    glyph: "doc.on.doc",
                    label: "Copy the working directory path",
                    hint: "Copies the full path to the clipboard"
                ) {
                    record(actions.copyPath(for: session))
                }
                actionButton(
                    title: "Stop",
                    glyph: "stop.circle",
                    label: "Stop session. Terminates the Claude Code process \(session.pid) for \(session.projectName).",
                    hint: "Asks for confirmation first",
                    role: .destructive
                ) {
                    isConfirmingStop = true
                }
            }
        }
    }

    private func actionButton(
        title: String,
        glyph: String,
        label: String,
        hint: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: glyph)
                    .font(.system(size: Theme.Bar.severityGlyph))
                Text(title)
                    .font(Theme.Typography.label)
                    .lineLimit(1)
            }
            .foregroundStyle(role == .destructive ? Theme.critical : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
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
