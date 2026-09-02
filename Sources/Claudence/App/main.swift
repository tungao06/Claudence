import AppKit
import Foundation
import ClaudenceCore

// Explicit entry point rather than @main, so a diagnostic run can finish and
// exit without ever starting the menu bar UI.
if CommandLine.arguments.contains("--diagnose") {
    if CommandLine.arguments.contains("--raw-usage") {
        DiagnoseRawUsage.run()
    } else {
        Diagnose.run()
    }
    exit(0)
}

// Offscreen render of the same views, for looking at a layout without driving
// the live application by hand. Also exits before the menu bar UI starts.
if let index = CommandLine.arguments.firstIndex(of: "--render-ui") {
    let directory = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1]
        : FileManager.default.currentDirectoryPath
    MainActor.assumeIsolated { RenderShots.run(directory: directory) }
    exit(0)
}

// One Claudence at a time. Two bundles with the same identifier -- an
// installed copy and a freshly built one -- both start under macOS's own rules,
// and then two of everything runs against one SQLite file. The older process
// wins; see SingleInstance for why the newcomer is the one that yields.
if let existing = SingleInstance.alreadyRunning() {
    let message = """
        Claudence is already running (pid \(existing.processIdentifier)\
        \(existing.bundleURL.map { " from \($0.path)" } ?? "")).
        This copy will not start. Quit the running one first if you meant to \
        replace it.

        """
    FileHandle.standardError.write(Data(message.utf8))
    exit(0)
}

ClaudenceApp.main()
