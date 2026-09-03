import Foundation
import Observation

// MARK: - Menu bar style

/// What the menu bar shows next to its status dot.
///
/// The menu bar is shared, narrow real estate (`Theme.Layout.menuBarMaxWidth`,
/// 60 pt), so the choice is between four short readings, not a layout editor.
/// `MenuBarLabel` owns the measurement that decides whether a reading fits; this
/// enum only names the choices.
enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    /// The status dot alone.
    case minimal
    /// The dot plus the percentage of the current usage window consumed.
    case usage
    /// The dot plus the number of active sessions.
    case sessions
    /// The dot plus both: the session count and the percentage together.
    ///
    /// This is the widest reading and the only one that can run out of room. It
    /// is offered because the count is the thing Claude Code's own status line
    /// cannot show, and a user watching several projects wants it beside the
    /// number that decides when they stop.
    case combined

    var id: String { rawValue }

    /// Picker label. Design section 7 names three of these; `sessions` is the
    /// count-only reading the design does not draw but the app has always had.
    var title: String {
        switch self {
        case .minimal: return "Icon"
        case .usage: return "Icon + %"
        case .sessions: return "Count"
        case .combined: return "Count \u{00B7} %"
        }
    }

    /// One line saying what will appear. No sample number: the real reading is
    /// whatever the data says, and this file does not invent one.
    var explanation: String {
        switch self {
        case .minimal:
            return "The status dot on its own, and nothing else."
        case .usage:
            return "The status dot and the percentage of your usage window consumed."
        case .sessions:
            return "The status dot and the number of sessions running now."
        case .combined:
            return """
            The status dot, the session count and the percentage together. \
            The widest readings shrink a little so the label never exceeds 60 pt.
            """
        }
    }
}

// MARK: - Appearance

/// Which palette the windows use.
///
/// This type stores the choice and nothing else. Applying it belongs to whoever
/// owns the windows, because a settings view that reached for `NSApp.appearance`
/// would be a leaf of the tree reconfiguring the whole application.
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    /// Follow the system setting, and keep following it when it changes.
    case auto
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var explanation: String {
        switch self {
        case .auto: return "Follow the system setting, including when it switches at sunset."
        case .light: return "Always the light palette, whatever the system is set to."
        case .dark: return "Always the dark palette, whatever the system is set to."
        }
    }
}

// MARK: - Usage refresh interval

/// How often the usage endpoint is asked how much of the limit is left.
///
/// This paces one network call and nothing else. See the note on `Preferences`
/// for why an interval control exists here at all when the rest of the
/// application is event driven.
enum UsageRefreshInterval: String, CaseIterable, Identifiable, Sendable {
    case thirtySeconds
    case oneMinute
    case fiveMinutes

    var id: String { rawValue }

    /// The value the polling loop sleeps for.
    var seconds: TimeInterval {
        switch self {
        case .thirtySeconds: return 30
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        }
    }

    /// Design section 7 spells these `30s`, `60s`, `5m`.
    var title: String {
        switch self {
        case .thirtySeconds: return "30s"
        case .oneMinute: return "60s"
        case .fiveMinutes: return "5m"
        }
    }
}

// MARK: - Preferences

