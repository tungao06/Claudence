import SwiftUI
import ClaudenceCore

/// How an explanation reaches the screen.
///
/// The design draws its own dark bubble that follows the cursor, tracked in
/// mockup JavaScript by a pair of coordinates updated on every `mousemove`.
/// This build uses `.help(_:)` instead, and the reason is the same one that
/// removed every repeating animation from the popover: `MenuBarExtra(style:
/// .window)` keeps this content mounted after the popover is dismissed, so
/// anything that holds live cursor state costs a layout pass whenever it
/// changes, for the life of the process. `.help(_:)` costs nothing until the
/// pointer stops over the view, is drawn by AppKit rather than by us, and comes
/// with the system's own delay, placement and screen-edge clamping already
/// correct.
///
/// What is lost is the bubble's styling: a native tooltip has no bold title
/// line, so the title is composed onto the first line and the body follows on
/// the next. That is a visual difference from the mockup and a deliberate one.
///
/// Nothing here reads a value the caller has not measured. `breakdown` composes
/// the design's own suffix from figures passed in, and when the total is zero it
/// omits the suffix entirely rather than printing a 0% share of nothing.
extension View {

    /// Attaches an explanation, or nothing at all when there is none.
    ///
    /// A missing entry is an ordinary outcome, not a bug: two of the design's
    /// strings are wrong about this application and are deliberately absent from
    /// the lookups, so a view asking for one gets no tooltip.
    @ViewBuilder
    func tooltip(_ entry: TooltipText.Entry?) -> some View {
        if let entry {
            help(Tooltip.render(entry))
        } else {
            self
        }
    }

    /// A metric tooltip, keyed as the design keys it.
    func tooltip(tip key: String) -> some View {
        tooltip(TooltipText.tip(key))
    }

    /// A session-fact tooltip, keyed on the fact's visible label.
    func tooltip(fact name: String) -> some View {
        tooltip(TooltipText.fact(name))
    }

    /// A breakdown-row tooltip, keyed on the row's visible label and carrying
    /// that row's measured share of the measured total.
    func tooltip(breakdown label: String, value: Int, of total: Int) -> some View {
        tooltip(Tooltip.breakdownEntry(label: label, value: value, total: total))
    }
}

/// Composition rules for tooltip text. Separate from the modifiers so the
/// string building is testable without a view.
enum Tooltip {

    /// The mockup's fixed separator: two spaces, a middle dot, two spaces.
    static let separator = "  ·  "

    /// Title first, body under it. A native tooltip has one text style, so the
    /// line break is all the hierarchy available.
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
