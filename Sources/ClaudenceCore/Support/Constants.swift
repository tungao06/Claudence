import Foundation

public enum Constants {
    /// Where Claude Code keeps its state. Detected, never assumed beyond this root.
    public static var claudeHome: URL {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    public static var sessionsDirectory: URL {
        claudeHome.appendingPathComponent("sessions", isDirectory: true)
    }

    public static var projectsDirectory: URL {
        claudeHome.appendingPathComponent("projects", isDirectory: true)
    }

    public static var credentialsFile: URL {
        claudeHome.appendingPathComponent(".credentials.json")
    }

    public enum Keychain {
        public static let service = "Claude Code-credentials"
    }

    public enum Usage {
        public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        public static let refreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
        public static let betaHeader = "oauth-2025-04-20"
        /// The token must be structurally incapable of reaching anywhere else.
        public static let allowedHosts: Set<String> = [
            "api.anthropic.com",
            "console.anthropic.com",
            "platform.claude.com",
        ]
        public static let cacheTTL: TimeInterval = 60
        public static let requestTimeout: TimeInterval = 10
        public static let maxResponseBytes = 1_000_000
    }

    public enum Watch {
        /// FSEvents debounce. Bursts of registry writes collapse into one scan.
        public static let debounce: Duration = .milliseconds(250)
        /// A session whose registry entry has not been touched for this long
        /// is treated as idle rather than running.
        public static let idleThreshold: TimeInterval = 60
    }

    /// Context usage thresholds. Named constants, never literals in views.
    public enum ContextThreshold {
        public static let attention = 70.0
        public static let warning = 85.0
        public static let critical = 95.0

        public static func severity(forPercent percent: Double) -> Severity {
            switch percent {
            case ..<attention: return .healthy
            case ..<warning: return .attention
            case ..<critical: return .warning
            default: return .critical
            }
        }
    }

    /// Usage window thresholds, applied to percent consumed.
    public enum UsageThreshold {
        public static let attention = 60.0
        public static let warning = 80.0
        public static let critical = 90.0

        public static func severity(forPercent percent: Double) -> Severity {
            switch percent {
            case ..<attention: return .healthy
            case ..<warning: return .attention
            case ..<critical: return .warning
            default: return .critical
            }
        }
    }

    public enum Performance {
        /// Menu bar must stay narrow; it is shared real estate.
        public static let maxMenuBarWidth: CGFloat = 60
    }

    public enum BurnRate {
        /// The window a burn rate is measured over.
        ///
        /// One definition, because the caption beside the figure names it. The
        /// design's caption reads `rolling 10 min` and the tracker measured
        /// five, so the interface was naming a window nobody measured. The
        /// tracker's default and the caption now read the same constant, and a
        /// change to one cannot silently leave the other lying.
        public static let window: TimeInterval = 300
        public static var windowMinutes: Int { Int(window / 60) }
    }
}
