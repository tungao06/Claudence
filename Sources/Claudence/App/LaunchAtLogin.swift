import ClaudenceCore
import Foundation
import ServiceManagement

// MARK: - State

/// What macOS actually reports about the login item, mapped one-to-one onto
/// `SMAppService.Status`.
///
/// The distinction matters because registration is allowed to fail. An app that
/// runs from the build directory and is signed with a local development
/// certificate rather than a Developer ID is exactly the case macOS is entitled
/// to refuse. So nothing in this file infers success from the absence of a
/// thrown error: every operation is followed by a fresh read of the real status,
/// and that read is what the interface shows.
enum LaunchAtLoginState: Equatable, Sendable {
    /// macOS will start Claudence at login.
    case enabled
    /// macOS knows the item and is not starting it.
    case notRegistered
    /// The item exists but the user has to allow it in System Settings.
    case requiresApproval
    /// macOS has no login item for this copy of the app.
    case notFound
    /// A status added after this code was written. Reported, never guessed at.
    case unrecognized(Int)

    init(_ status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .notRegistered: self = .notRegistered
        case .requiresApproval: self = .requiresApproval
        case .notFound: self = .notFound
        @unknown default: self = .unrecognized(status.rawValue)
        }
    }

    /// The only place that decides whether the toggle reads as on.
    var isEnabled: Bool { self == .enabled }

    /// One short line naming the real status. Written for a reader who has
    /// never heard of `SMAppService`.
    var summary: Phrase {
        switch self {
        case .enabled:
            return Phrase(en: "Registered with macOS", th: "ลงทะเบียนกับ macOS แล้ว")
        case .notRegistered:
            return Phrase(en: "Not registered", th: "ยังไม่ได้ลงทะเบียน")
        case .requiresApproval:
            return Phrase(en: "Waiting for your approval", th: "รอการอนุมัติจากคุณ")
        case .notFound:
            return Phrase(en: "No login item for this copy", th: "ไม่มี login item สำหรับแอปชุดนี้")
        case .unrecognized(let raw):
            return Phrase(
                en: "Unrecognised status \(raw)",
                th: "สถานะที่ไม่รู้จัก \(raw)"
            )
        }
    }

    /// A glyph, so the status never depends on colour alone.
    var glyph: String {
        switch self {
        case .enabled: return "checkmark.circle.fill"
        case .notRegistered: return "circle"
        case .requiresApproval: return "exclamationmark.circle.fill"
        case .notFound: return "questionmark.circle"
        case .unrecognized: return "questionmark.circle"
        }
    }

    /// True when the only way forward is through System Settings.
    var needsSystemSettings: Bool { self == .requiresApproval }
}

// MARK: - Outcome

/// The result of trying to change the setting: the status read back from the
/// system afterwards, plus a plain-language reason when the system did not end
/// up where the user asked.
struct LaunchAtLoginOutcome: Equatable, Sendable {
    let state: LaunchAtLoginState
    /// nil when the system agreed. Never a generic "something went wrong".
    let failure: Phrase?

}

// MARK: - Service

/// A thin wrapper over `SMAppService.mainApp`.
///
/// The four operations are stored as closures so a caller can construct a
/// `Preferences` without registering a real login item on the machine running
/// the code. `.system` is the only implementation that talks to macOS.
@MainActor
struct LaunchAtLoginService {
    var readState: () -> LaunchAtLoginState
    var register: () throws -> Void
    var unregister: () throws -> Void
    var openSystemSettings: () -> Void

    static let system = LaunchAtLoginService(
        readState: { LaunchAtLoginState(SMAppService.mainApp.status) },
        register: { try SMAppService.mainApp.register() },
        unregister: { try SMAppService.mainApp.unregister() },
        openSystemSettings: { SMAppService.openSystemSettingsLoginItems() }
    )

    /// Asks macOS for the change, then asks macOS what actually happened.
    ///
    /// The returned state is always the freshly read one, so a caller that
    /// binds a toggle to it cannot show a value the system does not hold.
    func apply(enabled: Bool) -> LaunchAtLoginOutcome {
        var thrown: Phrase?
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            thrown = Self.explain(error, enabling: enabled)
        }

