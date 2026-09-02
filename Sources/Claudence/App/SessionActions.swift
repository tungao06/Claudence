import AppKit
import ClaudenceCore
import Darwin
import Foundation

// MARK: - Tone

/// How an outcome should read, without naming a colour.
///
/// The service knows what happened; only the view knows what a `Theme` token
/// looks like. Keeping the mapping here as three abstract tones is what lets
/// this file stay free of SwiftUI and lets the view stay free of policy.
enum SessionActionTone: Sendable {
    /// The thing the user asked for happened.
    case success
    /// Nothing went wrong and nothing needed to. An ordinary state.
    case neutral
    /// The system refused, or the machine cannot do this at all.
    case problem
}

// MARK: - Outcome

/// The result of one quick action.
///
/// A `Bool` would collapse four genuinely different endings into two. "Terminal
/// is not installed", "that folder was deleted" and "the session had already
/// exited" are three separate answers, and only one of them is a failure worth
/// showing as such. Each case carries the sentence the interface prints, so the
/// caller never has to invent wording for a condition it did not diagnose.
enum SessionActionOutcome: Equatable, Sendable {
    /// The action ran and did what it said.
    case done(String)
    /// The process is already gone. Expected, not an error: a session can exit
    /// between the moment the popover drew it and the moment the user clicked.
    case alreadyStopped(String)
    /// This Mac cannot perform the action at all, e.g. no Terminal to resolve.
    case unavailable(String)
    /// It was attempted and the system said no.
    case failed(String)

    /// The one line the interface shows. Never a generic "something went wrong".
    var message: String {
        switch self {
        case .done(let text), .alreadyStopped(let text),
             .unavailable(let text), .failed(let text):
            return text
        }
    }

    /// Paired with the message everywhere, so an outcome is never carried by
    /// colour alone.
    var glyph: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .alreadyStopped: return "info.circle"
        case .unavailable: return "minus.circle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tone: SessionActionTone {
        switch self {
        case .done: return .success
        case .alreadyStopped: return .neutral
        case .unavailable: return .neutral
        case .failed: return .problem
        }
    }
}

// MARK: - Service

/// The four quick actions, behind injected side effects.
///
/// Same shape as `LaunchAtLoginService`: the operations that touch the machine
/// are stored closures and `.system` is the only value that binds them to the
/// real thing. A test can drive `stop` through every branch without owning a
/// process to kill, which matters more here than anywhere else in the app,
/// because the honest way to test a signal is not to send one.
///
/// Nothing in this file reads session content. The only session fields used are
/// `pid`, `procStart`, `workingDirectory` and `projectName`, all of which are
/// already on the privacy allowlist.
@MainActor
struct SessionActions {

    /// Resolves the Terminal bundle. `nil` means this Mac has no Terminal, which
    /// is reported rather than worked around.
    var terminalApplicationURL: () -> URL?

    /// Opens a directory with a named application. Returns `nil` on success, or
    /// the reason the open failed. Async because the AppKit call it wraps hands
    /// its answer back through a completion handler, and a quick action that
    /// claims success before the launch has been accepted is lying.
    var openDirectory: (_ directory: URL, _ application: URL) async -> String?

    /// Reveals a directory in Finder. `false` means Finder declined.
    var revealInFinder: (URL) -> Bool

    /// True only for a path that exists and is a directory. A working directory
    /// can be deleted while its session is still running.
    var directoryExists: (String) -> Bool

    /// Writes to the general pasteboard. `false` means the write was refused.
    var copyToPasteboard: (String) -> Bool

    /// Liveness, on the registry's terms: the pid must exist and the live
    /// process's real start time must match the recorded `procStart`.
    var isAlive: (_ pid: Int32, _ procStart: String) -> Bool

    /// Sends the terminate signal. Returns `0` on success, otherwise `errno`.
    var terminate: (Int32) -> Int32

    // MARK: The real machine

