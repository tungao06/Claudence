import Foundation

/// One `~/.claude/sessions/<pid>.json` file, decoded tolerantly.
///
/// Claude Code owns this format and it is undocumented. Only the five fields
/// Claudence cannot work without are required; everything else is optional and
/// unknown keys are ignored rather than fatal, so a Claude Code update that adds
/// a field does not blind the app. Verified against Claude Code 2.1.257.
///
/// Observed but deliberately not modelled: `peerProtocol`, `peerFeatures`,
/// `nameSince`. They are ignored by `Codable` and cost nothing.
public struct RegistryRecord: Sendable, Codable, Equatable {

    // MARK: Required

    /// Process id of the Claude Code process. Also the file's basename.
    public let pid: Int32
    /// Stable session identifier, the join key to the transcript file.
    public let sessionId: String
    /// Absolute working directory the session was launched in.
    public let cwd: String
    /// Session start, epoch **milliseconds**.
    public let startedAt: Double
    /// Process start time, C-locale `ctime` layout in **UTC**.
    /// Example: `"Tue Sep  1 19:27:02 2026"`. Paired with `pid` for liveness.
    public let procStart: String

    // MARK: Optional

    /// `interactive` is a user session. Observed infrastructure kind: `bg`.
    public let kind: String?
    /// Raw status string. Observed so far: `busy`, `idle`.
    public let status: String?
    /// Last touch of the registry entry, epoch **milliseconds**.
    public let updatedAt: Double?
    /// Last status transition, epoch **milliseconds**.
    public let statusUpdatedAt: Double?
    /// Human label, e.g. `claudence-06`.
    public let name: String?
    /// How `name` was chosen. Observed: `derived`, `auto`.
    public let nameSource: String?
    /// Claude Code version that wrote the file.
    public let version: String?
    /// Observed: `cli`.
    public let entrypoint: String?
    /// Observed: `darwin`. Namespaces `pid` across pid domains.
    public let pidDomain: String?
    public let messagingSocketPath: String?
    /// Present only on `kind == "bg"` records.
    public let jobId: String?
    public let bridgeSessionId: String?

    public init(
        pid: Int32,
        sessionId: String,
        cwd: String,
        startedAt: Double,
        procStart: String,
        kind: String? = nil,
        status: String? = nil,
        updatedAt: Double? = nil,
        statusUpdatedAt: Double? = nil,
        name: String? = nil,
        nameSource: String? = nil,
        version: String? = nil,
        entrypoint: String? = nil,
        pidDomain: String? = nil,
        messagingSocketPath: String? = nil,
        jobId: String? = nil,
        bridgeSessionId: String? = nil
    ) {
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.procStart = procStart
        self.kind = kind
        self.status = status
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
        self.name = name
        self.nameSource = nameSource
        self.version = version
        self.entrypoint = entrypoint
        self.pidDomain = pidDomain
        self.messagingSocketPath = messagingSocketPath
        self.jobId = jobId
        self.bridgeSessionId = bridgeSessionId
    }

    // MARK: Derived

    /// The only kind that is a user session. Everything else is Claude Code
    /// infrastructure. See spec section 2.1.
    public static let interactiveKind = "interactive"

    public var isInteractive: Bool { kind == Self.interactiveKind }

    public var startedAtDate: Date { Date(epochMilliseconds: startedAt) }

    /// Falls back to `startedAt` when the writer has not touched the file yet.
    public var lastActivityDate: Date {
        guard let updatedAt else { return startedAtDate }
        return Date(epochMilliseconds: updatedAt)
    }

    /// `name` when Claude Code supplied one, otherwise the last path component
    /// of `cwd`. Never empty.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        let leaf = (cwd as NSString).lastPathComponent
        return leaf.isEmpty ? cwd : leaf
    }
}

// MARK: - Epoch milliseconds

extension Date {
    /// `startedAt`, `updatedAt` and `statusUpdatedAt` are epoch milliseconds,
    /// not seconds. Confirmed against real files on Claude Code 2.1.257.
    public init(epochMilliseconds ms: Double) {
        self.init(timeIntervalSince1970: ms / 1000)
    }

    public var epochMilliseconds: Double { timeIntervalSince1970 * 1000 }
}
