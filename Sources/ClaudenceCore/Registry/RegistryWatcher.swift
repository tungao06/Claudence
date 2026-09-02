import CoreServices
import Foundation

/// Watches the session registry directory with FSEvents and fires a debounced
/// callback when anything under it changes. Never polls. See spec section 2.1.
///
/// Claude Code writes several files per session transition, so a single user
/// action produces a burst of events. They collapse into one callback after
/// `Constants.Watch.debounce`.
///
/// The directory may not exist yet (Claude Code never run). FSEvents cannot
/// watch a path that does not exist, so the watcher walks up to the nearest
/// existing ancestor and watches that instead: FSEvents is recursive, so the
/// directory's later creation arrives as an event and the caller rescans. If no
/// ancestor exists at all, `start` is a no-op that reports failure rather than
/// crashing.
public final class RegistryWatcher: @unchecked Sendable {

    /// The directory the caller asked for.
    public let directory: URL
    /// The debounce interval applied to event bursts.
    public let debounce: Duration

    private let queue: DispatchQueue
    private let lock = NSLock()

    // All guarded by `lock`.
    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?
    private var handler: (@Sendable () async -> Void)?
    private var retainedSelf: Unmanaged<RegistryWatcher>?
    private var watchedPath: String?

    public init(
        directory: URL = Constants.sessionsDirectory,
        debounce: Duration = Constants.Watch.debounce
    ) {
        self.directory = directory
        self.debounce = debounce
        self.queue = DispatchQueue(
            label: "com.claudence.registry-watcher",
            qos: .utility
        )
    }

    deinit {
        stop()
    }

    // MARK: - State

    public var isWatching: Bool {
        lock.lock(); defer { lock.unlock() }
        return stream != nil
    }

    /// The path FSEvents is actually watching. Equals `directory.path` normally,
    /// or an ancestor when the sessions directory does not exist yet.
    public var effectiveWatchedPath: String? {
        lock.lock(); defer { lock.unlock() }
        return watchedPath
    }

    // MARK: - Lifecycle

    /// Begins watching. Returns `false` when no watchable ancestor exists, in
    /// which case the watcher degrades to producing no events. Calling `start`
    /// on an already-running watcher restarts it with the new handler.
    @discardableResult
    public func start(onChange: @escaping @Sendable () async -> Void) -> Bool {
        stop()

        guard let path = Self.nearestExistingDirectory(from: directory) else {
            return false
        }

        lock.lock()
        handler = onChange
        watchedPath = path
        let retained = Unmanaged.passRetained(self)
        retainedSelf = retained

        var context = FSEventStreamContext(
            version: 0,
            info: retained.toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        // FSEvents has its own coalescing latency; keep it small and let the
        // debounce below own the collapsing so the interval is one constant.
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<RegistryWatcher>
                    .fromOpaque(info)
                    .takeUnretainedValue()
                EngineCounters.shared.countFSEventCallback()
                watcher.scheduleDebouncedCallback()
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,
            flags
        )

        guard let created else {
            handler = nil
            watchedPath = nil
            retainedSelf = nil
            lock.unlock()
            retained.release()
            return false
        }

        stream = created
        lock.unlock()

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            stop()
            return false
        }
        return true
    }

    /// Stops watching and drops the handler. Safe to call repeatedly and from
    /// `deinit`.
    public func stop() {
        lock.lock()
        let existing = stream
        let pending = pendingWork
        let retained = retainedSelf
        stream = nil
        pendingWork = nil
        handler = nil
        watchedPath = nil
        retainedSelf = nil
        lock.unlock()

        pending?.cancel()

        if let existing {
            FSEventStreamStop(existing)
            FSEventStreamInvalidate(existing)
            FSEventStreamRelease(existing)
        }
        retained?.release()
    }

    // MARK: - Debounce

    private func scheduleDebouncedCallback() {
        let seconds = Self.seconds(from: debounce)

        lock.lock()
        pendingWork?.cancel()
        guard handler != nil else {
            lock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let callback = self.handler
            self.pendingWork = nil
            self.lock.unlock()
            guard let callback else { return }
            EngineCounters.shared.countDebouncedRefresh()
            Task { await callback() }
        }
        pendingWork = work
        lock.unlock()

        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // MARK: - Helpers

    static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    /// Walks up from `url` to the first existing directory. `nil` when even the
    /// filesystem root is unreachable, which should not happen in practice.
    static func nearestExistingDirectory(from url: URL) -> String? {
        let fm = FileManager.default
        var candidate = url.standardizedFileURL
        var guardCount = 0
        while guardCount < 64 {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate.path
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            if parent.path == candidate.path { return nil }
            candidate = parent
            guardCount += 1
        }
        return nil
    }
}
