import Foundation
import UserNotifications
import os
import ClaudenceCore

/// The only place in Claudence that touches `UserNotifications`.
///
/// Everything that decides *whether* to notify lives in `ClaudenceCore`
/// (`EventDeriver`, `NotificationThrottle`) and is covered by tests that never
/// import this framework. This type does three things and nothing else: it
/// holds the baseline snapshot, it asks for authorization once, and it renders
/// an admitted event into a banner.
///
/// Failure is ordinary here, by design:
///
/// - The user declining notifications is a permanent, silently accepted state.
///   Nothing is retried, nothing is re-asked, no error reaches the UI, and the
///   rest of the application behaves exactly as it did before.
/// - `Claudence.app` is signed with a local self-signed identity. Local
///   notification delivery from a locally signed bundle can be refused by the
///   system for reasons that have nothing to do with this code. Every such
///   failure is logged and dropped.
/// - Running the executable outside its bundle leaves `bundleIdentifier` nil,
///   and `UNUserNotificationCenter.current()` traps in that case. The center is
///   therefore optional and the whole bridge degrades to a no-op rather than
///   crashing a debug run.
///
/// Thread safe. `MonitorEngine` publishes from inside its actor, so `handle`
/// can arrive on any thread.
final class NotificationBridge: @unchecked Sendable {

    // MARK: - Dependencies

    private let throttle: NotificationThrottle
    private let center: UNUserNotificationCenter?
    private let authorizer: Authorizer
    private let log: Logger

    private let lock = NSLock()
    private var deriver: EventDeriver
    private var lastSnapshot: MonitorSnapshot?
    private var enabled: Bool
    private var observerToken: UUID?

    init(
        deriver: EventDeriver = EventDeriver(),
        throttle: NotificationThrottle = NotificationThrottle(),
        isEnabled: Bool = true
    ) {
        self.deriver = deriver
        self.throttle = throttle
        self.enabled = isEnabled
        self.center = Self.makeCenter()
        let subsystem = Bundle.main.bundleIdentifier ?? "com.tungao.claudence"
        self.log = Logger(subsystem: subsystem, category: "notifications")
        self.authorizer = Authorizer(center: center, log: log)
    }

    /// `UNUserNotificationCenter.current()` requires a bundle. Outside one it
    /// traps rather than returning nil, so the check has to happen first.
    private static func makeCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    // MARK: - Settings switch

    /// Owned by Settings. Turning it off stops delivery immediately but keeps
    /// the baseline snapshot moving, so turning it back on resumes from the
    /// present rather than replaying a backlog of everything that was missed.
    var isEnabled: Bool {
        get { withLock { enabled } }
        set { withLock { enabled = newValue } }
    }

    /// `NSLock.lock()` is unavailable from an async context, so every critical
    /// section goes through this synchronous helper instead.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Entry points

    /// Attach to the engine. The composition root calls this once.
    ///
    /// `MonitorEngine.observe` replays the current snapshot to a new observer;
    /// that first delivery only establishes the baseline, because a diff needs
    /// two snapshots and the app has no business announcing history at launch.
    func start(observing engine: MonitorEngine) async {
        guard withLock({ observerToken == nil }) else { return }

        installPresentationDelegate()

        let token = await engine.observe { [weak self] snapshot in
            self?.handle(snapshot)
        }

        withLock { observerToken = token }
    }

    func stop(observing engine: MonitorEngine) async {
        let token = withLock { () -> UUID? in
            let existing = observerToken
            observerToken = nil
            return existing
        }
        guard let token else { return }
        await engine.removeObserver(token)
    }

    /// Callback entry point, for a caller that already has a snapshot stream.
    /// Cheap and synchronous: the diff is a value computation and delivery is
    /// handed to a detached task.
    func handle(_ snapshot: MonitorSnapshot) {
        let events = withLock { () -> [NotificationEvent] in
            let previous = lastSnapshot
            lastSnapshot = snapshot
            guard let previous else { return [] }
            let derived = deriver.events(from: previous, to: snapshot)
            // Disabled: the deriver still advances, so its dedup memory and
            // armed flags stay in step with reality; the result is discarded.
            return enabled ? derived : []
        }

        guard !events.isEmpty else { return }
        let admitted = throttle.admit(events)
        guard !admitted.isEmpty else { return }

        Task { [weak self] in
            await self?.deliver(admitted, at: snapshot.updatedAt)
        }
    }

    // MARK: - Delivery

    private func deliver(_ events: [NotificationEvent], at now: Date) async {
        guard let center else {
            log.debug("No notification center: running outside a bundle. \(events.count) event(s) dropped.")
            return
        }
        guard await authorizer.isAuthorized() else { return }

        for event in events {
            let request = UNNotificationRequest(
                // Keying the request on the event identity means a repeat
                // replaces the earlier banner instead of stacking a second one.
                identifier: event.throttleKey,
                content: Self.content(for: event, now: now),
                trigger: nil
            )
            do {
                try await center.add(request)
            } catch {
                // A locally signed bundle can be refused delivery for reasons
                // outside this code. Log it; never surface it.
                log.error("Notification not scheduled: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Wording comes from `NotificationEvent`, which follows spec section 10.
    static func content(for event: NotificationEvent, now: Date = Date()) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body(now: now)
        // Groups the two kinds separately in Notification Center.
        content.threadIdentifier = event.kind.rawValue

        switch event.kind {
        case .usageThreshold:
            // Time critical in the ordinary sense: the budget is about to run
            // out and the user may want to change what they are doing.
            content.sound = .default
            content.interruptionLevel = .timeSensitive
        case .sessionCompleted:
            // Informational, and the same fact is already on the popover.
            // A chime for every finished session is exactly the spam that gets
            // a monitoring tool uninstalled.
            content.sound = nil
            content.interruptionLevel = .passive
        }
        return content
    }

    /// Without a delegate, macOS suppresses a banner while the app is
    /// frontmost. Claudence is an accessory app, but its popover can hold focus,
    /// and a notification that silently does not appear is worse than none.
    private func installPresentationDelegate() {
        guard let center else { return }
        center.delegate = Self.presenter
    }

    private static let presenter = ForegroundPresenter()
}

// MARK: - Authorization

/// Asks once, remembers the answer, and never asks again.
private actor Authorizer {
    private let center: UNUserNotificationCenter?
    private let log: Logger
    private var decision: Bool?
    private var isAsking = false

    init(center: UNUserNotificationCenter?, log: Logger) {
        self.center = center
        self.log = log
    }

    func isAuthorized() async -> Bool {
        if let decision { return decision }

        guard let center else {
            decision = false
            return false
        }

        // A prompt is already on screen. The event that got here second is
        // dropped rather than queued: the user has not answered yet, and
        // stacking a second request would put up a second prompt.
        guard !isAsking else { return false }
        isAsking = true
        defer { isAsking = false }

        var granted = false
        do {
            // Sound is requested alongside alert so the usage warning can
            // chime; session completions opt out per notification.
            granted = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            // Refusal by the system rather than by the user: a locally signed
            // bundle, a managed device, a malformed bundle. Same handling.
            log.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            granted = false
        }

        decision = granted
        if !granted {
            // An ordinary state, not an error. Recorded once so the reason for
            // silence is discoverable, then never mentioned again. Nothing is
            // retried and nothing reaches the UI.
            log.info("Notifications not authorized. Claudence will not notify; everything else is unaffected.")
        }
        return granted
    }
}

// MARK: - Foreground presentation

private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
