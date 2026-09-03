import Foundation

/// Whether Claude Code is on this machine at all, and what to say when it is
/// not.
///
/// Written for first launch. Until now an absent Claude Code produced the same
/// display as an idle one: an empty session list and a meter with no reading,
/// which reads as a broken application rather than as a missing dependency. A
/// friend who installs this before installing Claude Code deserves the sentence
/// that tells them so.
///
/// The check is deliberately shallow. It looks for the directory Claude Code
/// keeps its state in and for evidence that it has ever run, and it does not go
/// looking for the binary on `PATH`: this application never launches Claude
/// Code, so whether the command is reachable from a shell is not its business.
/// What it needs is somewhere to read from.
public enum ClaudeCodePresence: Sendable, Equatable {
    /// The state directory exists and has been written to.
    case present
    /// The directory exists but nothing has run yet: no sessions, no projects.
    /// Ordinary on a machine where Claude Code was installed minutes ago.
    case installedButNeverRun
    /// No state directory at all.
    case absent

    public var isUsable: Bool {
        switch self {
        case .present: return true
        case .installedButNeverRun, .absent: return false
        }
    }

    /// Reads the filesystem once.
    ///
    /// - Parameters:
    ///   - fileManager: injected so a test never depends on the machine it runs
    ///     on, which is the same reason `Constants.claudeHome` is overridable.
    ///   - home: the state directory, `~/.claude` unless `CLAUDE_CONFIG_DIR`
    ///     says otherwise.
    public static func detect(
        fileManager: FileManager = .default,
        home: URL = Constants.claudeHome,
        projects: URL = Constants.projectsDirectory,
        sessions: URL = Constants.sessionsDirectory
    ) -> ClaudeCodePresence {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: home.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .absent
        }

        let hasProjects = (try? fileManager.contentsOfDirectory(atPath: projects.path))?.isEmpty == false
        let hasSessions = (try? fileManager.contentsOfDirectory(atPath: sessions.path))?.isEmpty == false
        return hasProjects || hasSessions ? .present : .installedButNeverRun
    }

    /// What the interface says, in both languages.
    ///
    /// The title states the fact and the detail says what to do about it. No
    /// state here is an error: a machine without Claude Code is a machine this
    /// application has nothing to show yet, which is an ordinary state with a
    /// defined display, exactly as zero sessions and a denied Keychain are.
    public var title: Phrase? {
        switch self {
        case .present:
            return nil
        case .installedButNeverRun:
            return Phrase(
                en: "Claude Code has not run yet",
                th: "ยังไม่เคยเรียกใช้ Claude Code"
            )
        case .absent:
            return Phrase(
                en: "Claude Code is not installed",
                th: "ยังไม่ได้ติดตั้ง Claude Code"
            )
        }
    }

    public var detail: Phrase? {
        switch self {
        case .present:
            return nil
        case .installedButNeverRun:
            return Phrase(
                en: "Start a session in any project and it will appear here.",
                th: "เริ่มเซสชันในโปรเจกต์ใดก็ได้ แล้วเซสชันนั้นจะปรากฏที่นี่"
            )
        case .absent:
            return Phrase(
                en: "Install it with: npm install -g @anthropic-ai/claude-code",
                th: "ติดตั้งด้วยคำสั่ง: npm install -g @anthropic-ai/claude-code"
            )
        }
    }
}
