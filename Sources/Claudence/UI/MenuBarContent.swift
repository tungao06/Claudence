import SwiftUI
import ClaudenceCore

struct MenuBarContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CLAUDENCE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Divider()

            Text("Monitoring not yet wired up")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Divider()

            Button("Quit Claudence") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 300)
    }
}
