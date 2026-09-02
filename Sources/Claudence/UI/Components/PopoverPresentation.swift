import SwiftUI

/// Whether the menu bar popover is actually in front of the user.
///
/// `MenuBarExtra(style: .window)` builds its content at launch and keeps it
/// mounted in a window that is merely ordered out when dismissed, so a view in
/// the popover keeps taking part in the display cycle whether or not anyone can
/// see it. A `.repeatForever` animation on such a view drives a layout and a
/// display-list pass at the screen's refresh rate, forever. That was measured
/// at 6.9% of a core with the popover never opened.
///
/// Components read this to suppress motion they cannot be seen making.
///
/// **The default is `false` on purpose.** A wrong answer in this direction costs
/// a missing pulse; a wrong answer in the other direction costs the CPU budget.
/// Anything that cannot prove it is visible does not animate.
private struct PopoverPresentationKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var popoverIsPresented: Bool {
        get { self[PopoverPresentationKey.self] }
        set { self[PopoverPresentationKey.self] = newValue }
    }
}
