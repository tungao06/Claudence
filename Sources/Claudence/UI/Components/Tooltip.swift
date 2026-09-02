import SwiftUI
import ClaudenceCore

/// How an explanation reaches the screen.
///
/// This is the design's own tooltip, not the system's. `Design/Claudence-UI.dc.html`
/// draws a dark bubble (`background` 0x2E2924, `border-radius: 12`,
/// `padding: 11px 13px`, `max-width: 320px`, `box-shadow: 0 14px 34px -12px`)
/// positioned at the cursor and clamped so it stays on screen, with a bold
/// title line over a softened body line, and it marks every trigger with a
/// `1px dotted` underline so a reader can see that an explanation exists before
/// hovering. An earlier build used `.help(_:)` instead and lost both halves:
/// the bubble and, more importantly, the affordance, since a native tooltip
/// advertises nothing at all.
///
/// ## Why this is allowed under the no-animation rule
///
/// `MenuBarExtra(style: .window)` keeps this content mounted for the life of the
/// process, so nothing here may repeat. Nothing here does. Hover tracking costs
/// exactly zero while the pointer is elsewhere: `onContinuousHover` delivers
/// `.ended` once and no further work happens. While the pointer *is* over a
/// trigger the x coordinate is quantised onto `Tooltip.pointerQuantum` before it
/// reaches state, so a slow drag across a row produces a handful of updates
/// rather than one per frame. The only animation is a single fade driven by
/// `value: isShowing`, which is a `Bool` and therefore already quantised.
///
/// ## Why the bubble is drawn at the root rather than on the trigger
///
/// A `.popover` is a real `NSWindow` on macOS and this content is already inside
/// one that is not an ordinary window, so the bubble stays inside the same view
/// tree. It was an overlay on the trigger itself until a shot of the dashboard
/// showed what that costs: an overlay is painted in its own container's turn,
/// so the power meter's bubble was painted under the Active-sessions card drawn
/// after it and cut off mid-word, and it was proposed the trigger's width, so a
/// 320 pt bubble hanging off a 100 pt tube wrapped its title onto two lines.
///
/// The trigger now publishes what it wants shown through a preference, and one
/// `tooltipLayer()` at the root of each window draws it last, over everything,
/// clamped against that window rather than against the trigger. `edge` is kept
/// as the hint for which way a bubble hangs off a narrow trigger; the clamp
/// decides the rest.
///
/// Nothing here reads a value the caller has not measured. `breakdown` composes
/// the design's own suffix from figures passed in, and when the total is zero it
/// omits the suffix entirely rather than printing a 0% share of nothing.

// MARK: - Placement

/// Which way a bubble hangs when it is wider than the thing it explains.
///
/// Not decoration: the popover is 420 pt wide and a bubble may be 320, so a
/// narrow trigger near one edge has only one direction it can open in without
/// leaving the window.
enum TooltipEdge: Sendable {
    case leading
    case center
    case trailing
}

/// The dotted rule the design draws under a trigger.
///
/// Two colours because the design uses two: the neutral 0xD6CCBF on cream, and
/// the warmer 0xC9B7A8 where the ground is the warm inset panel and the
/// neutral one disappears into it.
enum TooltipUnderline: Sendable {
    /// No affordance. The default, because most triggers in this application
    /// are whole rows and tiles, and the design underlines text, not rows.
    case none
    case neutral
    case warm

    var color: Color? {
        switch self {
        case .none: return nil
        case .warm: return Theme.dottedUnderlineSheet
        case .neutral: return Theme.dottedUnderline
        }
    }
}

// MARK: - Attachment

extension View {

    /// Attaches an explanation, or nothing at all when there is none.
    ///
    /// A missing entry is an ordinary outcome, not a bug: a caller may key off
    /// a value that has no explanation written for it.
    @ViewBuilder
    func tooltip(
        _ entry: TooltipText.Entry?,
        edge: TooltipEdge = .center,
        underline: TooltipUnderline = .none
    ) -> some View {
        if let entry {
            modifier(TooltipModifier(entry: entry, edge: edge, underline: underline))
        } else {
            self
        }
    }

    /// A metric tooltip, keyed as the design keys it.
    func tooltip(
        tip key: String,
        edge: TooltipEdge = .center,
        underline: TooltipUnderline = .none
    ) -> some View {
        tooltip(TooltipText.tip(key), edge: edge, underline: underline)
    }

    /// A session-fact tooltip, keyed on the fact's visible label.
    func tooltip(
        fact name: String,
        edge: TooltipEdge = .center,
        underline: TooltipUnderline = .none
    ) -> some View {
        tooltip(TooltipText.fact(name), edge: edge, underline: underline)
    }