/// Every user-facing setting, backed by `UserDefaults`.
///
/// ## Why there is a refresh interval, and what it does not touch
///
/// This file used to say there was deliberately no refresh-interval setting,
/// because the application is event driven and never polls. Half of that is
/// still true and worth keeping: session discovery and token counts are driven
/// by FSEvents and offset-based tailing, so an idle machine does no work, and
/// `usageRefreshInterval` does not touch either of them. Turning it to `5m` will
/// not make a session appear five minutes late.
///
/// The other half was wrong. The usage endpoint is not a file and emits no
/// events, so `MonitorViewModel` has always asked it on a timer. That timer was
/// a hard-coded number with no way to change it, which is not the same thing as
/// not polling. `usageRefreshInterval` is that one timer, made visible. It is
/// the only polled source in the application, and this is the only control that
/// paces anything.
///
/// `Preferences` exposes the value; the polling loop reads it. Nothing here
/// starts, stops or reschedules a timer.
///
/// ## Live-only mode
///
/// `liveOnlyMode` is the one preference read before the services are built:
/// `Composition.makeServices()` reads it to decide whether `ClaudenceStore`
/// opens its file or opens in memory, before anything else in the app exists.
/// Every later change to it is applied through `StoreModeController`, never by
/// a view writing this flag directly -- the controller is what reopens the
/// store and, on the way out, removes the file, and a view that only flipped
/// the stored `Bool` would leave the store pointed at whatever it already had
/// open.
///
/// ## Every property here writes on assignment, including in `init`
///
/// `@Observable` turns these stored properties into computed ones, so the
/// assignments in `init` go through the setter and each `didSet` writes to
/// `UserDefaults`. For a value read straight back from the same defaults that
/// is a no-op, which is why it has never mattered. It stops being a no-op when
/// the value came from somewhere else in the domain search order: launching the
/// binary with `-com.tungao.claudence.preference.liveOnlyMode YES`, which
/// `NSArgumentDomain` answers for the life of that process, wrote `true` into
/// the persistent domain on the way past and left the setting on for every
/// launch after it. That is how the mode was verified once, and the persistence
/// was not the intention. Anyone testing a preference from the command line
/// should expect it to stick.
///
/// ## Launch at login
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
/// true  + .combined           the dot, the count and the percentage
/// ```
///
/// `showMenuBarUsage` is the quiet switch: turn it off and nothing about your
/// usage is legible over your shoulder. `menuBarStyle` chooses the reading when
/// it is on, and is kept while the switch is off so turning it back on restores
/// the choice.
///
/// ## Notification switches
///
/// The three `notifyOn...` flags are stored intent, read by the notification
/// bridge rather than by this type. Each names a case `NotificationEvent`
/// actually has and `EventDeriver` actually emits, `notifyOnSessionIdle`
/// included -- it was the odd one out while the event was still missing, and it
/// was kept as a key on the grounds that `SessionStatus.idle` was derivable and
/// only the event was absent. The event landed; nothing here is speculative any
/// more. `permission` and `error` have no source at all, so they have no key
/// here and will not get one until one is proven.
@MainActor
@Observable
final class Preferences {

    // MARK: Keys

    private enum Key {
        static let showMenuBarUsage = "com.tungao.claudence.preference.showMenuBarUsage"
        static let menuBarStyle = "com.tungao.claudence.preference.menuBarStyle"
        static let notificationsEnabled = "com.tungao.claudence.preference.notificationsEnabled"
        static let appearance = "com.tungao.claudence.preference.appearance"
        static let usageRefreshInterval = "com.tungao.claudence.preference.usageRefreshInterval"
        static let showSubagents = "com.tungao.claudence.preference.showSubagents"
        static let compactRows = "com.tungao.claudence.preference.compactRows"
        static let liveIndicators = "com.tungao.claudence.preference.liveIndicators"
        static let notifyOnSessionCompleted = "com.tungao.claudence.preference.notifyOnSessionCompleted"
        static let notifyOnUsageThreshold = "com.tungao.claudence.preference.notifyOnUsageThreshold"
        static let notifyOnSessionIdle = "com.tungao.claudence.preference.notifyOnSessionIdle"
        static let notifyOnSessionNeedsInput = "com.tungao.claudence.preference.notifyOnSessionNeedsInput"
        static let liveOnlyMode = "com.tungao.claudence.preference.liveOnlyMode"
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

