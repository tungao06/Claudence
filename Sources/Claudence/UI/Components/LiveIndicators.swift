import SwiftUI

/// Whether the `Live indicators` setting is on, carried down the view tree.
///
/// The setting's own words are "mark the sessions that are working, and animate
/// a value once when it moves". Only the first half was ever wired: `isLive`
/// reached `StatusIndicator` and stilled its one-shot pulse, and every value
/// animation in the product went on running whatever the switch was set to. So
/// a user who turned it off to stop the movement still watched bars and arcs
/// slide, and the sentence under the switch described something the switch did
/// not do.
///
/// That `isLive` parameter is gone. It survived the move for a while alongside
/// this key, which left one setting with two delivery paths: `SessionRow` took
/// the flag *and* read the environment, and `SessionsTableView` passed no flag
/// at all, so the dashboard's status pill kept pulsing with the switch off. The
/// environment is now the only route, and there is nothing left to disagree.
///
/// An environment value rather than another parameter on six views: the bars are
/// leaves, several of them are three levels down from anything that knows what a
/// preference is, and threading a flag through every intermediate view to reach
/// them would put a setting's name in the signature of components that have no
/// other reason to know one exists.
///
/// It is deliberately not the same thing as Reduce Motion. Reduce Motion is the
/// system's accessibility setting and always wins; this is a preference about
/// how much the interface should move while it is working. Where both are read,
/// either one stills the animation.
private struct LiveIndicatorsKey: EnvironmentKey {
    /// True, so a preview or a view outside the app's scenes animates the way
    /// the product does by default rather than silently rendering still.
    static let defaultValue = true
}

extension EnvironmentValues {
    var liveIndicators: Bool {
        get { self[LiveIndicatorsKey.self] }
        set { self[LiveIndicatorsKey.self] = newValue }
    }
}

extension Theme {
    /// The animation for a value that has just moved, or nil when it should not
    /// move at all.
    ///
    /// One helper rather than `reduceMotion || !liveIndicators` written out at
    /// every call site: the two flags mean different things and the precedence
    /// between them is a decision, not something each bar should restate.
    static func valueAnimation(
        _ base: Animation = Theme.Motion.valueChange,
        reduceMotion: Bool,
        liveIndicators: Bool
    ) -> Animation? {
        guard liveIndicators else { return nil }
        return Theme.animation(base, reduceMotion: reduceMotion)
    }
}
