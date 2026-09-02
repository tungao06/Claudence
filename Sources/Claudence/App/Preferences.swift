import Foundation
import Observation

// MARK: - Menu bar style

/// What the menu bar shows next to its status dot.
///
/// The menu bar is shared, narrow real estate (`Theme.Layout.menuBarMaxWidth`),
/// so the choice is between three short readings, not a layout editor.
enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    /// The status dot alone.
    case minimal
    /// The dot plus the percentage of the current usage window consumed.
    case usage
    /// The dot plus the number of active sessions.
    case sessions

    var id: String { rawValue }

    /// Picker label.
    var title: String {
        switch self {
        case .minimal: return "Dot only"
        case .usage: return "Usage"
        case .sessions: return "Sessions"
        }
    }

    /// One line saying what will appear. No sample number: the real reading is
    /// whatever the data says, and this file does not invent one.
    var explanation: String {
        switch self {
        case .minimal: return "The status dot on its own, and nothing else."
        case .usage: return "The status dot and the percentage of your usage window consumed."
        case .sessions: return "The status dot and the number of sessions running now."
        }
    }
}

// MARK: - Preferences

/// Every user-facing setting, backed by `UserDefaults`.
///
/// Deliberately small. There is no refresh-interval setting: the application is
/// driven by filesystem events and never polls, so an interval control would be
/// a dial wired to nothing.
///
/// `launchAtLogin` is the one preference that is not stored here. macOS owns it,
/// registration is allowed to fail, and the user can change it in System
/// Settings behind the app's back. Mirroring it into `UserDefaults` would let
/// the interface disagree with the system, so the getter reads the real
/// `SMAppService` status instead.
///
/// ## Menu bar contract
///
/// The two menu bar preferences compose, and every combination is a distinct,
/// visible outcome:
///
/// ```
/// showMenuBarUsage == false   the app glyph only: no live reading, no colour
/// true  + .minimal            the live severity dot, no text
/// true  + .usage              the dot and the percentage consumed
/// true  + .sessions           the dot and the active session count
/// ```
///
/// `showMenuBarUsage` is the quiet switch: turn it off and nothing about your
/// usage is legible over your shoulder. `menuBarStyle` chooses the reading when
/// it is on, and is kept while the switch is off so turning it back on restores
/// the choice.
@MainActor
@Observable
final class Preferences {

    // MARK: Keys

    private enum Key {
        static let showMenuBarUsage = "com.tungao.claudence.preference.showMenuBarUsage"
        static let menuBarStyle = "com.tungao.claudence.preference.menuBarStyle"
        static let notificationsEnabled = "com.tungao.claudence.preference.notificationsEnabled"
    }

    // MARK: Dependencies

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let launch: LaunchAtLoginService

    // MARK: Stored preferences

    /// Whether the menu bar carries a live reading at all. Default on.
    var showMenuBarUsage: Bool {
        didSet { defaults.set(showMenuBarUsage, forKey: Key.showMenuBarUsage) }
    }

    /// Which reading the menu bar carries. Default `.usage`.
    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle) }
    }

    /// Whether Claudence posts notifications. Default on. The system permission
    /// is a separate question, owned by the notification code.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// What the menu bar should actually render, once the switch is applied.
    var effectiveMenuBarStyle: MenuBarStyle {
        showMenuBarUsage ? menuBarStyle : .minimal
    }

    // MARK: Launch at login

    /// The status macOS reports, refreshed after every attempt. Observed, so a
    /// view bound to it redraws when the real status changes.
    private(set) var launchAtLoginState: LaunchAtLoginState

    /// Why the last attempt did not do what the user asked, in plain words.
    /// nil when the last attempt agreed with the system.
    private(set) var launchAtLoginFailure: String?

    /// Reads the real service status. Setting it asks macOS, then reads back.
    var launchAtLogin: Bool {
        get { launchAtLoginState.isEnabled }
        set { setLaunchAtLogin(newValue) }
    }

    // MARK: Init

    init(
        defaults: UserDefaults = .standard,
        launchAtLogin: LaunchAtLoginService = .system
    ) {
        // Registered defaults are what `bool(forKey:)` returns when the key has
        // never been written, so every preference has one definition of its
        // default and survives a relaunch unchanged.
        defaults.register(defaults: [
            Key.showMenuBarUsage: true,
            Key.menuBarStyle: MenuBarStyle.usage.rawValue,
            Key.notificationsEnabled: true,
        ])

        self.defaults = defaults
        self.launch = launchAtLogin
        self.showMenuBarUsage = defaults.bool(forKey: Key.showMenuBarUsage)
        self.menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle) ?? "")
            ?? .usage
        self.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        self.launchAtLoginState = launchAtLogin.readState()
        self.launchAtLoginFailure = nil
    }

    // MARK: Actions

    /// Asks macOS for the change and adopts whatever macOS reports afterwards.
    /// A refused registration leaves the toggle off with a reason attached.
    func setLaunchAtLogin(_ enabled: Bool) {
        let outcome = launch.apply(enabled: enabled)
        launchAtLoginState = outcome.state
        launchAtLoginFailure = outcome.failure
    }

    /// Re-reads the status without changing anything. Called when the settings
    /// window appears and after the user visits System Settings, because the
    /// login item can be switched off there at any time.
    func refreshLaunchAtLoginStatus() {
        let outcome = launch.currentOutcome()
        launchAtLoginState = outcome.state
        // A plain re-read cannot fail, so a stale reason is cleared here rather
        // than left to contradict a status the user has since fixed.
        if launchAtLoginState.isEnabled { launchAtLoginFailure = nil }
    }

    /// Opens the Login Items pane. The only route out of `.requiresApproval`.
    func openLoginItemsSettings() {
        launch.openSystemSettings()
    }
}
