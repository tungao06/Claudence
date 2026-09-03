import Foundation

/// The text of the file a user sends by hand when something looks wrong.
///
/// Nothing here is transmitted. The application writes this to a file the user
/// chooses and stops; there is no telemetry in this product and adding one is an
/// amendment to CLAUDE.md, not a detail of a report button.
///
/// Two rules shape what goes in.
///
/// It is written in English whatever the interface language, because it is read
/// by the maintainer against the source, and a stack of Thai field names beside
/// English symbol names helps nobody.
///
/// It carries no path that names a person and no content of any transcript. The
/// home directory is abbreviated to `~`, project directories are reduced to
/// their last component, and the only numbers are counts, sizes and the engine's
/// own counters. A user should be able to read the whole file before sending it
/// and find nothing in it they would not have said out loud.
public struct ProblemReport: Sendable, Equatable {

    /// What the application knows about itself at the moment the button is
    /// pressed. Passed in rather than read here, so this type stays testable and
    /// so the executable target owns its own bundle lookups.
    public struct Environment: Sendable, Equatable {
        public var appVersion: String
        public var appBuild: String
        /// The commit this bundle was built from, `-modified` when the tree
        /// was dirty. Nil when the bundle carries no such key, which is what a
        /// build outside a git checkout produces.
        ///
        /// Worth a line of its own because self-distribution has no build
        /// server: two friends can hold bundles that call themselves
        /// `0.1.1 (72)` and were built from different working trees, and this
        /// is the only thing in the report that can tell them apart.
        public var sourceRevision: String?
        public var operatingSystem: String
        public var storeHealth: StoreHealth
        public var isLiveOnly: Bool
        public var databasePath: String?
        public var databaseSizeBytes: UInt64?
        public var claudeCodeVersion: String?
        public var liveSessionCount: Int
        public var storedSessionCount: Int?
        public var usageSampleCount: Int?
        public var rollupDayCount: Int?
        public var subagentTotalCount: Int?

        public init(
            appVersion: String,
            appBuild: String,
            sourceRevision: String? = nil,
            operatingSystem: String,
            storeHealth: StoreHealth,
            isLiveOnly: Bool,
            databasePath: String? = nil,
            databaseSizeBytes: UInt64? = nil,
            claudeCodeVersion: String? = nil,
            liveSessionCount: Int = 0,
            storedSessionCount: Int? = nil,
            usageSampleCount: Int? = nil,
            rollupDayCount: Int? = nil,
            subagentTotalCount: Int? = nil
        ) {
            self.appVersion = appVersion
            self.appBuild = appBuild
            self.sourceRevision = sourceRevision
            self.operatingSystem = operatingSystem
            self.storeHealth = storeHealth
            self.isLiveOnly = isLiveOnly
            self.databasePath = databasePath
            self.databaseSizeBytes = databaseSizeBytes
            self.claudeCodeVersion = claudeCodeVersion
            self.liveSessionCount = liveSessionCount
            self.storedSessionCount = storedSessionCount
            self.usageSampleCount = usageSampleCount
            self.rollupDayCount = rollupDayCount
            self.subagentTotalCount = subagentTotalCount
        }
    }

    public var environment: Environment
    public var counters: EngineCounters.Reading
    public var generatedAt: Date

    public init(
        environment: Environment,
        counters: EngineCounters.Reading,
        generatedAt: Date = Date()
    ) {
        self.environment = environment
        self.counters = counters
        self.generatedAt = generatedAt
    }

    /// A file name that sorts by time and says what it is.
    public var suggestedFileName: String {
        let stamp = ProblemReport.fileStamp.string(from: generatedAt)
        return "claudence-report-\(stamp).txt"
    }

    /// The whole file.
    public func text() -> String {
        var lines: [String] = []
        lines.append("Claudence problem report")
        lines.append(ProblemReport.timestamp.string(from: generatedAt))
        lines.append("")

        lines.append("Application")
        lines.append("  version:        \(environment.appVersion) (\(environment.appBuild))")
        lines.append("  source:         \(environment.sourceRevision ?? "unknown")")
        lines.append("  macOS:          \(environment.operatingSystem)")
        lines.append("  Claude Code:    \(environment.claudeCodeVersion ?? "not seen")")
        lines.append("  live-only mode: \(environment.isLiveOnly ? "on" : "off")")
        lines.append("")

        lines.append("Storage")
        lines.append("  health:         \(ProblemReport.describe(environment.storeHealth))")
        lines.append("  database:       \(ProblemReport.abbreviate(environment.databasePath) ?? "none")")
        lines.append("  size:           \(ProblemReport.describeSize(environment.databaseSizeBytes))")
        lines.append("  sessions:       \(ProblemReport.describe(environment.storedSessionCount))")
        lines.append("  usage samples:  \(ProblemReport.describe(environment.usageSampleCount))")
        lines.append("  rollup days:    \(ProblemReport.describe(environment.rollupDayCount))")
        lines.append("  subagent rows:  \(ProblemReport.describe(environment.subagentTotalCount))")
        lines.append("")

        lines.append("Live sessions")
        lines.append("  discovered now: \(environment.liveSessionCount)")
        lines.append("")

        lines.append("Engine counters, since launch")
        for line in counters.reportLines() {
            lines.append("  \(line)")
        }
        lines.append("")

        lines.append("What this file does not contain")
        lines.append("  No message text, no tool results, no command strings, no file contents.")
        lines.append("  No project paths beyond the database's own location, abbreviated to ~.")
        lines.append("  Nothing was sent anywhere: this file exists only where it was saved.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Rendering

    /// Home replaced by `~`, so a report never carries a user's account name.
    static func abbreviate(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A count the store could not answer is absent, never zero. The whole
    /// point of the file is to tell a failed read from an empty table.
    static func describe(_ count: Int?) -> String {
        count.map(String.init) ?? "unavailable"
    }

    static func describeSize(_ bytes: UInt64?) -> String {
        guard let bytes else { return "unavailable" }
        if bytes < 1_024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB"]
        var value = Double(bytes) / 1_024
        var unit = 0
        while value >= 1_024, unit < units.count - 1 {
            value /= 1_024
            unit += 1
        }
        return String(format: "%.1f %@", value, units[unit])
    }

    static func describe(_ health: StoreHealth) -> String {
        switch health {
        case .healthy: return "healthy"
        case .degraded(let reason): return "degraded (\(reason))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        }
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed locale and the Gregorian calendar on purpose. A Thai locale
        // supplies the Buddhist calendar, and a report dated 2569 against a
        // commit dated 2026 costs the reader a minute every time.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter
    }()

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()
}
