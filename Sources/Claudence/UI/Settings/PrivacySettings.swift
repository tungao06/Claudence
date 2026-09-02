import SwiftUI

/// The privacy disclosure required by spec section 3.3.
///
/// This is a product requirement, not decoration: it must list exactly what is
/// read and exactly what leaves the machine. Every sentence below was written
/// against the code that does the reading, and it claims nothing the code does
/// not do. If the field allowlist in section 3.1 changes, this text changes in
/// the same commit.
///
/// Written in the second person, in short sentences. The reader is the person
/// whose files these are, not an engineer.
struct PrivacySettings: View {

    var body: some View {
        SettingsSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                SettingsParagraph(text: Copy.opening)
                ForEach(Copy.blocks) { block in
                    PrivacyBlock(block: block)
                }
            }
        }
    }

    // MARK: - Block

    struct Block: Identifiable {
        let id: String
        let heading: String
        let glyph: String
        let body: String

        init(heading: String, glyph: String, body: String) {
            self.id = heading
            self.heading = heading
            self.glyph = glyph
            self.body = body
        }
    }

    /// A heading with a glyph and one paragraph. The glyph is decoration for a
    /// sighted reader and is hidden from VoiceOver, which hears the heading.
    struct PrivacyBlock: View {
        let block: Block

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: block.glyph)
                        .font(.system(size: Theme.Bar.severityGlyph))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                    Text(block.heading)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                SettingsParagraph(text: block.body)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Copy
    //
    // Named constants rather than inline strings, so the disclosure can be read
    // and checked against the parser in one place.

    enum Copy {
        static let opening = """
        Claudence runs entirely on this Mac. Here is exactly what it reads and \
        exactly what leaves the machine.
        """

        static let sessionsHeading = "Your list of sessions"
        static let sessionsBody = """
        Claudence reads the small files Claude Code writes in ~/.claude/sessions. \
        From each one it takes six things: the process id, the folder the session \
        is running in, the session's name, whether it is busy or idle, when it \
        started, and which version of Claude Code wrote the file.
        """

        static let transcriptsHeading = "Your token counts and current activity"
        static let transcriptsBody = """
        Claudence reads the transcript files Claude Code writes in \
        ~/.claude/projects. From each line it takes the token counts, the model \
        name, the name of the tool Claude is running right now, and the path of \
        the file that tool is working on. That is how Claudence can say \
        "Editing Menu.tsx" without reading Menu.tsx.
        """

        static let neverHeading = "What Claudence never reads"
        static let neverBody = """
        Your prompts. Claude's replies. The output of any command. The contents \
        of any file. The text of any command Claude runs.

        Claude Code records the commands it runs. Claudence turns each command \
        into a SHA-256 hash and keeps only the hash. The hash is never shown to \
        you and never leaves this Mac. This is deliberate: command lines \
        routinely carry API keys and database passwords, so Claudence says \
        "Running a command" and stops there.
        """

        static let tokenHeading = "Your Claude Code sign-in"
        static let tokenBody = """
        Claudence reads your Claude Code sign-in token from the macOS Keychain. \
        If the Keychain has no entry, it looks in ~/.claude/.credentials.json, \
        where older versions of Claude Code kept the same token. The token is \
        used for one purpose: asking Anthropic how much of your usage limit is \
        left. It is never written to disk, never logged, and never shown.
        """

        static let networkHeading = "What leaves this Mac"
        static let networkBody = """
        One request, to api.anthropic.com, carrying your token and nothing else. \
        That is the only outbound request the application makes. If your token \
        has expired, Claudence asks platform.claude.com for a fresh one first, \
        and then makes that same single request.

        Those two addresses and console.anthropic.com are the only ones \
        Claudence is permitted to reach. If a reply tries to redirect it \
        anywhere else, it refuses to follow.

        There is no telemetry, no analytics, and no sync. Nothing about your \
        code, your prompts, your file names, or your sessions is ever sent \
        anywhere.
        """

        static let storageHeading = "Where your history is kept"
        static let storageBody = """
        On this Mac only, in a SQLite database at \
        ~/Library/Application Support/Claudence/claudence.db. It holds token \
        totals and session records so the daily figures survive a restart. \
        Delete that file and the history is gone.
        """

        static let blocks: [Block] = [
            Block(heading: sessionsHeading, glyph: "list.bullet.rectangle", body: sessionsBody),
            Block(heading: transcriptsHeading, glyph: "number", body: transcriptsBody),
            Block(heading: neverHeading, glyph: "eye.slash", body: neverBody),
            Block(heading: tokenHeading, glyph: "key", body: tokenBody),
            Block(heading: networkHeading, glyph: "arrow.up.right", body: networkBody),
            Block(heading: storageHeading, glyph: "internaldrive", body: storageBody),
        ]
    }
}
