import SwiftUI
import ClaudenceCore

/// Menu bar rendering. Width is a hard constraint: the menu bar is shared and
/// narrow on a single display. See spec section 7.1.
struct MenuBarLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
            Text("Claude")
                .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: Constants.Performance.maxMenuBarWidth)
        .accessibilityLabel("Claudence, idle")
    }
}
