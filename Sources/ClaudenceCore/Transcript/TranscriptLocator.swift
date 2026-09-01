import Foundation

/// Resolves `~/.claude/projects/<slug>/<sessionId>.jsonl`.
///
/// `<slug>` is the session's `cwd` with every `/` replaced by `-`. Spec section
/// 2.3 calls that a hint, not a guarantee — a path containing dots or unusual
/// characters may not round-trip — so a failed hint falls back to scanning every
/// project directory for a file named `<sessionId>.jsonl`, and a candidate is
/// confirmed by reading `sessionId` out of the file itself.
public struct TranscriptLocator: Sendable {

    /// Bytes of the head of a candidate file inspected when confirming its
    /// session id. Kept small: this runs only when there is no usable cursor.
    static let confirmationWindow = 64 * 1024

    public let projectsDirectory: URL

    public init(projectsDirectory: URL = Constants.projectsDirectory) {
        self.projectsDirectory = projectsDirectory
    }

    /// `/Users/x/proj` -> `-Users-x-proj`.
    public static func slug(forWorkingDirectory directory: String) -> String {
        directory.replacingOccurrences(of: "/", with: "-")
    }

    /// The transcript for a session, or nil when no candidate exists.
    ///
    /// A file whose head confirms the session id wins. A name match whose head
    /// is inconclusive is accepted as a fallback, because the file name is
    /// itself the session id. A file whose head names a different session and
    /// never names this one is rejected.
    public func locate(sessionID: String, workingDirectory: String) -> URL? {
        guard !sessionID.isEmpty else { return nil }
        let fileName = sessionID + ".jsonl"
        let fileManager = FileManager.default

        let hint = projectsDirectory
            .appendingPathComponent(TranscriptLocator.slug(forWorkingDirectory: workingDirectory), isDirectory: true)
            .appendingPathComponent(fileName)

        var unconfirmed: URL?

        if fileManager.fileExists(atPath: hint.path) {
            switch confirmation(of: hint, sessionID: sessionID) {
            case .confirmed: return hint
            case .inconclusive: unconfirmed = hint
            case .contradicted: break
            }
        }

        guard let projects = try? fileManager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return unconfirmed
        }

        var newestUnconfirmed: (url: URL, modified: Date)?

        for project in projects.sorted(by: { $0.path < $1.path }) {
            let candidate = project.appendingPathComponent(fileName)
            guard candidate != hint, fileManager.fileExists(atPath: candidate.path) else { continue }
            switch confirmation(of: candidate, sessionID: sessionID) {
            case .confirmed:
                return candidate
            case .inconclusive:
                let modified = modificationDate(of: candidate)
                if newestUnconfirmed == nil || modified > newestUnconfirmed!.modified {
                    newestUnconfirmed = (candidate, modified)
                }
            case .contradicted:
                continue
            }
        }

        return unconfirmed ?? newestUnconfirmed?.url
    }

    // MARK: - Confirmation

    enum Confirmation {
        /// A record in the head of the file carries this session id.
        case confirmed
        /// No record in the head of the file carries any session id.
        case inconclusive
        /// Records carry session ids, none of them this one.
        case contradicted
    }

    /// Reads at most `confirmationWindow` bytes and decodes `sessionId` alone.
    /// No other field of any record is decoded here.
    func confirmation(of url: URL, sessionID: String) -> Confirmation {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .inconclusive }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: TranscriptLocator.confirmationWindow),
              !head.isEmpty else { return .inconclusive }

        let decoder = JSONDecoder()
        var sawAnySessionID = false

        // The final segment may be a partial line; only whole lines are decoded.
        var lines = Array(head.split(separator: 0x0A, omittingEmptySubsequences: false))
        if head.last != 0x0A, !lines.isEmpty { lines.removeLast() }

        for line in lines where !line.isEmpty {
            guard let probe = try? decoder.decode(TranscriptSessionProbe.self, from: Data(line)),
                  let found = probe.sessionID else { continue }
            if found == sessionID { return .confirmed }
            sawAnySessionID = true
        }

        return sawAnySessionID ? .contradicted : .inconclusive
    }

    private func modificationDate(of url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }
}
