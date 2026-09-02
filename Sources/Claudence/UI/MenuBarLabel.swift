import SwiftUI
import ClaudenceCore

/// Menu bar rendering. Width is a hard constraint: the menu bar is shared and
/// narrow on a single display, and `Constants.Performance.maxMenuBarWidth` (60
/// pt) is a real requirement, not a suggestion. See spec section 7.1 and design
/// section 5.1.
///
/// Meaning is never carried by colour alone. Two redundant cues do that work and
/// both survive every style:
///
/// - the glyph is filled for a measured value and hollow for an unknown one, so
///   "usage unavailable" is legible without reading a number or seeing a hue;
/// - the reading itself is a number or a word, and the accessibility label spells
///   out the percentage and the session count in full regardless of which style
///   is showing.
///
/// ## Fitting `combined` into 60 pt
///
/// Measured with `NSString.size(withAttributes:)` at the sizes below (system
/// font, medium weight, monospaced digits; an 8 pt `circle.fill` measures 10 pt
/// wide, plus 3 pt of spacing):
///
/// ```
/// "100%"      12 pt   47.8 pt total   widest .usage reading
/// "12"        12 pt   28.5 pt total   widest plausible .sessions reading
/// "2\u{00B7}24%"     12 pt   51.6 pt total   an ordinary .combined reading
/// "12\u{00B7}100%"   12 pt   67.1 pt total   widest plausible .combined reading, over budget
/// "12\u{00B7}100%"   10 pt   57.9 pt total   the same reading, inside budget
/// ```
///
/// So the count and the percentage together do **not** fit at the shared 12 pt
/// once the count reaches two digits and the window is near full. Two ways out
/// were available: shrink the whole style to 10 pt, which makes every everyday
/// reading harder to read to buy headroom for a rare one; or let the label shrink
/// only when it has to. The second is what ships. `minimumScaleFactor(0.8)`
/// allows 9.6 pt, which is past the 10 pt the widest reading needs, so
/// "2\u{00B7}24%" renders at full size and "12\u{00B7}100%" tightens instead of
/// truncating. Truncation was never an option: a clipped percentage is a wrong
/// number, and this project treats a wrong number as a defect.
///
/// The separator is a tight middle dot rather than the design's spaced
/// `2 \u{00B7} 24%`. The two spaces cost 6.5 pt, which is the difference between
/// the common case rendering at full size and rendering shrunk.
struct MenuBarLabel: View {
    let model: MonitorViewModel

    /// Optional so `ClaudenceApp` compiles whether or not it has been wired yet.
    /// Absent, the label renders `.usage`, which is what it has always rendered.
    var preferences: Preferences?

    var body: some View {
        HStack(spacing: Theme.MenuBar.glyphGap) {
            Image(systemName: glyphName)
                .font(.system(size: Theme.MenuBar.glyphSize, weight: .semibold))
                .foregroundStyle(glyphColor)
            if let reading {
                Text(reading)
                    .font(.system(size: Theme.MenuBar.textSize, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(Theme.MenuBar.minimumScaleFactor)
            }
        }
        .frame(maxWidth: Constants.Performance.maxMenuBarWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.menuBarAccessibilityLabel)
    }

    // MARK: - Reading

    private var style: MenuBarStyle {
        preferences?.effectiveMenuBarStyle ?? .usage
    }

    /// nil means the glyph stands alone.
    private var reading: String? {
        switch style {
        case .minimal:
            return nil
        case .usage:
            // The view model already owns this fallback chain, so the percentage
            // reading has one definition rather than two that can drift.
            return model.menuBarText
        case .sessions:
            return "\(model.activeCount)"
        case .combined:
            // An unmeasured window contributes nothing rather than a placeholder.
            // The hollow glyph is already saying the percentage is unknown, and
            // a second marker for it would only spend width.
            guard let percent = model.primaryWindow?.usedPercent else {
                return "\(model.activeCount)"
            }
            return "\(model.activeCount)\u{00B7}\(Format.percent(percent))"
        }
    }

    // MARK: - Glyph

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
