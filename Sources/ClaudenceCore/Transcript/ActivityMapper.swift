import Foundation

/// Turns a tool call into human phrasing. See spec section 8.
///
/// The mapping is derived from the tool name plus `file_path` only. It never
/// consults a command string: section 3.2 withdrew the earlier "show the raw
/// command" requirement because command strings routinely carry API keys and
/// connection strings. A vaguer honest label beats a precise leaky one.
public enum ActivityMapper {

    /// Canonical verbs. Named, so views and tests never spell them as literals.
    public enum Verb {
        public static let reading = "Reading"
        public static let editing = "Editing"
        public static let searching = "Searching"
        public static let running = "Running"
        public static let planning = "Planning"
    }

    /// Canonical subjects for the tools that cannot name a concrete target.
    public enum Subject {
        public static let codebase = "codebase"
        public static let command = "a command"
        public static let web = "the web"
        public static let subagent = "a subagent"
    }

    /// - Parameters:
    ///   - toolName: `content[].name`.
    ///   - filePath: `content[].input.file_path`, or nil.
    public static func activity(toolName: String, filePath: String? = nil) -> Activity {
        let target = basename(of: filePath)

        switch toolName {
        case "Read":
            return Activity(verb: Verb.reading, subject: target)
        case "Edit", "Write":
            return Activity(verb: Verb.editing, subject: target)
        case "Grep", "Glob":
            return Activity(verb: Verb.searching, subject: Subject.codebase)
        case "Bash":
            // Never echoes the command. See spec section 3.2.
            return Activity(verb: Verb.running, subject: Subject.command)
        case "WebFetch", "WebSearch":
            return Activity(verb: Verb.searching, subject: Subject.web)
        // Claude Code 2.1.257 renamed the agent-spawn tool from Task to Agent.
        // Both are mapped so a transcript written by an older build still reads.
        case "Agent", "Task":
            return Activity(verb: Verb.running, subject: Subject.subagent)
        // TodoWrite was replaced by TaskCreate / TaskUpdate in the same release.
        case "TaskCreate", "TaskUpdate", "TodoWrite":
            return Activity(verb: Verb.planning, subject: nil)
        default:
            return Activity(verb: Verb.running, subject: toolName)
        }
    }

    /// Activity for a decoded `tool_use` block, or nil for any other block.
    static func activity(for block: TranscriptContentBlock) -> Activity? {
        guard block.isToolUse, let name = block.name, !name.isEmpty else { return nil }
        return activity(toolName: name, filePath: block.input?.filePath)
    }

    /// Last path component. A path is allowlisted data; the rest of the path is
    /// dropped only to keep the label short.
    private static func basename(of path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? nil : component
    }
}
