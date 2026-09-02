import AppKit
import Foundation

/// Refuses to start a second copy of Claudence.
///
/// macOS already prevents launching one *bundle* twice, which is why this never
/// came up while there was a single copy in the repository. It stops helping the
/// moment a second bundle exists: an installed `/Applications/Claudence.app` and
/// a freshly built `./Claudence.app` are different bundles as far as
/// LaunchServices is concerned, so both start, both watch the same transcripts,
/// both write the same SQLite file, and two ring marks appear in the menu bar.
///
/// The check is by bundle identifier rather than by path, which is exactly the
/// case macOS does not cover.
///
/// ## Which copy survives
///
/// The newcomer yields, and "already registered with LaunchServices" is what
/// identifies the newcomer. A process appears in that list once it has become
/// an application, which happens inside `NSApplication`; this check runs before
/// `ClaudenceApp.main()`, so anything already listed is by construction ahead of
/// this process. The copy holding the store and the Keychain grant is therefore
/// never the one thrown away, and no clock comparison is needed to decide it.
///
/// Two launches close enough together that neither has registered yet will both
/// survive. That window is milliseconds wide and needs a deliberate race to hit;
/// the case this guards is an installed copy that has been running for hours.
///
/// ## Do not use `NSRunningApplication.current` here
///
/// It reports `processIdentifier` -1 for a process that was executed directly
/// rather than launched through LaunchServices, which is exactly how a
/// developer starts the binary. An earlier version filtered on that value, so
/// the guard silently never fired from the terminal while appearing to work
/// under `open` -- where LaunchServices had refused the second launch on its
/// own and the guard was never what stopped it. The process identifier comes
/// from `ProcessInfo`, which is correct in both cases.
///
/// ## When it does nothing
///
/// Running the executable straight out of `.build` leaves `bundleIdentifier`
/// nil, there is nothing to compare, and the guard stands aside. That is the
/// developer's case and blocking it would be surprising; the same nil is already
/// handled deliberately in `NotificationBridge`.
enum SingleInstance {
    /// An already-running Claudence that this process should defer to, or nil if
    /// this process is the one that should keep going.
    static func alreadyRunning() -> NSRunningApplication? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }

        let mine = ProcessInfo.processInfo.processIdentifier

        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first { $0.processIdentifier != mine && !$0.isTerminated }
    }
}
