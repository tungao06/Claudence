import SwiftUI
import ClaudenceCore

/// When Claudence is allowed to interrupt a human.
///
/// The four rows run in the design's own order — usage threshold, completed,
/// failed, permission — with two additions that are deliberate and are not the
/// design's:
///
/// - A master switch above them. The per-event switches are inert while it is
///   off, so they are disabled rather than left looking live. Nothing in the
///   design turns notifications off as a group; dropping the switch would take
///   a working capability away and leave "turn every one of them off
///   individually" as the only way to get silence.
/// - `Session goes idle`, which has a real `NotificationEvent` case, a real
///   preference key and a deriver that fires it. It is off by default because
///   pausing while you read a diff is the ordinary case, not news.
///
/// ## The two rows that cannot be switched on
///
/// The design draws one of the four, `Permission required`, disabled. The code
/// says two are undeliverable, not one, and this was checked against the code
/// rather than assumed:
///
/// - `SessionStatus.permission` returns false from `isDerivable`. Nothing in the
///   registry or the transcript says a session is waiting on a permission
///   prompt.
/// - `SessionStatus.error` returns false too, `NotificationEvent` has no case
///   for it, and the type's own doc comment records why: the registry carries no
///   exit condition at all. A session that crashed and one that finished cleanly
///   both leave by having their `~/.claude/sessions/<pid>.json` file removed,
///   with no exit code, no signal and no terminal status anywhere in the
///   snapshot. "Failed" cannot be told apart from "completed" without inventing
///   it.
///
/// So `Session failed` is drawn disabled as well. The design ships it enabled
/// and On; the design is wrong, and `CLAUDE.md`'s rule that no UI ships for a
/// state with no data source decides it. Both rows are
/// `SettingsUnavailableToggle`, which has no binding behind it: there is no
/// preference key for either, because a key that can only ever hold its default
/// is a lie in `UserDefaults`. Both come back the day a source is proven, and
/// neither the deriver nor the throttle needs a change to carry them.
struct NotificationSettings: View {
    @Bindable var preferences: Preferences

