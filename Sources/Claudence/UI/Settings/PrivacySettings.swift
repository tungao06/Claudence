import SwiftUI

/// The privacy disclosure required by spec section 3.3.
///
/// ## Shape
///
/// The design's last block is three short paragraphs, a `Read the full
/// disclosure` button and a version stamp, and that is what this is. An earlier
/// build replaced the three paragraphs with six headed detail blocks and had no
/// button at all, which made the block six times as long as the design's and
/// left the button's promise unkept.
///
/// The six blocks were not deleted, because the disclosure they contain is the
/// product requirement and the summary is not a substitute for it. They are what
/// the button now opens. That is the arrangement the design implies: a summary a
/// reader will actually read, and the full text one click away.
///
/// ## Copy
///
/// This is a product requirement, not decoration: it must list exactly what is
/// read and exactly what leaves the machine. Every sentence below was written
/// against the code that does the reading, and it claims nothing the code does
/// not do. If the field allowlist in section 3.1 changes, this text changes in
/// the same commit.
///
/// One sentence is deliberately not the design's. The design's summary says
/// "One request ever leaves this app". Two do: the usage call to
/// api.anthropic.com, and a conditional token refresh to platform.claude.com
/// when the access token has expired. The summary below says two, because the
/// number in a privacy disclosure is the one thing in it that must not be
/// rounded down.
///
/// Written in the second person, in short sentences. The reader is the person
/// whose files these are, not an engineer.
struct PrivacySettings: View {
    @State private var isShowingFullDisclosure = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsSection(title: "Privacy", showDivider: false) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SettingsParagraph(text: Copy.reads)
                SettingsParagraph(text: Copy.leaves)
                SettingsParagraph(text: Copy.never)

                HStack(alignment: .center, spacing: Theme.Space.m) {
                    Button {
                        isShowingFullDisclosure.toggle()
                    } label: {
                        Text(isShowingFullDisclosure ? "Hide the full disclosure" : "Read the full disclosure")
                            .font(Theme.Typography.labelEmphasis)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.vertical, Theme.Space.s)
                            .padding(.horizontal, Theme.Space.l)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .fill(Theme.surfaceControl)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                                    .strokeBorder(Theme.separator, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Read the full disclosure")
                    .accessibilityValue(isShowingFullDisclosure ? "Showing" : "Hidden")
                    .accessibilityHint("Shows exactly which files Claudence reads and which two requests leave this Mac")

                    Spacer(minLength: Theme.Space.s)

                    // The design stamps `v0.1.0` here. This reads the bundle
                    // rather than printing a literal, because a version string
                    // nobody checked is a fabricated number like any other.
                    Text(AppVersion.stamp)
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.textQuaternary)
                        .accessibilityLabel("Claudence version \(AppVersion.display)")
                }
                .padding(.top, Theme.Space.xs)

                if isShowingFullDisclosure {
                    VStack(alignment: .leading, spacing: Theme.Space.xl) {
                        ForEach(Copy.blocks) { block in
                            PrivacyBlock(block: block)
                        }
                    }
                    .padding(.top, Theme.Space.s)
                    .transition(.opacity)
                }
            }
            // One fade per press. `isShowingFullDisclosure` is a Bool, so the
            // value driving it is already quantised, and nothing repeats.
            .animation(
                Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
                value: isShowingFullDisclosure
            )
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

        // The summary: the design's three paragraphs, one of them corrected.

        static let reads = """
        Claudence reads four things on this Mac: the session registry, the \
        transcript files for token counts, your subscription plan name, and your \
        Claude Code credentials from the Keychain.
        """

        /// The design says one request. There are two. See the note on the type.
        static let leaves = """
        Two requests ever leave this app: the usage-limit call to \
        api.anthropic.com, and a token refresh to platform.claude.com when your \
        sign-in has expired. There is no backend, no telemetry, no sync.
        """

        static let never = """
        Message text, tool output and command strings are never read, stored, or \
        shown.
        """

        // The full disclosure, behind the button.

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

        static let planHeading = "Your subscription plan"
        static let planBody = """
        Claudence reads two fields from ~/.claude.json to put "Max 5x" or "Pro" \
        at the top of the popover: the plan type and the rate-limit tier. Those \
        two name a product, not you, and they are the same for everyone on that \
        plan.

        That file also holds your email address, your name, your organisation \
        name and every folder you have opened in Claude Code. Claudence does not \
        read any of it. The reader declares those two fields and nothing else, \
        and a test fails if anything more ever reaches the screen.

        Without the plan name, every percentage here is a share of a limit that \
        is never stated: 62% of a Max 20x limit is four times the work of 62% of \
        a Max 5x one.
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
        Two requests, and only these two. The first asks api.anthropic.com how \
        much of your usage limit is left, carrying your token and nothing else. \
        The second is sent only when your token has expired: Claudence asks \
        platform.claude.com for a fresh one, then makes the first request. \
        Nothing else in the application reaches the network at all.

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

        static let estimatesHeading = "Estimates, not bills"
        /// Section 9.4: anything derived rather than measured says so, every
        /// time it is shown. This paragraph used to be the whole reason an
        /// `About` section existed; the section is gone, because the design has
        /// none, and the sentence is here, where the rest of "what this
        /// application is actually claiming" already lives.
        static let estimatesBody = """
        Usage and cost figures are estimates. Token counts come from the \
        transcript files Claude Code writes, and cost is worked out from \
        published model prices. Neither is a bill. Where a figure cannot be \
        worked out, Claudence says so instead of showing a zero.
        """

        static let blocks: [Block] = [
            Block(heading: "What this covers", glyph: "info.circle", body: opening),
            Block(heading: sessionsHeading, glyph: "list.bullet.rectangle", body: sessionsBody),
            Block(heading: transcriptsHeading, glyph: "number", body: transcriptsBody),
            Block(heading: planHeading, glyph: "creditcard", body: planBody),
            Block(heading: neverHeading, glyph: "eye.slash", body: neverBody),
            Block(heading: tokenHeading, glyph: "key", body: tokenBody),
            Block(heading: networkHeading, glyph: "arrow.up.right", body: networkBody),
            Block(heading: storageHeading, glyph: "internaldrive", body: storageBody),
            Block(heading: estimatesHeading, glyph: "questionmark.circle", body: estimatesBody),
        ]
    }
}
