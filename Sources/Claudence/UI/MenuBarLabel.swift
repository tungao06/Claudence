import SwiftUI
import ClaudenceCore

/// Menu bar rendering. Width is a hard constraint: the menu bar is shared and
/// narrow on a single display. Text never carries meaning by color alone, so
/// the glyph is paired with a number or a word. See spec section 7.1.
struct MenuBarLabel: View {
    let model: MonitorViewModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: glyphName)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(glyphColor)
            Text(model.menuBarText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
        }
        .frame(maxWidth: Constants.Performance.maxMenuBarWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
    }

    /// A filled dot for a measured value, a hollow one when usage is unknown.
    /// The shape alone distinguishes the two states for anyone who cannot rely
    /// on color.
    private var glyphName: String {
        model.primaryWindow?.usedPercent == nil ? "circle" : "circle.fill"
    }

    private var glyphColor: Color {
        guard let severity = model.menuBarSeverity else { return Theme.textSecondary }
        return Theme.color(for: severity)
    }
}