    var body: some View {
        SettingsSection(title: Self.sectionTitle) {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                SettingsToggle(
                    title: Self.masterTitle,
                    explanation: Self.masterExplanation,
                    isOn: $preferences.notificationsEnabled
                )

                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    SettingsToggle(
                        title: Self.usageThresholdTitle,
                        explanation: Self.usageThresholdExplanation,
                        isOn: $preferences.notifyOnUsageThreshold
                    )
                    SettingsToggle(
                        title: Self.completedTitle,
                        explanation: Self.completedExplanation,
                        isOn: $preferences.notifyOnSessionCompleted
                    )
                    SettingsUnavailableToggle(
                        title: Self.failedTitle,
                        reason: Self.failedUnavailable
                    )
                    SettingsUnavailableToggle(
                        title: Self.permissionTitle,
                        reason: Self.permissionUnavailable
                    )
                    SettingsToggle(
                        title: Self.needsInputTitle,
                        explanation: Self.needsInputExplanation,
                        isOn: $preferences.notifyOnSessionNeedsInput
                    )
                    SettingsToggle(
                        title: Self.idleTitle,
                        explanation: Self.idleExplanation,
                        isOn: $preferences.notifyOnSessionIdle
                    )
                }
                .padding(.leading, Theme.Layout.settingsExplanationIndent)
                .disabled(!preferences.notificationsEnabled)
            }
        }
    }

    // MARK: Copy

    private static let sectionTitle = Phrase(en: "Notifications", th: "การแจ้งเตือน")

    private static let masterTitle = Phrase(
        en: "Notify me about sessions and limits",
        th: "แจ้งเตือนเกี่ยวกับ session และโควต้าการใช้งาน"
    )

    private static let masterExplanation = Phrase(
        en: """
        A notification when a session finishes and when a usage window is nearly \
        spent. macOS asks for permission separately, the first time one is sent.
        """,
        th: """
        แจ้งเตือนเมื่อ session จบ และเมื่อโควต้าการใช้งานใกล้หมด macOS จะขอสิทธิ์แยกต่างหาก \
        ในครั้งแรกที่มีการส่งแจ้งเตือน
        """
    )

    /// Built from the constant the deriver fires on, so the label and the
    /// behaviour cannot drift apart.
    private static let usageThresholdTitle = Phrase(
        en: "Usage reaches \(Int(Constants.UsageThreshold.critical))%",
        th: "การใช้งานถึง \(Int(Constants.UsageThreshold.critical))%"
    )

    private static let usageThresholdExplanation = Phrase(
        en: """
        Once per window, when it crosses upward. A window that dips and crosses \
        again does not notify twice.
        """,
        th: """
        แจ้งครั้งเดียวต่อหน้าต่าง เมื่อค่าข้ามขึ้นไป หากค่าลดแล้วข้ามขึ้นอีกครั้งจะไม่แจ้งซ้ำ
        """
    )

    private static let completedTitle = Phrase(en: "Session completed", th: "Session เสร็จสิ้น")

    private static let completedExplanation = Phrase(
        en: """
        When a session is gone from the registry and its process is confirmed gone \
        with it. A discovery hiccup on its own never counts.
        """,
        th: """
        เมื่อ session หายไปจาก registry และยืนยันได้ว่า process หายไปด้วย ความผิดพลาดเล็กน้อย \
        ในการตรวจจับเพียงอย่างเดียวจะไม่นับ
        """
    )

    private static let failedTitle = Phrase(en: "Session failed", th: "Session ล้มเหลว")

    private static let permissionTitle = Phrase(en: "Permission required", th: "ต้องการสิทธิ์เพิ่มเติม")

    private static let needsInputTitle = Phrase(en: "Session needs an answer", th: "Session รอคำตอบ")

    private static let needsInputExplanation = Phrase(
        en: """
        When a session asks you something and stops until you answer. On by \
        default: it is the one state where nothing happens at all until you look. \
        Claudence never reads the question itself, so the notification names the \
        project and nothing more.
        """,
        th: """
        เมื่อ session ถามคำถามและหยุดรอจนกว่าคุณจะตอบ เปิดไว้เป็นค่าเริ่มต้น เพราะเป็นสถานะเดียว \
        ที่จะไม่มีอะไรเกิดขึ้นเลยจนกว่าคุณจะเข้าไปดู Claudence ไม่เคยอ่านคำถามจริง การแจ้งเตือนจึงบอก \
        แค่ชื่อโปรเจกต์เท่านั้น
        """
    )

    private static let idleTitle = Phrase(en: "Session goes idle", th: "Session ว่าง")

    private static let idleExplanation = Phrase(
        en: """
        When a session stops working but stays open. Off by default: pausing while \
        you read the diff is the ordinary case, not news.
        """,
        th: """
        เมื่อ session หยุดทำงานแต่ยังเปิดอยู่ ปิดไว้เป็นค่าเริ่มต้น เพราะการหยุดพักระหว่างที่คุณอ่าน diff \
        เป็นเรื่องปกติ ไม่ใช่เหตุการณ์ที่ต้องแจ้ง
        """
    )

    /// Deliberately not the design's generic sentence. The design's wording for
    /// the disabled row, "this state is not derivable yet", is true but says
    /// nothing about why, and this reason is specific and worth stating.
    private static let failedUnavailable = Phrase(
        en: """
        Unavailable. A session that crashed and one that finished cleanly leave the \
        same way, with no exit code recorded anywhere, so Claudence cannot tell them \
        apart without guessing.
        """,
        th: """
        ไม่พร้อมใช้งาน session ที่ crash และ session ที่จบตามปกติออกจากระบบแบบเดียวกัน \
        โดยไม่มี exit code บันทึกไว้ที่ไหนเลย Claudence จึงแยกความแตกต่างไม่ได้โดยไม่เดา
        """
    )

    /// The design's own explanation, with its em dash rewritten as a full stop.
    private static let permissionUnavailable = Phrase(
        en: "Unavailable. This state is not derivable yet.",
        th: "ไม่พร้อมใช้งาน สถานะนี้ยังไม่สามารถตรวจจับได้"
    )
}
