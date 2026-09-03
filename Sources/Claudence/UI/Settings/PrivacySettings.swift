import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ClaudenceCore

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
    let storeMode: StoreModeController
    /// The live session count for the problem report (9.10c). Nothing else on
    /// this screen needs a view model; this is the one fact that lives on it
    /// rather than on the store.
    let model: MonitorViewModel
    @State private var isShowingFullDisclosure = false
    /// Set right before the confirmation opens, from the same summary the
    /// dialog's message is built from, so the counts on screen and the counts
    /// a "Delete" tap acts on are never two different reads of the store a
    /// moment apart.
    @State private var pendingSummary: ClaudenceStore.StoredDataSummary?
    @State private var isConfirmingLiveOnly = false
    /// Same reasoning as `pendingSummary`, for the "Clear Stored Data" button
    /// (9.10d): a separate summary and a separate flag, because this
    /// confirmation deletes on the spot rather than as a side effect of
    /// switching modes, and the two must never share one dialog's state.
    @State private var pendingClearSummary: ClaudenceStore.StoredDataSummary?
    @State private var isConfirmingClearData = false
    /// The result of the last "Save a Problem Report" attempt (9.10c). Nil
    /// before the button has ever been pressed.
    @State private var reportOutcome: ReportOutcome?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `SettingsToggle` wants a plain `Binding<Bool>`, but this switch cannot
    /// just write the value it is given: turning it on has to decide whether a
    /// confirmation is needed first, and turning it off has to reopen the
    /// store rather than merely record intent. The source of truth stays
    /// `storeMode.isLiveOnly`; a cancelled confirmation leaves that unchanged,
    /// so the toggle relaxes back to where it was without anything having
    /// moved.
    private var liveOnlyBinding: Binding<Bool> {
        Binding(
            get: { storeMode.isLiveOnly },
            set: { turnOn in
                guard turnOn else {
                    storeMode.setLiveOnly(false, deletingStoredData: false)
                    return
                }
                let summary = storeMode.storedDataSummary()
                if summary.isEmpty {
                    storeMode.setLiveOnly(true, deletingStoredData: false)
                } else {
                    pendingSummary = summary
                    isConfirmingLiveOnly = true
                }
            }
        )
    }

    var body: some View {
        SettingsSection(title: "Privacy", showDivider: false) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SettingsParagraph(text: Copy.reads)
                SettingsParagraph(text: Copy.leaves)
                SettingsParagraph(text: Copy.never)

                SettingsToggle(
                    title: Copy.liveOnlyTitle,
                    explanation: Copy.liveOnlyExplanation,
                    isOn: liveOnlyBinding
                )
                .padding(.top, Theme.Space.xs)

                if !storeMode.lastDeletionFailures.isEmpty {
                    deletionFailureNotice(storeMode.lastDeletionFailures)
                }

                clearDataRow
                    .padding(.top, Theme.Space.xs)

                reportRow
                    .padding(.top, Theme.Space.xs)

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
        .confirmationDialog(
            Copy.liveOnlyConfirmTitle,
            isPresented: $isConfirmingLiveOnly,
            titleVisibility: .visible
        ) {
            Button("Delete Stored History", role: .destructive) {
                storeMode.setLiveOnly(true, deletingStoredData: true)
                pendingSummary = nil
            }
            Button("Keep File, Stop Using It") {
                storeMode.setLiveOnly(true, deletingStoredData: false)
                pendingSummary = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSummary = nil
            }
            // Cancel is the default action, so a stray Return key does not
            // delete a history the user only meant to inspect.
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(pendingSummary.map(Copy.liveOnlyConfirmMessage) ?? Copy.liveOnlyConfirmFallback)
        }
        .confirmationDialog(
            Copy.clearDataConfirmTitle,
            isPresented: $isConfirmingClearData,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                // The engine has to forget along with the store, and forgetting
                // crosses into an actor, so the work is a task rather than a
                // straight call. See `StoreModeController.clearStoredData`.
                Task { await storeMode.clearStoredData() }
                pendingClearSummary = nil
            }
            Button("Cancel", role: .cancel) {
                pendingClearSummary = nil
            }
            // Same reasoning as the live-only dialog above: a stray Return
            // key must land on Cancel, not on a destructive delete.
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(pendingClearSummary.map(Copy.clearDataConfirmMessage) ?? Copy.clearDataConfirmFallback)
        }
    }

    // MARK: - Clear stored data (9.10d)

    /// Not a date-range delete: one button, everything, `VACUUM`d afterwards.
    /// `ClaudenceStore.deleteStoredData()` already keeps `sessions` and
    /// `read_cursors` in the same transaction, which is the invariant
    /// CLAUDE.md records -- a cursor surviving without its total resumes at
    /// byte N against a total of zero and corrupts the next rollup.
    private var clearDataRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            pillButton(title: "Clear Stored Data", tint: Theme.critical) {
                pendingClearSummary = storeMode.storedDataSummary()
                isConfirmingClearData = true
            }
            .accessibilityHint(Copy.clearDataExplanation)
            SettingsExplanation(text: Copy.clearDataExplanation)
        }
    }

    // MARK: - Problem report (9.10c)

    /// What the button writes, told back to the person who pressed it: the
    /// path it landed at, that nothing was saved because the panel was
    /// cancelled, or why the write failed. Never silent either way -- a
    /// button that reports nothing back is indistinguishable from one that
    /// silently sent something.
    private enum ReportOutcome: Equatable {
        case saved(path: String)
        case cancelled
        case failed(String)
    }

    private var reportRow: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            pillButton(title: "Save a Problem Report") {
                reportOutcome = Self.saveProblemReport(storeMode: storeMode, model: model)
            }
            .accessibilityHint(Copy.reportExplanation)
            SettingsExplanation(text: Copy.reportExplanation)
            if let reportOutcome {
                reportOutcomeLine(reportOutcome)
            }
        }
    }

    @ViewBuilder
    private func reportOutcomeLine(_ outcome: ReportOutcome) -> some View {
        switch outcome {
        case .saved(let path):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(Theme.healthy)
                    .accessibilityHidden(true)
                Text("Saved to \(path)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .cancelled:
            EmptyView()
        case .failed(let reason):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.critical)
                    .accessibilityHidden(true)
                Text("Could not save the report: \(reason)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Builds the report and asks where to put it. Nothing here is sent
    /// anywhere: `NSSavePanel` writes to a location the user chose, on this
    /// Mac, and that is the only thing this function does.
    ///
    /// `EngineCounters.shared` is read directly rather than threaded in,
    /// because it already is a process-wide singleton with no owner to pass
    /// through -- the same reason `--diagnose --counters` reads it the same
    /// way from the command line.
    @MainActor
    private static func saveProblemReport(
        storeMode: StoreModeController,
        model: MonitorViewModel
    ) -> ReportOutcome {
        let summary = storeMode.storedDataSummary()
        let environment = ProblemReport.Environment(
            appVersion: AppVersion.short,
            appBuild: AppVersion.build,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            storeHealth: storeMode.storeHealth,
            isLiveOnly: storeMode.isLiveOnly,
            databasePath: summary.fileURL?.path,
            databaseSizeBytes: summary.fileSizeBytes,
            liveSessionCount: model.sessions.count,
            storedSessionCount: summary.sessions,
            usageSampleCount: summary.usageSamples,
            rollupDayCount: summary.rollupDays,
            subagentTotalCount: summary.subagentTotals
        )
        let report = ProblemReport(environment: environment, counters: EngineCounters.shared.snapshot)

        let panel = NSSavePanel()
        panel.title = "Save Problem Report"
        panel.message = "Nothing is sent anywhere. This writes one file for you to send by hand."
        panel.nameFieldStringValue = report.suggestedFileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else {
            return .cancelled
        }
        do {
            try report.text().write(to: url, atomically: true, encoding: .utf8)
            return .saved(path: url.path)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Pill button chrome
    //
    // The same visual language as "Read the full disclosure" below: a
    // `surfaceControl` pill with a hairline border. `tint` recolours the label
    // alone, never the fill -- a destructive action here still reads as a
    // button first, not as a solid block of critical colour.
    private func pillButton(
        title: String,
        tint: Color = Theme.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.labelEmphasis)
                .foregroundStyle(tint)
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
        .accessibilityLabel(title)
    }

    // MARK: - Deletion failures

    /// What `StoreModeController.lastDeletionFailures` is for: a delete that
    /// silently left a file behind is worse than one that never ran, because
    /// the user is told the mode switched and believes the history is gone
    /// when the `-wal` or `-shm` sibling, or the file itself, is still on
    /// disk. Paired with a glyph rather than colour alone, per the rest of
    /// this app's indicators.
    private func deletionFailureNotice(_ files: [URL]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Theme.critical)
                    .accessibilityHidden(true)
                Text("Some stored files could not be deleted")
                    .font(Theme.Typography.labelEmphasis)
                    .foregroundStyle(Theme.critical)
            }
            ForEach(files, id: \.path) { file in
                Text(file.path)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textQuaternary)
            }
            Text("Live-only mode is on. Remove these by hand if you want them gone.")
                .font(Theme.Typography.help)
                .foregroundStyle(Theme.textQuaternary)
        }
        .accessibilityElement(children: .combine)
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

        // Live-only mode. `storageBody`, further down in the full disclosure,
        // names the same path this explanation does -- ~/Library/Application
        // Support/Claudence/claudence.db is the one file this whole section is
        // ever about, on or off.

        static let liveOnlyTitle = "Live-only mode"

        static let liveOnlyExplanation = """
        Claudence writes nothing to \
        ~/Library/Application Support/Claudence/claudence.db while this is on: \
        the database runs in memory for the rest of this run. History, project \
        totals, day-over-day figures and cost estimates are not shown in this \
        mode, because none of them can be worked out without what the database \
        holds.
        """

        static let liveOnlyConfirmTitle = "Turn on live-only mode?"

        /// Named counts rather than "your data": a confirmation that cannot say
        /// how much it is about to delete is not one a reader can act on.
        static func liveOnlyConfirmMessage(_ summary: ClaudenceStore.StoredDataSummary) -> String {
            let sizeSuffix = summary.fileSizeBytes.map { bytes in
                " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
            } ?? ""
            return """
            Claudence has \(summary.sessions) session\(summary.sessions == 1 ? "" : "s"), \
            \(summary.usageSamples) usage sample\(summary.usageSamples == 1 ? "" : "s") and \
            \(summary.rollupDays) day\(summary.rollupDays == 1 ? "" : "s") of rolled-up history\(sizeSuffix) \
            stored on this Mac. Delete it now, or keep the file untouched and simply stop using \
            it. Deletion cannot be undone.
            """
        }

        /// Used only if the confirmation somehow opens with no summary read yet.
        static let liveOnlyConfirmFallback = """
        Delete the stored history now, or keep the file untouched and simply \
        stop using it. Deletion cannot be undone.
        """

        // Clear stored data (9.10d). Not a date-range delete: everything, or
        // nothing -- a friend who wants Claudence to forget wants it to
        // forget, and a friend who wants to keep some history is not the
        // person pressing this button.

        static let clearDataExplanation = """
        Delete everything Claudence has saved on this Mac and reclaim the \
        space. Live sessions keep running and keep showing their own \
        numbers; history, day-over-day figures and project totals start over.
        """

        static let clearDataConfirmTitle = "Clear all stored data?"

        static func clearDataConfirmMessage(_ summary: ClaudenceStore.StoredDataSummary) -> String {
            let sizeSuffix = summary.fileSizeBytes.map { bytes in
                " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
            } ?? ""
            return """
            Claudence has \(summary.sessions) session\(summary.sessions == 1 ? "" : "s"), \
            \(summary.usageSamples) usage sample\(summary.usageSamples == 1 ? "" : "s") and \
            \(summary.rollupDays) day\(summary.rollupDays == 1 ? "" : "s") of rolled-up history\(sizeSuffix) \
            stored on this Mac. Delete all of it now and reclaim the space. This cannot be undone.
            """
        }

        /// Used only if the confirmation somehow opens with no summary read yet.
        static let clearDataConfirmFallback = """
        Delete everything stored on this Mac and reclaim the space. This \
        cannot be undone.
        """

        // Problem report (9.10c).

        static let reportExplanation = """
        Write one file with recent errors, counts and version numbers, with \
        your home folder abbreviated to ~. Nothing is sent anywhere -- you \
        choose where it is saved, and it is yours to send by hand or not.
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
