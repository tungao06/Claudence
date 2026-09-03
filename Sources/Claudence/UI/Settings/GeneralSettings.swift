import SwiftUI
import ClaudenceCore

/// How much of a session Claudence lists, and how often it asks Anthropic for
/// the usage windows.
///
/// The design's third block, with the design's three controls and nothing else.
/// Launch at login used to lead this file under a `Startup` eyebrow of its own;
/// it now sits in the menu bar block, where the design puts it, because it is a
/// fact about the menu bar item rather than about sessions.
///
/// Every control carries an accessibility label and a hint holding the same
/// sentence printed underneath it, so a VoiceOver user hears the explanation a
/// sighted user reads.
struct SessionsSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsSection(title: Self.sectionTitle) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsToggle(
                    title: Self.subagentsTitle,
                    explanation: Self.subagentsExplanation,
                    isOn: $preferences.showSubagents
                )
                SettingsToggle(
                    title: Self.compactTitle,
                    explanation: Self.compactExplanation,
                    isOn: $preferences.compactRows
                )
                SettingsPicker(
                    title: Self.refreshTitle,
                    options: UsageRefreshInterval.allCases,
                    optionTitle: \.title,
                    explanation: Self.refreshExplanation,
                    selection: $preferences.usageRefreshInterval
                )
            }
        }
    }

    // MARK: Copy

    private static let sectionTitle = Phrase(en: "Sessions", th: "Session")

    private static let subagentsTitle = Phrase(en: "Show subagents", th: "แสดง subagent")

    /// Design section 7, verbatim. Accurate: a subagent's tokens are billed to
    /// its parent, which is what "share of the parent" means here.
    private static let subagentsExplanation = Phrase(
        en: "List agents spawned under each session, with their share of the parent.",
        th: "แสดงรายการ agent ที่ถูก spawn ใต้แต่ละ session พร้อมสัดส่วนที่ใช้จาก parent"
    )

    private static let compactTitle = Phrase(en: "Compact rows", th: "แถวแบบย่อ")

    /// Design section 7, verbatim.
    private static let compactExplanation = Phrase(
        en: "Hide duration, rate and sparkline until a row is opened.",
        th: "ซ่อนระยะเวลา, อัตราการใช้ และ sparkline จนกว่าจะเปิดแถวนั้น"
    )

    private static let refreshTitle = Phrase(en: "Usage refresh", th: "ความถี่ในการอัปเดตการใช้งาน")

    /// Design section 7, verbatim, and the sentence that keeps this control
    /// honest: it paces one network call and touches nothing else.
    private static let refreshExplanation = Phrase(
        en: "Sessions and tokens update on file change; this only paces the usage-limit call.",
        th: "Session และ token อัปเดตทันทีเมื่อไฟล์เปลี่ยน การตั้งค่านี้กำหนดความถี่ของการเรียก usage-limit เท่านั้น"
    )
}
