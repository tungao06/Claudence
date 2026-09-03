import Foundation
import Testing

/// A lint against a string that reaches the screen without passing through
/// `Phrase`.
///
/// ## Why this is a source scan rather than a type
///
/// `Phrase` makes an untranslated string fail to compile *at a call site that
/// takes a `Phrase`*. It cannot stop someone writing `Text("Active sessions")`,
/// because `Text` has taken a `String` since SwiftUI shipped and always will.
/// The type covers the parameters this project controls; this test covers the
/// ones Apple controls, which is where an English literal actually gets in.
///
/// It reads the source of the executable target as text. That is unusual, and
/// it is the only option available: `ClaudenceCoreTests` depends on
/// `ClaudenceCore`, not on `Claudence`, and adding the executable as a test
/// dependency to reach a handful of view types would put every `@MainActor`
/// SwiftUI type into the test target's build for no other benefit. The scan
/// costs nothing and needs no such dependency.
///
/// ## What counts as a violation
///
/// A string literal passed directly as the first argument of a view or a
/// modifier whose argument is spoken or drawn: `Text`, `Button`, `Toggle`,
/// `Picker`, `Label`, `.accessibilityLabel`, `.accessibilityHint`, `.help`,
/// `.navigationTitle`. Anything else -- an SF Symbol name, a `UserDefaults`
/// key, a lookup key, a file path -- is not user-facing and is not scanned.
///
/// A literal that is genuinely identical in both languages still has to say so
/// through `Phrase.untranslated(_:)`, which is a marker rather than a
/// translation. That is deliberate: "it reads the same in Thai" should be a
/// decision somebody wrote down, not the absence of one.
@Suite("Interface literals")
struct InterfaceLiteralTests {

    /// Files exempt from the scan, each with the reason it is exempt. Every
    /// entry here is developer-facing text that no user ever sees.
    ///
    /// This list is meant to stay short. A view file arriving here because
    /// translating it was awkward is the failure this test exists to prevent,
    /// so an addition needs a reason that survives being read aloud.
    static let exempt: [String: String] = [
        // `.previewDisplayName` labels, shown in a preview canvas this project
        // does not even have -- there is no Xcode on this machine.
        "Previews.swift": "preview display names, developer-facing",
        "DashboardPreviews.swift": "preview display names, developer-facing",
        // Writes PNGs to a directory for a human to look at while working on
        // the design. Never built into anything a user runs.
        "RenderShots.swift": "render-shot harness, developer-facing",
    ]

    /// The modifiers and initialisers whose first string argument is spoken or
    /// drawn.
    static let spokenCalls = [
        "Text(",
        "Button(",
        "Toggle(",
        "Picker(",
        "Label(",
        "accessibilityLabel(",
        "accessibilityHint(",
        "accessibilityValue(",
        "help(",
        "navigationTitle(",
    ]

    @Test("no user-facing literal reaches the screen without a Phrase")
    func everySpokenStringIsAPhrase() throws {
        let violations = try Self.scan()
        #expect(
            violations.isEmpty,
            """
            \(violations.count) user-facing string literal(s) are not Phrases. \
            Each one renders English on a Thai screen:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    /// The scan has to actually be looking at something. A wrong path, a moved
    /// directory or a renamed target would otherwise make the test above pass
    /// by reading nothing at all, which is the failure mode a source-text lint
    /// is most prone to.
    @Test("the scan reads the interface it claims to")
    func theScanSeesRealFiles() throws {
        let files = try Self.interfaceFiles()
        #expect(files.count > 30)
        #expect(files.contains { $0.lastPathComponent == "MenuBarContent.swift" })
        #expect(files.contains { $0.lastPathComponent == "DashboardView.swift" })
        #expect(files.contains { $0.lastPathComponent == "SettingsView.swift" })
    }

    // MARK: - The scan

    /// `Sources/Claudence`, found relative to this file rather than to the
    /// working directory, which `swift test` does not promise.
    static var interfaceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ClaudenceCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("Sources/Claudence")
    }

    static func interfaceFiles() throws -> [URL] {
        let root = interfaceRoot
        guard
            let walker = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
        else {
            throw ScanFailure.rootUnreadable(root.path)
        }
        return walker
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    static func scan() throws -> [String] {
        var violations: [String] = []
        for file in try interfaceFiles() {
            let name = file.lastPathComponent
            if exempt[name] != nil { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in source.components(separatedBy: .newlines).enumerated() {
                if let call = offendingCall(in: line) {
                    violations.append("\(name):\(index + 1): \(call) \(line.trimmed)")
                }
            }
        }
        return violations
    }

    /// Whether this line hands a raw literal to one of the spoken calls.
    ///
    /// Deliberately syntactic and deliberately shallow: it looks for the call
    /// followed immediately by a quote. That misses a literal split across two
    /// lines and it misses one passed through a `let` first, and both of those
    /// are acceptable. The purpose is to catch the ordinary case -- somebody
    /// types `Text("Sessions")` while adding a row -- at the moment it is
    /// typed, not to be a parser.
    static func offendingCall(in line: String) -> String? {
        let code = line.strippingComment
        guard !code.isEmpty else { return nil }
        for call in spokenCalls where code.contains(call + "\"") {
            return call.dropLast() + "(\"…\")"
        }
        return nil
    }

    enum ScanFailure: Error {
        case rootUnreadable(String)
    }
}

// MARK: - Line handling

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespaces)
    }

    /// The code half of a line, so a `Text("…")` written inside a doc comment
    /// -- which several of this project's files do, explaining exactly this
    /// rule -- is not reported as a violation of it.
    ///
    /// Only leading `//` is honoured. A `//` inside a string literal would
    /// truncate the line early and hide a violation after it, so the check
    /// stops at the first quote instead of scanning the whole line for a
    /// comment marker.
    fileprivate var strippingComment: String {
        let body = trimmed
        if body.hasPrefix("//") || body.hasPrefix("///") || body.hasPrefix("*") {
            return ""
        }
        return body
    }
}
