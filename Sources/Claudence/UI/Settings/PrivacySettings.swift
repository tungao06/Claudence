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

    @Environment(\.appLanguage) private var language

    var body: some View {
        SettingsSection(title: Copy.sectionTitle, showDivider: false) {
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
                        PhraseText(isShowingFullDisclosure ? Copy.hideDisclosure : Copy.readDisclosure)
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
                    .accessibilityLabel(Copy.readDisclosure, in: language)
                    .accessibilityValue((isShowingFullDisclosure ? Copy.showing : Copy.hidden).string(in: language))
                    .accessibilityHint(Copy.readDisclosureHint.string(in: language))

                    Spacer(minLength: Theme.Space.s)

                    // The design stamps `v0.1.0` here. This reads the bundle
                    // rather than printing a literal, because a version string
                    // nobody checked is a fabricated number like any other.
                    PhraseText(AppVersion.stampPhrase)
                        .font(Theme.Typography.micro)
                        .foregroundStyle(Theme.textQuaternary)
                        .accessibilityLabel(
                            Copy.versionLabel.format(in: language, AppVersion.displayPhrase.string(in: language))
                        )
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
            Copy.liveOnlyConfirmTitle.string(in: language),
            isPresented: $isConfirmingLiveOnly,
            titleVisibility: .visible
        ) {
            Button(Copy.deleteStoredHistory.string(in: language), role: .destructive) {
                storeMode.setLiveOnly(true, deletingStoredData: true)
                pendingSummary = nil
            }
            Button(Copy.keepFileStopUsing.string(in: language)) {
                storeMode.setLiveOnly(true, deletingStoredData: false)
                pendingSummary = nil
            }
            Button(Copy.cancel.string(in: language), role: .cancel) {
                pendingSummary = nil
            }
            // Cancel is the default action, so a stray Return key does not
            // delete a history the user only meant to inspect.
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(pendingSummary.map { Copy.liveOnlyConfirmMessage($0, in: language) }
                ?? Copy.liveOnlyConfirmFallback.string(in: language))
        }
        .confirmationDialog(
            Copy.clearDataConfirmTitle.string(in: language),
            isPresented: $isConfirmingClearData,
            titleVisibility: .visible
        ) {
            Button(Copy.deleteEverything.string(in: language), role: .destructive) {
                // The engine has to forget along with the store, and forgetting
                // crosses into an actor, so the work is a task rather than a
                // straight call. See `StoreModeController.clearStoredData`.
                Task { await storeMode.clearStoredData() }
                pendingClearSummary = nil
            }
            Button(Copy.cancel.string(in: language), role: .cancel) {
                pendingClearSummary = nil
            }
            // Same reasoning as the live-only dialog above: a stray Return
            // key must land on Cancel, not on a destructive delete.
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(pendingClearSummary.map { Copy.clearDataConfirmMessage($0, in: language) }
                ?? Copy.clearDataConfirmFallback.string(in: language))
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
            pillButton(title: Copy.clearStoredData, tint: Theme.critical) {
                pendingClearSummary = storeMode.storedDataSummary()
                isConfirmingClearData = true
            }
            .accessibilityHint(Copy.clearDataExplanation.string(in: language))
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
            pillButton(title: Copy.saveProblemReportTitle) {
                reportOutcome = Self.saveProblemReport(storeMode: storeMode, model: model, language: language)
            }
            .accessibilityHint(Copy.reportExplanation.string(in: language))
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
                Text(Copy.savedTo.format(in: language, path))
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
                Text(Copy.couldNotSaveReport.format(in: language, reason))
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
        model: MonitorViewModel,
        language: AppLanguage
    ) -> ReportOutcome {
        let summary = storeMode.storedDataSummary()
        let environment = ProblemReport.Environment(
            appVersion: AppVersion.short,
            appBuild: AppVersion.build,
            sourceRevision: AppVersion.sourceRevision,
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
        panel.title = Copy.saveProblemReportTitle.string(in: language)
        panel.message = Copy.saveProblemReportPanelMessage.string(in: language)
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
        title: Phrase,
        tint: Color = Theme.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            PhraseText(title)
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
        .accessibilityLabel(title, in: language)
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
                PhraseText(Copy.deletionFailureHeading)
                    .font(Theme.Typography.labelEmphasis)
                    .foregroundStyle(Theme.critical)
            }
            ForEach(files, id: \.path) { file in
                Text(file.path)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.textQuaternary)
            }
            PhraseText(Copy.deletionFailureFootnote)
                .font(Theme.Typography.help)
                .foregroundStyle(Theme.textQuaternary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Block

    struct Block: Identifiable {
        let id: String
        let heading: Phrase
        let glyph: String
        let body: Phrase

        /// `id` is the English heading, a stable identity independent of the
        /// language the block is currently rendered in.
        init(heading: Phrase, glyph: String, body: Phrase) {
            self.id = heading.en
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
                    PhraseText(block.heading)
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

        static let sectionTitle = Phrase(en: "Privacy", th: "ความเป็นส่วนตัว")

        static let readDisclosure = Phrase(en: "Read the full disclosure", th: "อ่านคำชี้แจงฉบับเต็ม")
        static let hideDisclosure = Phrase(en: "Hide the full disclosure", th: "ซ่อนคำชี้แจงฉบับเต็ม")
        static let readDisclosureHint = Phrase(
            en: "Shows exactly which files Claudence reads and which two requests leave this Mac",
            th: "แสดงว่า Claudence อ่านไฟล์ใดบ้าง และสองคำขอใดที่ออกจาก Mac เครื่องนี้"
        )
        static let showing = Phrase(en: "Showing", th: "กำลังแสดง")
        static let hidden = Phrase(en: "Hidden", th: "ซ่อนอยู่")
        static let versionLabel = Phrase(en: "Claudence version %@", th: "Claudence เวอร์ชัน %@")

        static let cancel = Phrase(en: "Cancel", th: "ยกเลิก")
        static let deleteEverything = Phrase(en: "Delete Everything", th: "ลบทั้งหมด")
        static let deleteStoredHistory = Phrase(en: "Delete Stored History", th: "ลบประวัติที่เก็บไว้")
        static let keepFileStopUsing = Phrase(en: "Keep File, Stop Using It", th: "เก็บไฟล์ไว้ แค่หยุดใช้")
        static let clearStoredData = Phrase(en: "Clear Stored Data", th: "ล้างข้อมูลที่เก็บไว้")
        static let saveProblemReportTitle = Phrase(en: "Save a Problem Report", th: "บันทึกรายงานปัญหา")
        static let saveProblemReportPanelMessage = Phrase(
            en: "Nothing is sent anywhere. This writes one file for you to send by hand.",
            th: "ไม่มีการส่งข้อมูลไปที่ใดเลย ปุ่มนี้จะบันทึกไฟล์หนึ่งไฟล์ให้คุณส่งต่อด้วยตัวเอง"
        )
        static let savedTo = Phrase(en: "Saved to %@", th: "บันทึกไว้ที่ %@")
        static let couldNotSaveReport = Phrase(
            en: "Could not save the report: %@",
            th: "บันทึกรายงานไม่สำเร็จ: %@"
        )

        static let deletionFailureHeading = Phrase(
            en: "Some stored files could not be deleted",
            th: "ไฟล์บางไฟล์ที่เก็บไว้ลบไม่สำเร็จ"
        )
        static let deletionFailureFootnote = Phrase(
            en: "Live-only mode is on. Remove these by hand if you want them gone.",
            th: "โหมด live-only เปิดอยู่ ลบไฟล์เหล่านี้ด้วยตัวเองหากต้องการให้หายไปจริง"
        )

        // The summary: the design's three paragraphs, one of them corrected.

        static let reads = Phrase(
            en: """
            Claudence reads four things on this Mac: the session registry, the \
            transcript files for token counts, your subscription plan name, and your \
            Claude Code credentials from the Keychain.
            """,
            th: """
            Claudence อ่านสี่อย่างบนเครื่อง Mac นี้: session registry, ไฟล์ transcript สำหรับนับ \
            token, ชื่อแผนสมัครสมาชิกของคุณ และข้อมูลรับรองตัวตนของ Claude Code จาก Keychain
            """
        )

        /// The design says one request. There are two. See the note on the type.
        static let leaves = Phrase(
            en: """
            Two requests ever leave this app: the usage-limit call to \
            api.anthropic.com, and a token refresh to platform.claude.com when your \
            sign-in has expired. There is no backend, no telemetry, no sync.
            """,
            th: """
            มีสองคำขอเท่านั้นที่ออกจากแอปนี้: คำขอตรวจสอบโควต้าการใช้งานไปยัง api.anthropic.com \
            และการขอ token ใหม่ไปยัง platform.claude.com เมื่อการเข้าสู่ระบบของคุณหมดอายุ \
            ไม่มี backend ไม่มี telemetry ไม่มีการ sync
            """
        )

        static let never = Phrase(
            en: """
            Message text, tool output and command strings are never read, stored, or \
            shown.
            """,
            th: """
            ข้อความ message, ผลลัพธ์ของ tool และคำสั่งที่รันจะไม่ถูกอ่าน ไม่ถูกเก็บ และไม่แสดงผลเลย
            """
        )

        // Live-only mode. `storageBody`, further down in the full disclosure,
        // names the same path this explanation does -- ~/Library/Application
        // Support/Claudence/claudence.db is the one file this whole section is
        // ever about, on or off.

        static let liveOnlyTitle = Phrase(en: "Live-only mode", th: "โหมด live-only")

        static let liveOnlyExplanation = Phrase(
            en: """
            Claudence writes nothing to \
            ~/Library/Application Support/Claudence/claudence.db while this is on: \
            the database runs in memory for the rest of this run. History, project \
            totals, day-over-day figures and cost estimates are not shown in this \
            mode, because none of them can be worked out without what the database \
            holds.
            """,
            th: """
            Claudence จะไม่เขียนอะไรลง ~/Library/Application Support/Claudence/claudence.db \
            ขณะเปิดโหมดนี้ ฐานข้อมูลจะทำงานอยู่ในหน่วยความจำตลอดการรันครั้งนี้เท่านั้น ประวัติ, \
            ยอดรวมของโปรเจกต์, ตัวเลขเทียบวันต่อวัน และค่าประมาณต้นทุนจะไม่แสดงในโหมดนี้ เพราะ \
            คำนวณไม่ได้เลยหากไม่มีสิ่งที่ฐานข้อมูลเก็บไว้
            """
        )

        static let liveOnlyConfirmTitle = Phrase(en: "Turn on live-only mode?", th: "เปิดโหมด live-only?")

        /// Named counts rather than "your data": a confirmation that cannot say
        /// how much it is about to delete is not one a reader can act on. Thai
        /// carries no plural inflection, so its half uses one wording for any
        /// count rather than the English singular/plural branch.
        static func liveOnlyConfirmMessage(_ summary: ClaudenceStore.StoredDataSummary, in language: AppLanguage) -> String {
            let sizeSuffix = summary.fileSizeBytes.map { bytes in
                " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
            } ?? ""
            switch language {
            case .english:
                return """
                Claudence has \(summary.sessions) session\(summary.sessions == 1 ? "" : "s"), \
                \(summary.usageSamples) usage sample\(summary.usageSamples == 1 ? "" : "s") and \
                \(summary.rollupDays) day\(summary.rollupDays == 1 ? "" : "s") of rolled-up history\(sizeSuffix) \
                stored on this Mac. Delete it now, or keep the file untouched and simply stop using \
                it. Deletion cannot be undone.
                """
            case .thai:
                return """
                Claudence มีข้อมูลเก็บอยู่บน Mac เครื่องนี้: \(summary.sessions) session, \
                \(summary.usageSamples) usage sample และประวัติที่สรุปแล้ว \(summary.rollupDays) \
                วัน\(sizeSuffix) ลบตอนนี้ได้เลย หรือจะเก็บไฟล์ไว้เฉยๆ แล้วแค่หยุดใช้งานก็ได้ \
                การลบไม่สามารถย้อนกลับได้
                """
            }
        }

        /// Used only if the confirmation somehow opens with no summary read yet.
        static let liveOnlyConfirmFallback = Phrase(
            en: """
            Delete the stored history now, or keep the file untouched and simply \
            stop using it. Deletion cannot be undone.
            """,
            th: """
            ลบประวัติที่เก็บไว้ตอนนี้ได้เลย หรือจะเก็บไฟล์ไว้เฉยๆ แล้วแค่หยุดใช้งานก็ได้ \
            การลบไม่สามารถย้อนกลับได้
            """
        )

        // Clear stored data (9.10d). Not a date-range delete: everything, or
        // nothing -- a friend who wants Claudence to forget wants it to
        // forget, and a friend who wants to keep some history is not the
        // person pressing this button.

        static let clearDataExplanation = Phrase(
            en: """
            Delete everything Claudence has saved on this Mac and reclaim the \
            space. Live sessions keep running and keep showing their own \
            numbers; history, day-over-day figures and project totals start over.
            """,
            th: """
            ลบทุกอย่างที่ Claudence บันทึกไว้บน Mac เครื่องนี้และคืนพื้นที่ว่าง session ที่กำลังทำงานอยู่ \
            จะยังทำงานต่อและแสดงตัวเลขของตัวเองตามปกติ ส่วนประวัติ, ตัวเลขเทียบวันต่อวัน และยอดรวม \
            โปรเจกต์จะเริ่มนับใหม่
            """
        )

        static let clearDataConfirmTitle = Phrase(en: "Clear all stored data?", th: "ล้างข้อมูลที่เก็บไว้ทั้งหมด?")

        static func clearDataConfirmMessage(_ summary: ClaudenceStore.StoredDataSummary, in language: AppLanguage) -> String {
            let sizeSuffix = summary.fileSizeBytes.map { bytes in
                " (\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)))"
            } ?? ""
            switch language {
            case .english:
                return """
                Claudence has \(summary.sessions) session\(summary.sessions == 1 ? "" : "s"), \
                \(summary.usageSamples) usage sample\(summary.usageSamples == 1 ? "" : "s") and \
                \(summary.rollupDays) day\(summary.rollupDays == 1 ? "" : "s") of rolled-up history\(sizeSuffix) \
                stored on this Mac. Delete all of it now and reclaim the space. This cannot be undone.
                """
            case .thai:
                return """
                Claudence มีข้อมูลเก็บอยู่บน Mac เครื่องนี้: \(summary.sessions) session, \
                \(summary.usageSamples) usage sample และประวัติที่สรุปแล้ว \(summary.rollupDays) \
                วัน\(sizeSuffix) ลบทั้งหมดตอนนี้และคืนพื้นที่ว่าง การกระทำนี้ย้อนกลับไม่ได้
                """
            }
        }

        /// Used only if the confirmation somehow opens with no summary read yet.
        static let clearDataConfirmFallback = Phrase(
            en: """
            Delete everything stored on this Mac and reclaim the space. This \
            cannot be undone.
            """,
            th: """
            ลบทุกอย่างที่เก็บไว้บน Mac เครื่องนี้และคืนพื้นที่ว่าง การกระทำนี้ย้อนกลับไม่ได้
            """
        )

        // Problem report (9.10c).

        static let reportExplanation = Phrase(
            en: """
            Write one file with recent errors, counts and version numbers, with \
            your home folder abbreviated to ~. Nothing is sent anywhere -- you \
            choose where it is saved, and it is yours to send by hand or not.
            """,
            th: """
            เขียนไฟล์หนึ่งไฟล์ที่มีข้อผิดพลาดล่าสุด ตัวเลขต่างๆ และหมายเลขเวอร์ชัน โดยย่อโฟลเดอร์ home \
            เป็น ~ ไม่มีการส่งข้อมูลไปที่ใดเลย คุณเป็นคนเลือกที่บันทึกเอง และเป็นสิทธิ์ของคุณว่าจะส่งต่อ \
            ด้วยมือหรือไม่
            """
        )

        // The full disclosure, behind the button.

        static let opening = Phrase(
            en: """
            Claudence runs entirely on this Mac. Here is exactly what it reads and \
            exactly what leaves the machine.
            """,
            th: """
            Claudence ทำงานอยู่บนเครื่อง Mac นี้เท่านั้น นี่คือสิ่งที่มันอ่านและสิ่งที่ออกจากเครื่องอย่างชัดเจน
            """
        )

        static let sessionsHeading = Phrase(en: "Your list of sessions", th: "รายการ session ของคุณ")
        static let sessionsBody = Phrase(
            en: """
            Claudence reads the small files Claude Code writes in ~/.claude/sessions. \
            From each one it takes six things: the process id, the folder the session \
            is running in, the session's name, whether it is busy or idle, when it \
            started, and which version of Claude Code wrote the file.
            """,
            th: """
            Claudence อ่านไฟล์ขนาดเล็กที่ Claude Code เขียนไว้ใน ~/.claude/sessions จากแต่ละไฟล์ \
            จะอ่านหกอย่าง: process id, โฟลเดอร์ที่ session กำลังรันอยู่, ชื่อของ session, สถานะว่ากำลัง \
            ทำงานหรือว่างอยู่, เวลาที่เริ่ม และเวอร์ชันของ Claude Code ที่เขียนไฟล์นั้น
            """
        )

        static let transcriptsHeading = Phrase(
            en: "Your token counts and current activity",
            th: "จำนวน token และกิจกรรมปัจจุบันของคุณ"
        )
        static let transcriptsBody = Phrase(
            en: """
            Claudence reads the transcript files Claude Code writes in \
            ~/.claude/projects. From each line it takes the token counts, the model \
            name, the name of the tool Claude is running right now, and the path of \
            the file that tool is working on. That is how Claudence can say \
            "Editing Menu.tsx" without reading Menu.tsx.
            """,
            th: """
            Claudence อ่านไฟล์ transcript ที่ Claude Code เขียนไว้ใน ~/.claude/projects จากแต่ละ \
            บรรทัดจะอ่านจำนวน token, ชื่อโมเดล, ชื่อ tool ที่ Claude กำลังรันอยู่ตอนนี้ และ path ของไฟล์ \
            ที่ tool นั้นกำลังทำงานด้วย นี่คือวิธีที่ Claudence พูดว่า "กำลังแก้ไข Menu.tsx" ได้โดยไม่ต้อง \
            อ่านเนื้อหาในไฟล์ Menu.tsx เลย
            """
        )

        static let planHeading = Phrase(en: "Your subscription plan", th: "แผนสมัครสมาชิกของคุณ")
        static let planBody = Phrase(
            en: """
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
            """,
            th: """
            Claudence อ่านสองฟิลด์จาก ~/.claude.json เพื่อแสดง "Max 5x" หรือ "Pro" ไว้ด้านบนของ \
            popover: ประเภทของแผนและระดับ rate-limit ทั้งสองอย่างนี้บอกชื่อผลิตภัณฑ์ ไม่ใช่ตัวคุณ \
            และเหมือนกันสำหรับทุกคนที่อยู่แผนนั้น

            ไฟล์เดียวกันนี้ยังเก็บอีเมล, ชื่อของคุณ, ชื่อองค์กร และทุกโฟลเดอร์ที่คุณเคยเปิดใน Claude Code \
            ด้วย Claudence ไม่อ่านสิ่งเหล่านั้นเลย ตัวอ่านประกาศไว้ชัดเจนแค่สองฟิลด์นั้นเท่านั้น และมี test \
            ที่จะล้มเหลวทันทีหากมีอะไรมากกว่านั้นไปถึงหน้าจอ

            หากไม่มีชื่อแผน ทุกเปอร์เซ็นต์ในแอปนี้จะเป็นสัดส่วนของโควต้าที่ไม่เคยระบุค่า: 62% ของโควต้า \
            Max 20x คืองานมากกว่า 62% ของ Max 5x ถึงสี่เท่า
            """
        )

        static let neverHeading = Phrase(en: "What Claudence never reads", th: "สิ่งที่ Claudence ไม่เคยอ่าน")
        static let neverBody = Phrase(
            en: """
            Your prompts. Claude's replies. The output of any command. The contents \
            of any file. The text of any command Claude runs.

            Claude Code records the commands it runs. Claudence turns each command \
            into a SHA-256 hash and keeps only the hash. The hash is never shown to \
            you and never leaves this Mac. This is deliberate: command lines \
            routinely carry API keys and database passwords, so Claudence says \
            "Running a command" and stops there.
            """,
            th: """
            prompt ของคุณ คำตอบของ Claude ผลลัพธ์ของคำสั่งใดๆ เนื้อหาของไฟล์ใดๆ ข้อความของคำสั่งที่ \
            Claude รัน

            Claude Code บันทึกคำสั่งที่มันรันไว้ Claudence แปลงแต่ละคำสั่งเป็น SHA-256 hash และเก็บ \
            ไว้แค่ hash เท่านั้น hash นี้จะไม่แสดงให้คุณเห็นและไม่ออกจากเครื่อง Mac นี้เลย ตั้งใจทำแบบนี้ \
            เพราะคำสั่งมักมี API key และรหัสผ่านฐานข้อมูลติดมาด้วย Claudence จึงพูดแค่ "กำลังรันคำสั่ง" \
            แล้วหยุดไว้แค่นั้น
            """
        )

        static let tokenHeading = Phrase(en: "Your Claude Code sign-in", th: "การเข้าสู่ระบบ Claude Code ของคุณ")
        static let tokenBody = Phrase(
            en: """
            Claudence reads your Claude Code sign-in token from the macOS Keychain. \
            If the Keychain has no entry, it looks in ~/.claude/.credentials.json, \
            where older versions of Claude Code kept the same token. The token is \
            used for one purpose: asking Anthropic how much of your usage limit is \
            left. It is never written to disk, never logged, and never shown.
            """,
            th: """
            Claudence อ่าน token การเข้าสู่ระบบ Claude Code ของคุณจาก macOS Keychain หาก Keychain \
            ไม่มีข้อมูลนี้ จะไปดูที่ ~/.claude/.credentials.json ซึ่งเป็นที่ที่ Claude Code เวอร์ชันเก่าเก็บ \
            token เดียวกันไว้ token นี้ใช้เพื่อจุดประสงค์เดียว: ถาม Anthropic ว่าโควต้าการใช้งานของคุณ \
            เหลือเท่าไร จะไม่ถูกเขียนลงดิสก์ ไม่ถูก log และไม่แสดงผลเลย
            """
        )

        static let networkHeading = Phrase(en: "What leaves this Mac", th: "สิ่งที่ออกจาก Mac เครื่องนี้")
        static let networkBody = Phrase(
            en: """
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
            """,
            th: """
            มีสองคำขอเท่านั้น คำขอแรกถาม api.anthropic.com ว่าโควต้าการใช้งานของคุณเหลือเท่าไร \
            พร้อมส่ง token ของคุณไปเท่านั้น ไม่มีอย่างอื่น คำขอที่สองจะส่งก็ต่อเมื่อ token หมดอายุเท่านั้น: \
            Claudence ขอ token ใหม่จาก platform.claude.com แล้วจึงส่งคำขอแรก ไม่มีส่วนอื่นใดของแอปนี้ \
            ที่ติดต่อเครือข่ายเลย

            ที่อยู่ทั้งสองนี้กับ console.anthropic.com เป็นที่อยู่เดียวที่ Claudence ได้รับอนุญาตให้เชื่อมต่อ \
            หากคำตอบพยายามเปลี่ยนเส้นทางไปที่อื่น Claudence จะปฏิเสธไม่ทำตาม

            ไม่มี telemetry ไม่มี analytics และไม่มีการ sync ไม่มีข้อมูลใดเกี่ยวกับโค้ด, prompt, ชื่อไฟล์ \
            หรือ session ของคุณถูกส่งไปที่ใดเลย
            """
        )

        static let storageHeading = Phrase(en: "Where your history is kept", th: "ที่เก็บประวัติของคุณ")
        static let storageBody = Phrase(
            en: """
            On this Mac only, in a SQLite database at \
            ~/Library/Application Support/Claudence/claudence.db. It holds token \
            totals and session records so the daily figures survive a restart. \
            Delete that file and the history is gone.
            """,
            th: """
            บนเครื่อง Mac นี้เท่านั้น ในฐานข้อมูล SQLite ที่ \
            ~/Library/Application Support/Claudence/claudence.db เก็บยอดรวม token และบันทึก \
            session ไว้ เพื่อให้ตัวเลขรายวันอยู่รอดหลังรีสตาร์ท ลบไฟล์นั้นแล้วประวัติจะหายไป
            """
        )

        static let estimatesHeading = Phrase(en: "Estimates, not bills", th: "ค่าประมาณ ไม่ใช่ใบเรียกเก็บเงิน")
        /// Section 9.4: anything derived rather than measured says so, every
        /// time it is shown. This paragraph used to be the whole reason an
        /// `About` section existed; the section is gone, because the design has
        /// none, and the sentence is here, where the rest of "what this
        /// application is actually claiming" already lives.
        static let estimatesBody = Phrase(
            en: """
            Usage and cost figures are estimates. Token counts come from the \
            transcript files Claude Code writes, and cost is worked out from \
            published model prices. Neither is a bill. Where a figure cannot be \
            worked out, Claudence says so instead of showing a zero.
            """,
            th: """
            ตัวเลขการใช้งานและต้นทุนเป็นค่าประมาณ จำนวน token มาจากไฟล์ transcript ที่ Claude Code \
            เขียนไว้ ส่วนต้นทุนคำนวณจากราคาโมเดลที่เผยแพร่ไว้ ทั้งสองอย่างไม่ใช่ใบเรียกเก็บเงิน หากคำนวณ \
            ตัวเลขไม่ได้ Claudence จะบอกตรงๆ แทนที่จะแสดงเป็นศูนย์
            """
        )

        static let blocks: [Block] = [
            Block(heading: Phrase(en: "What this covers", th: "สิ่งที่คำชี้แจงนี้ครอบคลุม"), glyph: "info.circle", body: opening),
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