        let state = readState()
        if thrown == nil, state.isEnabled == enabled {
            return LaunchAtLoginOutcome(state: state, failure: nil)
        }
        return LaunchAtLoginOutcome(
            state: state,
            failure: thrown ?? Self.disagreement(state: state, enabling: enabled)
        )
    }

    /// A fresh read with no side effect. Used on appearance, and after the user
    /// has been sent to System Settings.
    func currentOutcome() -> LaunchAtLoginOutcome {
        LaunchAtLoginOutcome(state: readState(), failure: nil)
    }

    // MARK: Explanations

    /// Turns a thrown error into a sentence. The numeric code is kept because
    /// it is the only thing that distinguishes one refusal from another, but it
    /// is never the whole message.
    private static func explain(_ error: Error, enabling: Bool) -> Phrase {
        let ns = error as NSError
        if ns.domain == NSOSStatusErrorDomain, ns.code == 1 {
            return enabling
                ? Phrase(
                    en: """
                    macOS would not add the login item. This copy of Claudence runs \
                    from the build directory and is signed with a local development \
                    certificate, which macOS is allowed to refuse. Moving Claudence to \
                    the Applications folder is the usual fix. (code 1)
                    """,
                    th: """
                    macOS ไม่ยอมเพิ่ม login item แอปชุดนี้รันจาก build directory และเซ็นด้วย \
                    certificate สำหรับพัฒนาในเครื่อง ซึ่ง macOS มีสิทธิ์ปฏิเสธ วิธีแก้ที่ใช้ได้ทั่วไปคือ \
                    ย้าย Claudence ไปไว้ในโฟลเดอร์ Applications (code 1)
                    """
                )
                : Phrase(
                    en: """
                    macOS would not remove the login item. This copy of Claudence runs \
                    from the build directory and is signed with a local development \
                    certificate, which macOS is allowed to refuse. Moving Claudence to \
                    the Applications folder is the usual fix. (code 1)
                    """,
                    th: """
                    macOS ไม่ยอมลบ login item แอปชุดนี้รันจาก build directory และเซ็นด้วย \
                    certificate สำหรับพัฒนาในเครื่อง ซึ่ง macOS มีสิทธิ์ปฏิเสธ วิธีแก้ที่ใช้ได้ทั่วไปคือ \
                    ย้าย Claudence ไปไว้ในโฟลเดอร์ Applications (code 1)
                    """
                )
        }
        let detail = "(\(ns.domain) \(ns.code)): \(ns.localizedDescription)"
        return enabling
            ? Phrase(en: "macOS would not add the login item \(detail)", th: "macOS ไม่ยอมเพิ่ม login item \(detail)")
            : Phrase(en: "macOS would not remove the login item \(detail)", th: "macOS ไม่ยอมลบ login item \(detail)")
    }

    /// Nothing was thrown, yet the system is not where the user asked it to be.
    /// This is the case the toggle exists to make visible.
    private static func disagreement(state: LaunchAtLoginState, enabling: Bool) -> Phrase {
        guard enabling else {
            return Phrase(
                en: """
                macOS still lists Claudence as a login item. Open Login Items in \
                System Settings and remove it there.
                """,
                th: """
                macOS ยังคงแสดง Claudence เป็น login item อยู่ เปิด Login Items ใน \
                System Settings แล้วลบออกจากที่นั่น
                """
            )
        }
        switch state {
        case .requiresApproval:
            return Phrase(
                en: """
                macOS added the login item but is holding it off until you allow it. \
                Open Login Items in System Settings and switch Claudence on.
                """,
                th: """
                macOS เพิ่ม login item แล้วแต่ยังไม่เปิดใช้จนกว่าคุณจะอนุญาต เปิด Login Items ใน \
                System Settings แล้วเปิดใช้งาน Claudence
                """
            )
        case .notFound:
            return Phrase(
                en: """
                macOS reports no login item for this copy of Claudence. That is the \
                usual answer for an app running from the build directory rather than \
                the Applications folder. Move Claudence to Applications and try again.
                """,
                th: """
                macOS รายงานว่าไม่มี login item สำหรับแอปชุดนี้ ซึ่งเป็นคำตอบปกติสำหรับแอปที่รันจาก \
                build directory แทนที่จะเป็นโฟลเดอร์ Applications ลองย้าย Claudence ไปไว้ใน \
                Applications แล้วลองใหม่
                """
            )
        case .notRegistered:
            return Phrase(
                en: "macOS did not register the login item, and did not say why.",
                th: "macOS ไม่ได้ลงทะเบียน login item และไม่ได้ระบุเหตุผล"
            )
        case .unrecognized(let raw):
            return Phrase(
                en: "macOS reported status \(raw), which this version does not recognise.",
                th: "macOS รายงานสถานะ \(raw) ซึ่งแอปเวอร์ชันนี้ไม่รู้จัก"
            )
        case .enabled:
            return Phrase(en: "macOS registered the login item.", th: "macOS ลงทะเบียน login item แล้ว")
        }
    }
}
