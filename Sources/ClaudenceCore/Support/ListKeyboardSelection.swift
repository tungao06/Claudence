import Foundation

/// Where the keyboard cursor lands next in a vertical list.
///
/// ## Why this is in Core rather than beside the view
///
/// It is arithmetic, and the arithmetic is where the mistakes are: an
/// off-by-one at either end, a stale identifier surviving a refresh, an empty
/// list producing a selection anyway. The views that use it live in the
/// executable target, which the test target deliberately does not depend on --
/// so a rule kept in a view is a rule argued from reading, and a rule kept
/// here is a rule with a test. The view is left with the part that genuinely
/// needs a view: drawing a ring and calling a handler.
///
/// ## The two decisions this type makes
///
/// **It does not wrap.** Down at the last row stays on the last row. A list of
/// live sessions is short and its ends are meaningful -- the newest and the
/// oldest -- and a cursor that silently jumps from one to the other reads as a
/// lost cursor rather than as a feature. Wrapping is also what makes a held
/// arrow key impossible to reason about.
///
/// **A selection that is no longer in the list is nothing, not the nearest
/// thing.** Sessions come and go while the popover is open. Substituting an
/// index-adjacent row when the selected one exits would move the cursor onto a
/// row the user never chose, and then Return would open that one. Clearing is
/// the honest answer to "the thing you had selected is gone"; the next arrow
/// press starts from the end again, which is where `first` puts it.
public enum ListKeyboardSelection {

    /// Which way the cursor is being asked to go.
    public enum Direction: Sendable, Equatable {
        case up
        case down
    }

    /// The identifier the cursor should hold after a move.
    ///
    /// - Parameters:
    ///   - current: what is selected now, or nil when nothing is.
    ///   - direction: the arrow that was pressed.
    ///   - identifiers: the list as it is on screen, in visual order.
    /// - Returns: the new selection, or nil when the list is empty.
    public static func move(
        from current: String?,
        _ direction: Direction,
        in identifiers: [String]
    ) -> String? {
        guard !identifiers.isEmpty else { return nil }

        // No selection yet, or one that has since left the list. Entering from
        // the top goes to the first row and entering from the bottom to the
        // last, which is what makes a single arrow press land somewhere a user
        // can predict from the key they pressed.
        guard let current, let index = identifiers.firstIndex(of: current) else {
            return direction == .down ? identifiers.first : identifiers.last
        }

        switch direction {
        case .up:
            return identifiers[max(0, index - 1)]
        case .down:
            return identifiers[min(identifiers.count - 1, index + 1)]
        }
    }

    /// The selection to keep after the list changed underneath it.
    ///
    /// Call it whenever the list is rebuilt. It keeps the selection when the
    /// row is still there and clears it when the row is gone, for the reason
    /// on the type.
    public static func surviving(_ current: String?, in identifiers: [String]) -> String? {
        guard let current, identifiers.contains(current) else { return nil }
        return current
    }
}
