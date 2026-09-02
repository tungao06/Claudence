import Foundation

// MARK: - Provider

public enum AIProviderType: String, Sendable, Codable, CaseIterable {
    case claudeCode
    case codex
    case geminiCLI
}

// MARK: - Session status

/// Only states with a proven data source are used by the UI.
/// `permission` and `error` exist for the provider contract but must not be
/// rendered until a source is proven to derive them. `waiting` was in that
/// group until a live capture on Claude Code 2.1.258 showed the registry
/// writing `"waiting"` as a status string of its own, which is a source; it is
/// derivable now and the adapter maps it directly. See spec section 6.
public enum SessionStatus: String, Sendable, Codable {
    case running
    case idle
    case completed
    case waiting
    case permission
    case error

    /// Whether this state is currently derivable from a real data source.
    public var isDerivable: Bool {
        switch self {
        case .running, .idle, .completed, .waiting: return true
        case .permission, .error: return false
        }
    }
}

// MARK: - Token usage

/// The single definition of token accounting for the whole application.
/// Nothing computes its own totals. See spec section 5.
public struct TokenUsage: Sendable, Codable, Equatable {
    public var freshInput: Int
    public var cacheCreation: Int
    public var cacheRead: Int
    public var output: Int
    public var thinking: Int

    public init(
        freshInput: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        thinking: Int = 0
    ) {
        self.freshInput = freshInput
        self.cacheCreation = cacheCreation
        self.cacheRead = cacheRead
        self.output = output
        self.thinking = thinking
    }

    public var billableInput: Int { freshInput + cacheCreation + cacheRead }
    public var total: Int { billableInput + output }

    public static let zero = TokenUsage()

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            freshInput: lhs.freshInput + rhs.freshInput,
            cacheCreation: lhs.cacheCreation + rhs.cacheCreation,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            output: lhs.output + rhs.output,
            thinking: lhs.thinking + rhs.thinking
        )
    }

    public static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

// MARK: - Activity

/// What a session is currently doing, derived from tool name plus file path only.
/// Never carries a command string. See spec section 3.1.
public struct Activity: Sendable, Codable, Equatable {
    public var verb: String
    public var subject: String?

    public init(verb: String, subject: String? = nil) {
        self.verb = verb
        self.subject = subject
    }

    public var display: String {
        guard let subject, !subject.isEmpty else { return verb }
        return "\(verb) \(subject)"
    }
}

// MARK: - Session

public struct AISession: Sendable, Identifiable, Equatable {
    public let id: String
    public let provider: AIProviderType
    public let pid: Int32
    /// Paired with `pid` for liveness. PID alone is reused after reboot.
    public let procStart: String
    public let projectName: String
    public let workingDirectory: String
    public var status: SessionStatus
    public var currentActivity: Activity?
    public let startedAt: Date
    public var lastActivityAt: Date
    /// Tokens from this session's own transcript.
    public var usage: TokenUsage
    /// Tokens spent by subagents this session spawned. They have no process of
    /// their own and are billed to the parent, so `combinedUsage` is the honest
    /// figure to show as "this session's tokens". Kept separate so the split
    /// can be displayed and so nothing double-counts.
    public var subagentUsage: TokenUsage
    public var subagentCount: Int
    public var model: String?
    public let claudeCodeVersion: String?
    /// Tool-use counts by name, accumulated across the session. Names only.
    public var toolCounts: [String: Int]
    /// Distinct file paths this session has touched, newest last. Paths only:
    /// no file is opened and no content is read.
    public var filePaths: [String]
    /// Recent activities in order, for the session timeline.
    public var activityTrail: [TimedActivity]
    /// `usage.service_tier` from the most recent record carrying one.
    public var serviceTier: String?
    /// `gitBranch` from the most recent record carrying one, when the
    /// transcript records one at all. Nil is ordinary: a directory that is not
    /// a git working tree has no branch, and the row then shows the path alone.
    public var gitBranch: String?
    /// Assistant records read from this session's own transcript.
    public var recordsParsed: Int
    /// The newest single request's `message.usage`, not the running total.
    ///
    /// A context window sizes one request's input. `usage` is cumulative, and
    /// its `cache_read` alone reaches tens of millions on a long session, so
    /// measuring a context window against it produces percentages in the
    /// thousands. Nil until a record with a usage block has been read, which is
    /// the ordinary state for a session that has not answered yet.
    public var lastRequestUsage: TokenUsage?

