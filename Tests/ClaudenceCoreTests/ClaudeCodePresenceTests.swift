import Foundation
import Testing

@testable import ClaudenceCore

/// An absent Claude Code and an idle one produced the same display: an empty
/// list and a meter with no reading. One is an ordinary quiet machine and the
/// other is a missing dependency, and a first-time user cannot tell them apart.
@Suite("Claude Code presence")
struct ClaudeCodePresenceTests {

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudenceCodePresence", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func detect(in root: URL) -> ClaudeCodePresence {
        ClaudeCodePresence.detect(
            home: root.appendingPathComponent(".claude", isDirectory: true),
            projects: root.appendingPathComponent(".claude/projects", isDirectory: true),
            sessions: root.appendingPathComponent(".claude/sessions", isDirectory: true)
        )
    }

    @Test("no state directory at all reads as not installed")
    func absent() {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(detect(in: root) == .absent)
        #expect(detect(in: root).isUsable == false)
        #expect(detect(in: root).title != nil)
    }

    @Test("an empty state directory reads as installed but never run")
    func installedButNeverRun() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(detect(in: root) == .installedButNeverRun)
        #expect(detect(in: root).isUsable == false)
    }

    @Test("one project directory is enough to say it has run")
    func present() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/projects/-Users-someone-project", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(detect(in: root) == .present)
        #expect(detect(in: root).isUsable)
        // Nothing to say about a machine that is working.
        #expect(detect(in: root).title == nil)
        #expect(detect(in: root).detail == nil)
    }

    @Test("a live session with no project history still counts as running")
    func sessionsAloneAreEnough() throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent(".claude/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sessions.appendingPathComponent("4242.json"))
        #expect(detect(in: root) == .present)
    }

    @Test("both languages are present for every state that speaks")
    func bothLanguages() {
        for state in [ClaudeCodePresence.absent, .installedButNeverRun] {
            let title = state.title
            let detail = state.detail
            #expect(title?.string(in: .english).isEmpty == false)
            #expect(title?.string(in: .thai).isEmpty == false)
            #expect(detail?.string(in: .english).isEmpty == false)
            #expect(detail?.string(in: .thai).isEmpty == false)
            #expect(title?.en != title?.th)
        }
    }
}