    /// A breakdown-row tooltip, keyed on the row's visible label and carrying
    /// that row's measured share of the measured total.
    func tooltip(
        breakdown label: String,
        value: Int,
        of total: Int,
        edge: TooltipEdge = .center
    ) -> some View {
        tooltip(Tooltip.breakdownEntry(label: label, value: value, total: total), edge: edge)
    }
}

// MARK: - What the root draws

/// One bubble's worth of instructions, sent from a trigger to the root.
struct TooltipPresentation: Equatable {
    let entry: TooltipText.Entry
    /// The trigger's frame in the tooltip layer's coordinate space.
    let triggerFrame: CGRect
    /// Where the pointer sits inside the trigger, quantised.
    let pointerX: CGFloat
    let edge: TooltipEdge
}

/// Only one tooltip is ever shown, so the last writer wins: the pointer can
/// only be inside one trigger, and a nil from a trigger that has just ended its
/// hover must not erase the one that has just begun.
struct TooltipPreferenceKey: PreferenceKey {
    static let defaultValue: TooltipPresentation? = nil

    static func reduce(value: inout TooltipPresentation?, nextValue: () -> TooltipPresentation?) {
        if let next = nextValue() { value = next }
    }
}

extension View {

    /// Draws the tooltip for everything inside it, over everything inside it.
    ///
    /// Apply once per window: the popover's content, the dashboard's, and the
    /// detail sheet's, which is its own window and therefore its own layer. A
    /// second layer nested inside the first would draw the same bubble twice.
    func tooltipLayer() -> some View {
        coordinateSpace(name: Tooltip.layerSpace)
            .overlayPreferenceValue(TooltipPreferenceKey.self) { presentation in
                GeometryReader { proxy in
                    TooltipLayer(presentation: presentation, bounds: proxy.size)
                }
                .allowsHitTesting(false)
            }
    }
}

/// The root's bubble: measured, then placed against the window's own bounds.
private struct TooltipLayer: View {
    let presentation: TooltipPresentation?
    let bounds: CGSize

    @State private var bubbleSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let presentation {
                TooltipBubble(entry: presentation.entry)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { bubbleSize = $0 }
                    .offset(x: x(presentation), y: y(presentation))
                    // One frame passes before the size is known. Placing an
                    // unmeasured bubble would show it jumping into position.
                    .opacity(bubbleSize.width > 0 ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // On presence alone, never on position: the pointer publishes a new
        // frame every 4 pt it travels, and animating those would run an
        // interpolation for as long as the pointer stays on a trigger.
        .animation(
            Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
            value: presentation != nil
        )
    }

    /// Follows the pointer, then clamps against the window. The mockup clamps
    /// against the viewport with a fixed-position element; this is the same
    /// clamp, against the only bounds this content has.
    private func x(_ presentation: TooltipPresentation) -> CGFloat {
        let trigger = presentation.triggerFrame
        let preferred: CGFloat
        if bubbleSize.width <= trigger.width {
            preferred = trigger.minX + presentation.pointerX - bubbleSize.width / 2
        } else {
            switch presentation.edge {
            case .leading: preferred = trigger.minX
            case .center: preferred = trigger.midX - bubbleSize.width / 2
            case .trailing: preferred = trigger.maxX - bubbleSize.width
            }
        }
        let last = max(Tooltip.windowInset, bounds.width - bubbleSize.width - Tooltip.windowInset)
        return min(max(Tooltip.windowInset, preferred), last)
    }

    /// Above the trigger, as the design draws it, unless the window has no room
    /// there; then below.
    private func y(_ presentation: TooltipPresentation) -> CGFloat {
        let trigger = presentation.triggerFrame
        let needed = bubbleSize.height + Theme.Space.s
        guard trigger.minY - needed >= Tooltip.windowInset else {
            return min(trigger.maxY + Theme.Space.s, max(0, bounds.height - bubbleSize.height))
        }
        return trigger.minY - needed
    }
}

// MARK: - Modifier

private struct TooltipModifier: ViewModifier {
    let entry: TooltipText.Entry
    let edge: TooltipEdge
    let underline: TooltipUnderline

