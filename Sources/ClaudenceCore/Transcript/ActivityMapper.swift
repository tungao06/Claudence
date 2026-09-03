import Foundation

/// Turns a tool call into human phrasing. See spec section 8.
///
/// The mapping is derived from the tool name plus `file_path` only. It never
/// consults a command string: section 3.2 withdrew the earlier "show the raw
/// command" requirement because command strings routinely carry API keys and
/// connection strings. A vaguer honest label beats a precise leaky one.
public enum ActivityMapper {

    /// Canonical verbs. Named, so views and tests never spell them as literals.
    ///
    /// Thai wants the continuous aspect these English participles carry, which
    /// is what `กำลัง` does, so each verb keeps it rather than being a bare
    /// dictionary form that would read as an instruction.
    public enum Verb {
        public static let reading = Phrase(en: "Reading", th: "กำลังอ่าน")
        public static let editing = Phrase(en: "Editing", th: "กำลังแก้ไข")
        public static let searching = Phrase(en: "Searching", th: "กำลังค้นหา")
        public static let running = Phrase(en: "Running", th: "กำลังรัน")
        public static let planning = Phrase(en: "Planning", th: "กำลังวางแผน")
    }

    /// Canonical subjects for the tools that cannot name a concrete target.
    ///
    /// Each Thai subject carries whatever particle the join needs, because the
    /// join itself is a plain space in both languages and knows nothing about
    /// either. `Searching the web` is `กำลังค้นหา บนเว็บ`, not a bare noun.
    public enum Subject {
        public static let codebase = Phrase(en: "codebase", th: "ในโค้ด")
        public static let command = Phrase(en: "a command", th: "คำสั่ง")
        public static let web = Phrase(en: "the web", th: "บนเว็บ")
        public static let subagent = Phrase(en: "a subagent", th: "subagent")
    }

    /// - Parameters:
    ///   - toolName: `content[].name`.
    ///   - filePath: `content[].input.file_path`, or nil.
    public static func activity(toolName: String, filePath: String? = nil) -> Activity {
        let target = basename(of: filePath)

        switch toolName {
        case "Read":
            return Activity(verb: Verb.reading, subject: target.map(Phrase.untranslated))
        case "Edit", "Write":
            return Activity(verb: Verb.editing, subject: target.map(Phrase.untranslated))
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
            return Activity(verb: Verb.running, subject: .untranslated(toolName))
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