    public init(
        id: String,
        provider: AIProviderType = .claudeCode,
        pid: Int32,
        procStart: String,
        projectName: String,
        workingDirectory: String,
        status: SessionStatus,
        currentActivity: Activity? = nil,
        startedAt: Date,
        lastActivityAt: Date,
        usage: TokenUsage = .zero,
        subagentUsage: TokenUsage = .zero,
        subagentCount: Int = 0,
        model: String? = nil,
        claudeCodeVersion: String? = nil,
        toolCounts: [String: Int] = [:],
        filePaths: [String] = [],
        activityTrail: [TimedActivity] = [],
        serviceTier: String? = nil,
        gitBranch: String? = nil,
        recordsParsed: Int = 0,
        lastRequestUsage: TokenUsage? = nil
    ) {
        self.id = id
        self.provider = provider
        self.pid = pid
        self.procStart = procStart
        self.projectName = projectName
        self.workingDirectory = workingDirectory
        self.status = status
        self.currentActivity = currentActivity
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.usage = usage
        self.subagentUsage = subagentUsage
        self.subagentCount = subagentCount
        self.model = model
        self.claudeCodeVersion = claudeCodeVersion
        self.toolCounts = toolCounts
        self.filePaths = filePaths
        self.activityTrail = activityTrail
        self.serviceTier = serviceTier
        self.gitBranch = gitBranch
        self.recordsParsed = recordsParsed
        self.lastRequestUsage = lastRequestUsage
    }

    /// What this session actually cost: its own transcript plus every subagent
    /// it spawned. Every total shown to the user uses this.
    public var combinedUsage: TokenUsage { usage + subagentUsage }

    /// Tool mix, busiest first. The interface shows the top few.
    public var toolMix: [(name: String, count: Int)] {
        toolCounts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }

    /// Share of billable input served from cache. Nil when nothing billable has
    /// been read yet, because a ratio of nothing is undefined, not zero.
    public var cacheServedFraction: Double? {
        let billable = combinedUsage.billableInput
        guard billable > 0 else { return nil }
        return Double(combinedUsage.cacheRead) / Double(billable)
    }

    /// Tokens per hour over the session's whole life. Nil until enough time has
    /// passed for the figure to mean anything.
    public func tokensPerHour(now: Date = Date()) -> Double? {
        let elapsed = now.timeIntervalSince(startedAt)
        guard elapsed >= 60 else { return nil }
        return Double(combinedUsage.total) / (elapsed / 3_600)
    }

    public var duration: TimeInterval { Date().timeIntervalSince(startedAt) }

    /// Abbreviated working directory, `~` for home.
    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard workingDirectory.hasPrefix(home) else { return workingDirectory }
        return "~" + workingDirectory.dropFirst(home.count)
    }
}

/// One row of `usage_samples`: a session's running total at an instant.
///
/// Cumulative, not incremental. Two consecutive rows for the same session
/// differ by what that session spent between them, and that difference is the
/// only thing any caller wants; a single row on its own says nothing about a
/// period. See `ClaudenceStore.usageSamples(in:)` for why the row before a
/// range has to be fetched with it.
public struct UsageSampleRow: Sendable, Equatable {
    public let sessionID: String
    public let sampledAt: Date
    public let usage: TokenUsage

    public init(sessionID: String, sampledAt: Date, usage: TokenUsage) {
        self.sessionID = sessionID
        self.sampledAt = sampledAt
        self.usage = usage
    }
}

// MARK: - Usage windows

public struct UsageWindow: Sendable, Codable, Equatable, Identifiable {
    /// `five_hour`, `seven_day`, or `seven_day_<model_slug>`.
    public let name: String
    public let usedPercent: Double?
    public let resetsAt: Date?

    public var id: String { name }

    public init(name: String, usedPercent: Double? = nil, resetsAt: Date? = nil) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double? {
        usedPercent.map { max(0, 100 - $0) }
    }

    public var displayName: String {
        switch name {
        case "five_hour": return "5 Hour"
        case "seven_day": return "7 Day"
        default:
            guard name.hasPrefix("seven_day_") else { return name }
            let slug = name.dropFirst("seven_day_".count)
            return slug.split(separator: "_").map(\.capitalized).joined(separator: " ")
        }
    }
}

/// Usage is either measured or explicitly unavailable. There is no third state
/// and no fallback value. See spec section 9.4.
public enum UsageState: Sendable, Equatable {
    case unavailable(reason: String)
    case available(windows: [UsageWindow], fetchedAt: Date)

    public var windows: [UsageWindow] {
        if case .available(let w, _) = self { return w }
        return []
    }

    public func window(named name: String) -> UsageWindow? {
        windows.first { $0.name == name }
    }
}

// MARK: - Severity

public enum Severity: String, Sendable, CaseIterable {
    case healthy
    case attention
    case warning
    case critical
}
