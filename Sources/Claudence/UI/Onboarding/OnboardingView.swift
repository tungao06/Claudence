import SwiftUI
import ClaudenceCore

/// The screen shown once, before anything in this application asks the
/// Keychain for a token.
///
/// ## Why this exists
///
/// Until now the Keychain prompt arrived cold: the first thing a freshly
/// installed copy of Claudence did, on the very first popover click, was ask
/// macOS for permission to read `Claude Code-credentials`, with no sentence
/// anywhere explaining why. A friend who clicked Deny -- a reasonable
/// response to an unexplained request -- was left with an application that
/// looked broken, because nothing told them what they had just refused or
/// that refusing was even a normal thing to do. This screen gives the reason
/// before the request, the same order any reasonable person would want them
/// in.
///
/// ## What is on it, and where the words came from
///
/// Every sentence about what is read or not read is drawn from
/// `PrivacySettings.Copy` (the settings window's own disclosure) or, where
/// that file has no equivalent paragraph yet -- the subagent metadata fields
/// -- from the privacy section of `CLAUDE.md` directly. Nothing here is a new
/// claim; see the doc comments beside each paragraph below for exactly which
/// source it was taken from.
///
/// ## What it does not yet do
///
/// The screen's own copy stays in English. PLAN.md 9.10b, "Thai and
/// English," is the item that converts every user-facing literal in the
/// application, and it has not run yet. What *is* wired here is the
/// preference and the picker themselves (`Preferences.languagePreference`),
/// plus the one piece of copy on this screen that is already bilingual --
/// `ClaudeCodePresence.title`/`.detail` -- so picking a language has a
/// visible, honest effect today instead of doing nothing until 9.10b lands.
struct OnboardingView: View {
    @Bindable var preferences: Preferences
    let historyImportRunner: HistoryImportRunner
    let presence: ClaudeCodePresence
    let onFinish: () -> Void

    @State private var importRange: ImportRange = .everything
    @State private var importState: ImportState = .idle