    @State private var isShowing = false
    @State private var pointerX: CGFloat = 0
    /// The trigger's frame in the layer's coordinate space, which is what the
    /// root needs to place a bubble the trigger no longer draws.
    @State private var triggerFrame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) { rule }
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Tooltip.layerSpace))
            } action: { frame in
                triggerFrame = frame
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    // Quantised before it reaches state: a pointer drag would
                    // otherwise push one view update per mouse event.
                    let stepped = (location.x / Tooltip.pointerQuantum).rounded() * Tooltip.pointerQuantum
                    if stepped != pointerX { pointerX = stepped }
                    if !isShowing { isShowing = true }
                case .ended:
                    if isShowing { isShowing = false }
                }
            }
            .preference(key: TooltipPreferenceKey.self, value: presentation)
            // The bubble is drawn, not spoken. VoiceOver gets the same words as
            // a hint so the two audiences read the same explanation.
            .accessibilityHint(Tooltip.render(entry))
    }

    private var presentation: TooltipPresentation? {
        guard isShowing, triggerFrame.width > 0 else { return nil }
        return TooltipPresentation(
            entry: entry,
            triggerFrame: triggerFrame,
            pointerX: pointerX,
            edge: edge
        )
    }

    @ViewBuilder
    private var rule: some View {
        if let color = underline.color {
            DottedRule(color: color)
                .offset(y: Tooltip.underlineDrop)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Bubble

/// The design's bubble: a bold title over a softened body, dark in both
/// appearances, wrapped at `Theme.Layout.tooltipMaxWidth`.
struct TooltipBubble: View {
    let entry: TooltipText.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(entry.title)
                .font(Theme.Typography.tooltipTitle)
                .foregroundStyle(Tooltip.ink)
            Text(entry.body)
                .font(Theme.Typography.body)
                .foregroundStyle(Tooltip.ink.opacity(Tooltip.bodyInkOpacity))
                .fixedSize(horizontal: false, vertical: true)
        }
        // Wrapped at the design's width and no wider. `fixedSize` is what makes
        // the wrap happen here rather than at whatever width the container
        // proposes, which used to be the trigger's and folded short titles onto
        // two lines.
        .frame(maxWidth: Theme.Layout.tooltipMaxWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, Theme.Layout.tooltipPaddingVertical)
        .padding(.horizontal, Theme.Layout.tooltipPaddingHorizontal)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.tooltipSurface)
        )
        .themeShadow(Theme.Shadow.tooltip)
        .accessibilityHidden(true)
    }
}

/// A one-pixel dotted rule. Drawn rather than borrowed from `Divider`, which
/// has no dash pattern.
struct DottedRule: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 0.5))
            path.addLine(to: CGPoint(x: size.width, y: 0.5))
            context.stroke(
                path,
                with: .color(color),
                style: StrokeStyle(lineWidth: 1, dash: Tooltip.underlineDash)
            )
        }
        .frame(height: 1)
        .accessibilityHidden(true)
    }
}

// MARK: - Composition rules

/// Composition rules for tooltip text. Separate from the modifiers so the
/// string building is testable without a view.
enum Tooltip {

    /// The mockup's fixed separator: two spaces, a middle dot, two spaces.
    static let separator = "  ·  "

    /// The coordinate space every trigger reports its frame in, and the space
    /// the root places bubbles in.
    static let layerSpace = "tooltip-layer"

    /// How close a bubble may come to the window's edge before it is clamped.
    static let windowInset: CGFloat = Theme.Space.s

    /// How far the pointer must travel before the bubble is repositioned. Four
    /// points is under one character and keeps the follow smooth while cutting
    /// state writes by roughly an order of magnitude against one per event.
    static let pointerQuantum: CGFloat = 4

    /// CSS `1px dotted` renders as a 1 pt dot every 2 pt on this platform.
    static let underlineDash: [CGFloat] = [1, 2]

    /// The rule sits just clear of the baseline, as `border-bottom` does.
    static let underlineDrop: CGFloat = 1

    /// The bubble's text. Light in both appearances, against a dark bubble.
    static var ink: Color { Theme.tooltipInk }

    /// HTML sets the body at `rgba(246,241,233,.72)` against the same ink.
    static let bodyInkOpacity: Double = 0.72

    /// Title first, body under it, for anything that needs the two as one
    /// string: an accessibility hint, or a test.
    static func render(_ entry: TooltipText.Entry) -> String {
        "\(entry.title)\n\(entry.body)"
    }

    /// The breakdown body with the design's numeric suffix appended:
    /// `body + "  ·  " + value + " of " + total + " (" + pct + "%)"`.
    ///
    /// Both figures are the caller's measurements. When the total is zero the
    /// suffix is dropped: a share of nothing is undefined, and "0 of 0 (0%)"
    /// would read as a measurement rather than as an absence.
    static func breakdownEntry(label: String, value: Int, total: Int) -> TooltipText.Entry? {
        guard let entry = TooltipText.breakdown(label) else { return nil }
        guard total > 0 else { return entry }
        let percent = Int((Double(value) / Double(total) * 100).rounded())
        let suffix = separator
            + Format.tokens(value)
            + " of "
            + Format.tokens(total)
            + " (\(percent)%)"
        return TooltipText.Entry(title: entry.title, body: entry.body + suffix)
    }
}
