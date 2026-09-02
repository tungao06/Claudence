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

ClaudenceApp.main()