    private var language: AppLanguage { preferences.appLanguage }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.xxl) {
                    header
                    languageSection
                    privacySection
                    presenceSection
                    importSection
                }
                .padding(Theme.Space.xxl)
            }
            footer
        }
        .frame(width: 560, height: 660)
        .background(Theme.surface)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("Welcome to Claudence")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            Text("Before anything else, here is exactly what this app reads on your Mac.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        SettingsSection(title: "Language") {
            SettingsPicker(
                title: "Interface language",
                options: LanguagePreference.allCases,
                optionTitle: \.title,
                explanation: "Only this screen's Claude Code message follows this choice today. "
                    + "The rest of the interface is English until translation lands.",
                selection: $preferences.languagePreference
            )
        }
    }

    // MARK: - Privacy

    /// Verbatim, from `PrivacySettings.Copy`: the settings window's own
    /// three-paragraph summary, unchanged. `Copy.leaves` is what names the
    /// two outbound requests this task calls out specifically.
    private var privacySection: some View {
        SettingsSection(title: "What Claudence reads") {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SettingsParagraph(text: PrivacySettings.Copy.reads)
                SettingsParagraph(text: Self.subagentBody)
                SettingsParagraph(text: PrivacySettings.Copy.leaves)
                SettingsParagraph(text: PrivacySettings.Copy.never)
            }
        }
    }

    /// Not in `PrivacySettings.Copy` -- that file's full disclosure has no
    /// block for this yet. Drawn instead from `CLAUDE.md`'s own subagent
    /// paragraph: the three fields `SubagentLocator.Meta` decodes are
    /// `agentType`, `description` and `toolUseId`, and nothing else in that
    /// file is read.
    ///
    /// It named a fourth, `spawnDepth`, for a few hours on 2026-09-03. That
    /// field was dropped from the decoder and from the allowlist earlier the
    /// same day, in the 9.9 subtraction pass, because nothing rendered it. A
    /// first-run screen that claims a read the code does not perform is worse
    /// than one that says too little, so this sentence follows the decoder.
    private static let subagentBody = """
    For a session that spawned subagents, Claudence also reads three fields \
    from each one's spawn record: its type, a short task label, and the tool \
    call that created it. Not its prompt, its messages, or its results -- \
    those follow the same rules as everything else above.
    """

    // MARK: - Claude Code presence

    @ViewBuilder
    private var presenceSection: some View {
        SettingsSection(title: "Claude Code") {
            if presence.isUsable {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Theme.Bar.severityGlyph))
                        .foregroundStyle(Theme.healthy)
                    Text("Claude Code found. Its sessions will appear as soon as you continue.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                UnavailableView(
                    presence.title?.string(in: language) ?? "Claude Code is not installed",
                    reason: presence.detail?.string(in: language)
                )
            }
        }
    }

    // MARK: - Import

    private var importSection: some View {
        SettingsSection(title: "Import existing history", showDivider: false) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsPicker(
                    title: "How far back",
                    options: ImportRange.allCases,
                    optionTitle: \.title,
                    explanation: "Reads the transcripts already on this Mac through the same "
                        + "parser the live view uses. Nothing beyond the privacy allowlist above "
                        + "is read here either.",
                    selection: $importRange,
                    isEnabled: presence.isUsable && importState.isIdleOrDone
                )

                importActionRow

                if let report = importState.report {
                    importReportView(report)
                } else if case .failed = importState {
                    Text("The import could not finish. You can try again, or skip this and continue.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.critical)
                }
            }
        }
    }

    private var importActionRow: some View {
        HStack(spacing: Theme.Space.m) {
            Button(importButtonTitle) {
                runImport()
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.labelEmphasis)
            .foregroundStyle(presence.isUsable ? Theme.accentDeep : Theme.textDisabled)
            .disabled(!presence.isUsable || importState == .running)

            if importState == .running {
                Text("Reading transcripts\u{2026}")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var importButtonTitle: String {
        switch importState {
        case .idle, .failed: return "Import Now"
        case .running: return "Importing\u{2026}"
        case .done: return "Import Again"
        }
    }

    private func importReportView(_ report: HistoryImporter.Report) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: Theme.Bar.statusGlyph))
                    .foregroundStyle(Theme.healthy)
                Text(Self.importedSummary(report))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !report.sessionsSkipped.isEmpty {
                Text("\(report.sessionsSkipped.count) session(s) were outside the chosen range.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
            }
            if !report.failures.isEmpty {
                Text("\(report.failures.count) file(s) could not be read.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Built as plain `String` arithmetic rather than inline inside a `Text`
    /// initializer -- the compiler could not type-check the interpolated,
    /// pluralised version in reasonable time once it sat inside a view
    /// builder closure.
    private static func importedSummary(_ report: HistoryImporter.Report) -> String {
        let sessionWord = report.sessionsImported == 1 ? "session" : "sessions"
        let projectWord = report.projectsSeen == 1 ? "project" : "projects"
        return "Imported \(report.sessionsImported) \(sessionWord) across "
            + "\(report.projectsSeen) \(projectWord)."
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(AppVersion.stamp)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
            Spacer()
            Button("Get Started") {
                onFinish()
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.labelEmphasis)
            .foregroundStyle(Theme.textPrimary)
            .padding(.vertical, Theme.Space.s)
            .padding(.horizontal, Theme.Space.xl)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(Theme.accent)
            )
            .accessibilityHint(
                "Closes this screen and lets Claudence start reading your sessions and usage."
            )
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.l)
        .background(Theme.surfaceFooter)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    // MARK: - Import action

    private func runImport() {
        guard importState != .running else { return }
        importState = .running
        let startDate = importRange.startDate()
        Task { @MainActor in
            let report = await historyImportRunner.run(startDate)
            importState = .done(report)
        }
    }
}

// MARK: - Import range

/// How far back the chosen import reads. PLAN.md 9.12 asks for "a one-time
/// import with a chosen start date" -- these three are the choice, not a
/// free-form date picker, because a friend's first decision about their own
/// history should not require knowing when their oldest session was.
enum ImportRange: String, CaseIterable, Identifiable, Sendable {
    case everything
    case last30
    case last90

    var id: String { rawValue }

    var title: String {
        switch self {
        case .everything: return "Everything"
        case .last30: return "Last 30 days"
        case .last90: return "Last 90 days"
        }
    }

    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        switch self {
        case .everything: return .distantPast
        case .last30: return calendar.date(byAdding: .day, value: -30, to: now) ?? .distantPast
        case .last90: return calendar.date(byAdding: .day, value: -90, to: now) ?? .distantPast
        }
    }
}

// MARK: - Import state

enum ImportState: Equatable {
    case idle
    case running
    case done(HistoryImporter.Report)
    case failed

    static func == (lhs: ImportState, rhs: ImportState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.running, .running), (.failed, .failed): return true
        case let (.done(a), .done(b)): return a == b
        default: return false
        }
    }

    var report: HistoryImporter.Report? {
        if case let .done(report) = self { return report }
        return nil
    }

    var isIdleOrDone: Bool {
        switch self {
        case .idle, .done, .failed: return true
        case .running: return false
        }
    }
}