    static let system = SessionActions(
        terminalApplicationURL: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminalBundleIdentifier)
        },
        openDirectory: { directory, application in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            return await withCheckedContinuation { continuation in
                NSWorkspace.shared.open(
                    [directory],
                    withApplicationAt: application,
                    configuration: configuration
                ) { _, error in
                    // Only a `String?` crosses back, so nothing non-Sendable
                    // escapes the completion handler's thread.
                    continuation.resume(returning: error.map { ($0 as NSError).localizedDescription })
                }
            }
        },
        revealInFinder: { url in
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        },
        directoryExists: { path in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        },
        copyToPasteboard: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        },
        isAlive: { pid, procStart in
            // The registry's own check, called directly rather than
            // reimplemented. It is deliberately the uncached entry point:
            // `LivenessCache` is right for a discovery sweep that asks the same
            // question several times a second, and wrong for a signal, where a
            // one-second-old "alive" is a one-second-old licence to kill.
            SessionRegistryAdapter.isAlive(pid: pid, procStart: procStart)
        },
        terminate: { pid in
            // SIGTERM, never SIGKILL. This is the user's own editor session and
            // Claude Code is entitled to flush its transcript and remove its
            // registry file on the way out.
            if kill(pid, SIGTERM) == 0 { return 0 }
            return errno
        }
    )

    /// Terminal ships with macOS and its identifier has not changed, but the
    /// lookup is still allowed to fail: a managed Mac can remove it.
    static let terminalBundleIdentifier = "com.apple.Terminal"

    /// The lowest pid this service will ever signal. `0` means "every process in
    /// my group" and `1` is `launchd`; both are catastrophic and neither can
    /// ever be a Claude Code session.
    static let lowestSignallablePID: Int32 = 2

    // MARK: - Open Terminal

    /// Opens Terminal with the session's working directory as its argument,
    /// which is how Terminal is asked for a new window at a path without
    /// AppleScript and without a shell.
    func openTerminal(for session: AISession) async -> SessionActionOutcome {
        guard directoryExists(session.workingDirectory) else {
            return .failed("That folder no longer exists at \(session.displayPath).")
        }
        guard let terminal = terminalApplicationURL() else {
            return .unavailable("No Terminal application on this Mac.")
        }
        let directory = URL(fileURLWithPath: session.workingDirectory, isDirectory: true)
        if let reason = await openDirectory(directory, terminal) {
            return .failed("Terminal would not open: \(reason)")
        }
        return .done("Opened Terminal at \(session.displayPath).")
    }

    // MARK: - Open project

    /// Shows the working directory in Finder. A deleted directory is a reported
    /// failure, checked before the call rather than discovered by it.
    func openProject(for session: AISession) -> SessionActionOutcome {
        guard directoryExists(session.workingDirectory) else {
            return .failed("That folder no longer exists at \(session.displayPath).")
        }
        let directory = URL(fileURLWithPath: session.workingDirectory, isDirectory: true)
        guard revealInFinder(directory) else {
            return .failed("Finder would not open \(session.displayPath).")
        }
        return .done("Opened \(session.displayPath) in Finder.")
    }

    // MARK: - Copy path

    /// Copies the absolute path, not `displayPath`.
    ///
    /// `displayPath` abbreviates the home directory to `~`, which reads well and
    /// pastes badly: `~` is expanded by a shell, and by almost nothing else. The
    /// confirmation line still shows the abbreviated form, so what the user sees
    /// stays short while what they paste stays usable.
    func copyPath(for session: AISession) -> SessionActionOutcome {
        guard copyToPasteboard(session.workingDirectory) else {
            return .failed("The clipboard would not take the path.")
        }
        return .done("Copied \(session.displayPath).")
    }

    // MARK: - Stop session

    /// Asks the session's process to shut down.
    ///
    /// Three guards stand between a click and a signal, in this order:
    ///
    /// 1. The pid must be at or above `lowestSignallablePID`. A zero pid signals
    ///    the whole process group and a pid of one signals `launchd`.
    /// 2. `kill(pid, 0)` must find the process AND its real start time must
    ///    still match the recorded `procStart`. The second half is the
    ///    load-bearing one: pids are recycled, and a recycled pid is a stranger's
    ///    process. This is exactly the discipline the registry applies before it
    ///    will show a session, and it is reused here rather than restated.
    /// 3. `kill` itself can still lose the race and report `ESRCH`, which is
    ///    reported as an ordinary "already stopped" rather than as a failure.
    func stopSession(_ session: AISession) -> SessionActionOutcome {
        let pid = session.pid
        guard pid >= Self.lowestSignallablePID else {
            return .failed("Refusing to signal process \(pid).")
        }
        guard isAlive(pid, session.procStart) else {
            return .alreadyStopped("\(session.projectName) had already stopped.")
        }
        let code = terminate(pid)
        switch code {
        case 0:
            return .done("Asked \(session.projectName) to stop, process \(pid).")
        case ESRCH:
            return .alreadyStopped("\(session.projectName) had already stopped.")
        case EPERM:
            return .failed("Not permitted to stop process \(pid).")
        default:
            return .failed("Could not stop process \(pid), error \(code).")
        }
    }
}
