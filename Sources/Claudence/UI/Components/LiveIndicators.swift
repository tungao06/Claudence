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

/// Whether `Preferences.liveOnlyMode` is on, carried down the view tree the
/// same way `liveIndicators` is.
///
/// Live-only mode points the shared store at memory: nothing survives a quit,
/// so any surface that can only be computed from stored history has nothing
/// honest to show. Those surfaces are not rendered as `Usage unavailable` --
/// the mode is not a degraded state, it is a choice -- they are omitted
/// outright, and the layout around them closes up. Deciding that is a view's
/// job, not the adapter's, which is why this is an environment value rather
/// than a field the adapter leaves nil: a nil in `DashboardData` already means
/// "the store could not answer," and reusing it here would make an
/// intentional omission indistinguishable from a failed read.
///
/// One environment key rather than a parameter threaded through `DashboardView`,
/// `StatTilesView` and every card in between, for the same reason
/// `liveIndicators` is one: a setting that reaches some of its views through a
/// parameter and others through the environment is the failure this pattern
/// exists to rule out.
private struct LiveOnlyModeKey: EnvironmentKey {
    /// False, so a preview or a view outside the app's scenes renders the full
    /// dashboard by default rather than silently hiding history.
    static let defaultValue = false
}

extension EnvironmentValues {
    var liveOnlyMode: Bool {
        get { self[LiveOnlyModeKey.self] }
        set { self[LiveOnlyModeKey.self] = newValue }
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
