import SwiftUI
import ClaudenceCore

/// The focus ring, defined once.
///
/// `UsageChart` drew the first one, inline, out of `Theme.accent` and
/// `DashboardMetrics.focusRingWidth`. Two more surfaces need the same ring
/// now, and three inline copies of a ring is how a product ends up with three
/// slightly different rings. The colour is a semantic token and the width is
/// the existing constant, so this changes nothing about the one already on
/// screen; it only stops the next one from being drawn by hand.
///
/// It is an overlay rather than a border, so a ring never changes the size of
/// what it surrounds and a row does not move when it takes focus.
extension View {
    func focusRing(_ isVisible: Bool, cornerRadius: CGFloat = Theme.Radius.row) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: DashboardMetrics.focusRingWidth)
                .opacity(isVisible ? 1 : 0)
                // The ring is drawn, not spoken. VoiceOver already announces
                // focus, so an accessibility element here would say it twice.
                .accessibilityHidden(true)
        )
    }
}

/// Arrow-key navigation over a vertical list of rows, as one tab stop.
///
/// ## Why one tab stop and not one per row
///
/// This is the macOS convention and it is the convention for a reason: a
/// `List` or a `Table` is a single stop in the tab chain, and the arrow keys
/// move a selection inside it. Making every row its own stop would put twelve
/// presses between the top of the popover and the footer link under it, and a
/// popover with four sessions in it is not a form.
///
/// ## What it does not pretend to fix
///
/// Whether Tab reaches a focusable view at all is a system setting -- Keyboard
/// navigation, in System Settings > Keyboard -- and no application can turn it
/// on for the user. That is why `defaultFocus` matters here: the popover has
/// no text field competing for it, so the session list can hold focus from the
/// moment the popover opens, and the arrow keys work for someone who never
/// found that setting. Someone who did find it gets the list as an ordinary
/// tab stop as well.
struct KeyboardListModifier: ViewModifier {
    /// Row identifiers, in the order they are drawn.
    let identifiers: [String]
    /// The current keyboard selection, owned by the caller so it can draw the
    /// ring on the right row.
    @Binding var selection: String?
    /// What Return does to the selected row. Nil when the list has no action,
    /// in which case the selection is a reading position and nothing more.
    let onActivate: ((String) -> Void)?

    func body(content: Content) -> some View {
        content
            .focusable(!identifiers.isEmpty)
            .onMoveCommand { direction in
                switch direction {
                case .up:
                    selection = ListKeyboardSelection.move(from: selection, .up, in: identifiers)
                case .down:
                    selection = ListKeyboardSelection.move(from: selection, .down, in: identifiers)
                default:
                    // Left and right belong to whatever is inside a row, or to
                    // nothing. Swallowing them here would make a horizontal
                    // control unreachable once the list has focus.
                    break
                }
            }
            .onKeyPress(.return) {
                guard let selection, let onActivate else { return .ignored }
                onActivate(selection)
                return .handled
            }
            // Escape puts the cursor away without closing anything. In the
            // popover the same key would otherwise dismiss the window, which
            // is a much larger action than the one a user pressing it after
            // arrowing around is asking for.
            .onExitCommand { selection = nil }
            // A list that changed under the cursor must not keep a selection
            // that is no longer in it. See `ListKeyboardSelection.surviving`.
            .onChange(of: identifiers) { _, latest in
                selection = ListKeyboardSelection.surviving(selection, in: latest)
            }
    }
}

extension View {
    /// Adds arrow-key navigation over `identifiers`, with Return activating
    /// the selected row.
    func keyboardList(
        _ identifiers: [String],
        selection: Binding<String?>,
        onActivate: ((String) -> Void)? = nil
    ) -> some View {
        modifier(
            KeyboardListModifier(
                identifiers: identifiers,
                selection: selection,
                onActivate: onActivate
            )
        )
    }
}

/// A keyboard shortcut that only some call sites want.
///
/// `keyboardShortcut` has no "no shortcut" value, and an `if` inside a view
/// builder returns two different types, so the choice has to be a modifier.
/// Same shape as `SessionDetailView`'s own `EscapeShortcut`, which exists for
/// the same reason.
struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key)
        } else {
            content
        }
    }
}
