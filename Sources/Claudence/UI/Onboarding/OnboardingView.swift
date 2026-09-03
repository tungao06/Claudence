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
/// ## Language
///
/// PLAN.md 9.10b, "Thai and English," converted every user-facing literal on
/// this screen to `Phrase`, alongside the rest of the application. The
/// language picker (`Preferences.languagePreference`) now has a visible
/// effect on every paragraph here, not only on `ClaudeCodePresence.title`/
/// `.detail`, which was the one piece of copy already bilingual before this
/// item ran.
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
            PhraseText(Self.welcomeTitle)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
            PhraseText(Self.welcomeSubtitle)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private static let welcomeTitle = Phrase(en: "Welcome to Claudence", th: "ยินดีต้อนรับสู่ Claudence")
    private static let welcomeSubtitle = Phrase(
        en: "Before anything else, here is exactly what this app reads on your Mac.",
        th: "ก่อนอื่นเลย นี่คือสิ่งที่แอปนี้อ่านบนเครื่อง Mac ของคุณอย่างชัดเจน"
    )

    // MARK: - Language

    private var languageSection: some View {
        SettingsSection(title: Self.languageSectionTitle) {
            SettingsPicker(
                title: Self.interfaceLanguageTitle,
                options: LanguagePreference.allCases,
                optionTitle: \.title,
                explanation: Self.languageExplanation,
                selection: $preferences.languagePreference
            )
        }
    }

    private static let languageSectionTitle = Phrase(en: "Language", th: "ภาษา")
    private static let interfaceLanguageTitle = Phrase(en: "Interface language", th: "ภาษาของอินเทอร์เฟซ")
    private static let languageExplanation = Phrase(
        en: "Changes every screen in the application, including this one.",
        th: "เปลี่ยนทุกหน้าจอในแอปพลิเคชัน รวมถึงหน้านี้ด้วย"
    )

    // MARK: - Privacy

    /// Verbatim, from `PrivacySettings.Copy`: the settings window's own
    /// three-paragraph summary, unchanged. `Copy.leaves` is what names the
    /// two outbound requests this task calls out specifically.
    private var privacySection: some View {
        SettingsSection(title: Self.privacySectionTitle) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                SettingsParagraph(text: PrivacySettings.Copy.reads)
                SettingsParagraph(text: Self.subagentBody)
                SettingsParagraph(text: PrivacySettings.Copy.leaves)
                SettingsParagraph(text: PrivacySettings.Copy.never)
            }
        }
    }

    private static let privacySectionTitle = Phrase(en: "What Claudence reads", th: "สิ่งที่ Claudence อ่าน")

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
    private static let subagentBody = Phrase(
        en: """
        For a session that spawned subagents, Claudence also reads three fields \
        from each one's spawn record: its type, a short task label, and the tool \
        call that created it. Not its prompt, its messages, or its results -- \
        those follow the same rules as everything else above.
        """,
        th: """
        สำหรับ session ที่ spawn subagent ไว้ Claudence จะอ่านเพิ่มอีกสามฟิลด์จาก spawn record \
        ของแต่ละตัว: ประเภทของมัน, label งานสั้นๆ และ tool call ที่สร้างมันขึ้นมา ไม่ใช่ prompt, \
        message หรือผลลัพธ์ของมัน สิ่งเหล่านั้นเป็นไปตามกฎเดียวกับที่กล่าวไว้ข้างต้นทั้งหมด
        """
    )

    // MARK: - Claude Code presence

    @ViewBuilder
    private var presenceSection: some View {
        SettingsSection(title: Self.claudeCodeTitle) {
            if presence.isUsable {
                HStack(spacing: Theme.Space.s) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: Theme.Bar.severityGlyph))
                        .foregroundStyle(Theme.healthy)
                    PhraseText(Self.claudeCodeFound)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else {
                UnavailableView(
                    presence.title ?? Self.claudeCodeNotInstalled,
                    reason: presence.detail
                )
            }
        }
    }

    private static let claudeCodeTitle = Phrase.untranslated("Claude Code")
    private static let claudeCodeFound = Phrase(
        en: "Claude Code found. Its sessions will appear as soon as you continue.",
        th: "พบ Claude Code แล้ว session ของมันจะปรากฏทันทีที่คุณดำเนินการต่อ"
    )
    private static let claudeCodeNotInstalled = Phrase(
        en: "Claude Code is not installed",
        th: "ยังไม่ได้ติดตั้ง Claude Code"
    )

    // MARK: - Import

    private var importSection: some View {
        SettingsSection(title: Self.importSectionTitle, showDivider: false) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsPicker(
                    title: Self.howFarBackTitle,
                    options: ImportRange.allCases,
                    optionTitle: \.title,
                    explanation: Self.howFarBackExplanation,
                    selection: $importRange,
                    isEnabled: presence.isUsable && importState.isIdleOrDone
                )

                importActionRow

                if let report = importState.report {
                    importReportView(report)
                } else if case .failed = importState {
                    PhraseText(Self.importFailed)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.critical)
                }
            }
        }
    }

    private static let importSectionTitle = Phrase(en: "Import existing history", th: "นำเข้าประวัติที่มีอยู่")
    private static let howFarBackTitle = Phrase(en: "How far back", th: "ย้อนหลังแค่ไหน")
    private static let howFarBackExplanation = Phrase(
        en: """
        Reads the transcripts already on this Mac through the same parser the \
        live view uses. Nothing beyond the privacy allowlist above is read here \
        either.
        """,
        th: """
        อ่าน transcript ที่มีอยู่แล้วบนเครื่อง Mac นี้ ผ่าน parser ตัวเดียวกับที่หน้าจอหลักใช้ ไม่มีการ \
        อ่านสิ่งใดเกินกว่ารายการที่อนุญาตด้านบนที่นี่เช่นกัน
        """
    )
    private static let importFailed = Phrase(
        en: "The import could not finish. You can try again, or skip this and continue.",
        th: "การนำเข้าไม่สำเร็จ คุณลองใหม่อีกครั้งได้ หรือข้ามขั้นตอนนี้แล้วดำเนินการต่อ"
    )

    private var importActionRow: some View {
        HStack(spacing: Theme.Space.m) {
            Button(importButtonTitle.string(in: language)) {
                runImport()
            }
            .buttonStyle(.plain)
            .font(Theme.Typography.labelEmphasis)
            .foregroundStyle(presence.isUsable ? Theme.accentDeep : Theme.textDisabled)
            .disabled(!presence.isUsable || importState == .running)

            if importState == .running {
                PhraseText(Self.readingTranscripts)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private static let readingTranscripts = Phrase(
        en: "Reading transcripts\u{2026}",
        th: "กำลังอ่าน transcript\u{2026}"
    )

    private var importButtonTitle: Phrase {
        switch importState {
        case .idle, .failed: return Phrase(en: "Import Now", th: "นำเข้าตอนนี้")
        case .running: return Phrase(en: "Importing\u{2026}", th: "กำลังนำเข้า\u{2026}")
        case .done: return Phrase(en: "Import Again", th: "นำเข้าอีกครั้ง")
        }
    }

    private func importReportView(_ report: HistoryImporter.Report) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: Theme.Bar.statusGlyph))
                    .foregroundStyle(Theme.healthy)
                Text(Self.importedSummary(report, in: language))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            if !report.sessionsSkipped.isEmpty {
                Text(Self.sessionsSkipped.format(in: language, "\(report.sessionsSkipped.count)"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textQuaternary)
            }
            if !report.failures.isEmpty {
                Text(Self.filesUnreadable.format(in: language, "\(report.failures.count)"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.attention)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static let sessionsSkipped = Phrase(
        en: "%@ session(s) were outside the chosen range.",
        th: "มี %@ session ที่อยู่นอกช่วงเวลาที่เลือก"
    )
    private static let filesUnreadable = Phrase(
        en: "%@ file(s) could not be read.",
        th: "มี %@ ไฟล์ที่อ่านไม่ได้"
    )

    /// Built as plain `String` arithmetic rather than inline inside a `Text`
    /// initializer -- the compiler could not type-check the interpolated,
    /// pluralised version in reasonable time once it sat inside a view
    /// builder closure. Thai carries no plural inflection, so its half needs
    /// only one wording, unlike the English singular/plural branch.
    private static func importedSummary(_ report: HistoryImporter.Report, in language: AppLanguage) -> String {
        switch language {
        case .english:
            let sessionWord = report.sessionsImported == 1 ? "session" : "sessions"
            let projectWord = report.projectsSeen == 1 ? "project" : "projects"
            return "Imported \(report.sessionsImported) \(sessionWord) across "
                + "\(report.projectsSeen) \(projectWord)."
        case .thai:
            return "นำเข้า \(report.sessionsImported) session จาก \(report.projectsSeen) โปรเจกต์"
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            PhraseText(AppVersion.stampPhrase)
                .font(Theme.Typography.micro)
                .foregroundStyle(Theme.textQuaternary)
            Spacer()
            Button(Self.getStarted.string(in: language)) {
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
            .accessibilityHint(Self.getStartedHint.string(in: language))
        }
        .padding(.horizontal, Theme.Space.xxl)
        .padding(.vertical, Theme.Space.l)
        .background(Theme.surfaceFooter)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    private static let getStarted = Phrase(en: "Get Started", th: "เริ่มต้นใช้งาน")
    private static let getStartedHint = Phrase(
        en: "Closes this screen and lets Claudence start reading your sessions and usage.",
        th: "ปิดหน้าจอนี้และให้ Claudence เริ่มอ่าน session และการใช้งานของคุณ"
    )

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

    var title: Phrase {
        switch self {
        case .everything: return Phrase(en: "Everything", th: "ทั้งหมด")
        case .last30: return Phrase(en: "Last 30 days", th: "30 วันล่าสุด")
        case .last90: return Phrase(en: "Last 90 days", th: "90 วันล่าสุด")
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