    /// Whether Claudence posts notifications at all. Default on. The system
    /// permission is a separate question, owned by the notification code, and
    /// the per-event switches below only matter while this one is on.
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled) }
    }

    /// Which palette the windows use. Default `.auto`.
    var appearance: AppearanceMode {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }

    /// How often the usage endpoint is polled. Default `.oneMinute`, which is
    /// the interval the application already used before it was adjustable.
    var usageRefreshInterval: UsageRefreshInterval {
        didSet { defaults.set(usageRefreshInterval.rawValue, forKey: Key.usageRefreshInterval) }
    }

    /// Whether a session row lists the agents spawned under it. Default on.
    var showSubagents: Bool {
        didSet { defaults.set(showSubagents, forKey: Key.showSubagents) }
    }

    /// Whether a closed session row hides duration, rate and sparkline until it
    /// is opened. Default off: the full row is the design's normal state, and
    /// this is the setting for someone watching many sessions at once.
    var compactRows: Bool {
        didSet { defaults.set(compactRows, forKey: Key.compactRows) }
    }

    /// Whether a working session gets a visible liveness cue. Default on.
    ///
    /// Not a repeating animation, whatever the design's wording suggests: the
    /// cue is a one-shot change when the value moves. System Reduce Motion still
    /// wins over this switch.
    var liveIndicators: Bool {
        didSet { defaults.set(liveIndicators, forKey: Key.liveIndicators) }
    }

    /// Notify when a monitored session is gone and its absence is confirmed.
    /// Default on. Backed by `NotificationEvent.sessionCompleted`.
    var notifyOnSessionCompleted: Bool {
        didSet { defaults.set(notifyOnSessionCompleted, forKey: Key.notifyOnSessionCompleted) }
    }

    /// Notify when a usage window crosses the critical threshold upward.
    /// Default on. Backed by `NotificationEvent.usageThreshold`.
    var notifyOnUsageThreshold: Bool {
        didSet { defaults.set(notifyOnUsageThreshold, forKey: Key.notifyOnUsageThreshold) }
    }

    /// Notify when a session stops working but stays open. Default off, because
    /// a session that pauses while its human reads the diff is the ordinary
    /// case and interrupting them for it would be noise.
    /// On by default, unlike `notifyOnSessionIdle`. A session that has stopped
    /// working is an observation; a session that has asked a question is doing
    /// nothing at all until it is answered, and the whole point of watching
    /// several sessions at once is that the one waiting on you is not the one
    /// you are looking at.
    var notifyOnSessionNeedsInput: Bool {
        didSet { defaults.set(notifyOnSessionNeedsInput, forKey: Key.notifyOnSessionNeedsInput) }
    }

    var notifyOnSessionIdle: Bool {
        didSet { defaults.set(notifyOnSessionIdle, forKey: Key.notifyOnSessionIdle) }
    }

    /// Whether Claudence persists anything of its own to disk. Default off.
    ///
    /// This is only the stored intent. Reading it does not point the store
    /// anywhere -- see the note on live-only mode above. Written here so
    /// `StoreModeController` has somewhere durable to record the choice once
    /// it has actually reopened the store; nothing else should write it.
    var liveOnlyMode: Bool {
        didSet { defaults.set(liveOnlyMode, forKey: Key.liveOnlyMode) }
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
            Key.appearance: AppearanceMode.auto.rawValue,
            Key.usageRefreshInterval: UsageRefreshInterval.oneMinute.rawValue,
            Key.showSubagents: true,
            Key.compactRows: false,
            Key.liveIndicators: true,
            Key.notifyOnSessionCompleted: true,
            Key.notifyOnUsageThreshold: true,
            Key.notifyOnSessionIdle: false,
            Key.notifyOnSessionNeedsInput: true,
            Key.liveOnlyMode: false,
        ])

        self.defaults = defaults
        self.launch = launchAtLogin
        self.showMenuBarUsage = defaults.bool(forKey: Key.showMenuBarUsage)
        self.menuBarStyle = MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle) ?? "")
            ?? .usage
        self.notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        // An unrecognised raw value falls back to the registered default rather
        // than to an arbitrary first case, so a hand-edited plist or a renamed
        // case degrades to the behaviour the app shipped with.
        self.appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "")
            ?? .auto
        self.usageRefreshInterval = UsageRefreshInterval(
            rawValue: defaults.string(forKey: Key.usageRefreshInterval) ?? ""
        ) ?? .oneMinute
        self.showSubagents = defaults.bool(forKey: Key.showSubagents)
        self.compactRows = defaults.bool(forKey: Key.compactRows)
        self.liveIndicators = defaults.bool(forKey: Key.liveIndicators)
        self.notifyOnSessionCompleted = defaults.bool(forKey: Key.notifyOnSessionCompleted)
        self.notifyOnUsageThreshold = defaults.bool(forKey: Key.notifyOnUsageThreshold)
        self.notifyOnSessionIdle = defaults.bool(forKey: Key.notifyOnSessionIdle)
        self.notifyOnSessionNeedsInput = defaults.bool(forKey: Key.notifyOnSessionNeedsInput)
        self.liveOnlyMode = defaults.bool(forKey: Key.liveOnlyMode)
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
