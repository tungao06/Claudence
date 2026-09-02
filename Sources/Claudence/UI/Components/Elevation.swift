import SwiftUI

/// How far a surface answers the pointer, and what it casts while it does.
///
/// Two levels, because the window has two kinds of surface a pointer can be
/// inside: a card, which is one of six on the screen, and a row, which is one
/// of dozens. They are deliberately not the same size of gesture. A card
/// rising two points reads as the panel under the pointer coming forward; a
/// list of twenty rows doing the same would read as the list heaving, so a row
/// rises one point and casts a shorter, tighter shadow.
///
/// Every number here is already in `Theme`. This type does not invent a
/// distance or a falloff, it only says which of the existing pair a given
/// surface uses, so that six call sites cannot drift into six answers.
///
/// Depth is drawn with a translation and a shadow, never with a scale. A scaled
/// card resamples its own text for as long as the pointer is over it, which is
/// both visibly soft and the only part of a hover that costs anything;
/// `Theme.Elevation` says the same thing where the constants live.
enum ElevationLevel {

    /// A panel: a `DashboardCard`, a stat tile.
    case card
    /// One entry in a list: a session, a history line, a project.
    case row

    /// How far the surface rises while the pointer is inside it. Negative,
    /// because up on this screen is toward the top of the window.
    var lift: CGFloat {
        switch self {
        case .card: return Theme.Elevation.cardLift
        case .row: return Theme.Elevation.rowLift
        }
    }

    /// How far a pressed surface gives that lift back.
    ///
    /// Exactly the lift and no more, so a row being clicked settles onto the
    /// ground it rose from. A press that travelled further than the hover it
    /// cancels would read as a dent rather than as a release, and a dent is a
    /// second gesture the reader has to learn.
    var settle: CGFloat { -lift }

    /// What the raised surface casts.
    var hoverShadow: Theme.ShadowToken {
        switch self {
        case .card: return Theme.Shadow.cardHover
        case .row: return Theme.Shadow.rowHover
        }
    }

    /// The corner a surface of this level is cut to when the call site does not
    /// say otherwise. Call sites whose own background is cut differently pass
    /// their own radius, so the ground below can never peek past the surface it
    /// is sitting under.
    var cornerRadius: CGFloat {
        switch self {
        case .card: return Theme.Radius.card
        case .row: return Theme.Radius.row
        }
    }

    /// The shadow a surface casts at rest, which is none.
    ///
    /// Spelled as a token with the hover shadow's own colour taken to zero
    /// rather than by leaving `.shadow` off entirely, because a modifier that
    /// appears on hover and vanishes on exit is a structural change to the view
    /// tree and SwiftUI interpolates nothing across one: the surface would rise
    /// smoothly and then snap flat. Four numbers that can be interpolated give
    /// it a way back down.
    var restShadow: Theme.ShadowToken {
        Theme.ShadowToken(color: hoverShadow.color.opacity(0), radius: 0, x: 0, y: 0)
    }
}

/// A surface that rises while the pointer is inside it.
///
/// The whole of the motion is driven by the pointer and none of it repeats. An
/// idle window runs nothing here by construction rather than by a flag being
/// right, which is the distinction `CLAUDE.md`'s no-repeating-animation rule is
/// actually about: `MenuBarExtra(style: .window)` keeps its content mounted
/// after dismissal, so anything that animates on its own animates forever.
///
/// Three details are not obvious and each is load-bearing.
///
/// The `ZStack` looks redundant and is not. `.offset` moves a view for drawing
/// and for hit testing but not for layout, so the stack around it keeps a frame
/// that does not move while its child does. The pointer tracking installed by
/// the caller therefore sits on a fixed rectangle. Without it, a pointer parked
/// in the bottom two points of a card would leave the card's own hover region
/// the moment the card rose, which drops it, which puts the pointer back
/// inside: an oscillation at the refresh rate, indistinguishable in cost from
/// the repeating animation the project forbids.
///
/// The ground behind the content exists so the shadow has something to fall
/// from. A shadow is derived from what it is cast by, so applied to a row that
/// is nothing but text it would blur the glyphs into a second, softer copy of
/// themselves rather than reading as a raised surface. Cards, tiles and session
/// rows already own an opaque background, and theirs is drawn in front of this
/// one, so for them the ground is invisible and only its shape matters.
///
/// The animation is one-shot and reads `accessibilityReduceMotion` through
/// `Theme.animation(_:reduceMotion:)`, which returns nil under Reduce Motion.
/// A nil animation is not a slower animation: the lift and the shadow both
/// arrive immediately, and the depth is still there to be read.
private struct Elevated: ViewModifier {
    let level: ElevationLevel
    let cornerRadius: CGFloat
    let isHovering: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
                .background(ground)
                .offset(y: isHovering ? level.lift : 0)
        }
        .animation(
            Theme.animation(Theme.Motion.hover, reduceMotion: reduceMotion),
            value: isHovering
        )
    }

    /// The hover ground: the shadow's caster, and for a row with no background
    /// of its own also the mark of what the pointer is on.
    ///
    /// `surfaceInset` rather than a lighter step, because in the light
    /// appearance the card underneath is already the whitest surface in the
    /// palette and there is nothing above it to move to. The rise is carried by
    /// the shadow and the translation; the ground only says which row.
    private var ground: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(isHovering ? Theme.surfaceInset : Color.clear)
            .themeShadow(isHovering ? level.hoverShadow : level.restShadow)
    }
}

/// Owns the pointer state for a surface that has no other reason to track it.
///
/// The tracking is attached outside `Elevated`, on the stack whose frame the
/// lift cannot move. See the note on `Elevated` for why that matters.
private struct ElevatedOnHover: ViewModifier {
    let level: ElevationLevel
    let cornerRadius: CGFloat

    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .modifier(
                Elevated(level: level, cornerRadius: cornerRadius, isHovering: isHovering)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {

    /// Raises this surface while the pointer is inside it.
    ///
    /// `cornerRadius` defaults to the level's own and should be overridden by
    /// any surface cut to a different corner, so that the ground behind it
    /// stays hidden behind it at the corners as well as along the edges.
    func elevates(_ level: ElevationLevel, cornerRadius: CGFloat? = nil) -> some View {
        modifier(
            ElevatedOnHover(level: level, cornerRadius: cornerRadius ?? level.cornerRadius)
        )
    }
}

/// A clickable row that settles under the press.
///
/// The press does not add a gesture of its own, it takes one away: the row
/// gives back exactly the lift the pointer gave it and rests on the surface
/// again for as long as the button is held. That is the smallest thing a
/// surface can do that still acknowledges a click, and it cannot be mistaken
/// for the row moving somewhere.
///
/// A `ButtonStyle` rather than a gesture, because the pressed state is the
/// button's own and reading it any other way would mean re-implementing what
/// counts as a press, including the drag back out that cancels one.
///
/// This replaces `.plain` at its call sites. `.plain` renders the label with no
/// chrome and no tint, and so does this: `configuration.label` inherits the
/// foreground style it was given, and every label this is used on sets its own
/// colours on every run of text.
struct ElevatedRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? ElevationLevel.row.settle : 0)
            .animation(
                Theme.animation(Theme.Motion.press, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}
