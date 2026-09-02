import SwiftUI

/// The dashboard's one card shell.
///
/// Every panel on the window is this: a titled block on `surface`, hairlined,
/// rounded once. It exists so the six panels cannot drift apart, and so the
/// design's two padding variants (20 all round, 20 by 22 for the chart) are a
/// parameter rather than six sets of numbers.
///
/// The title is optional because one panel supplies its own. `UsageChart` puts
/// a live readout where a title would go, and that readout replaces itself with
/// the day under the pointer, which a static header could not do; giving it a
/// card title as well would print the same words twice.
struct DashboardCard<Content: View>: View {

    /// How the design sets a card's title against its subtitle.
    ///
    /// Both arrangements are in section 1a and they are not interchangeable.
    /// The power meter and the sessions table put the subtitle on the title's
    /// own baseline, hard right, where it reads as an annotation on the card;
    /// the chart and the breakdown stack it underneath, where it reads as a
    /// second line of the title. Rendering all four the same way was the
    /// transcription this restores.
    enum HeaderLayout {
        /// `flex-direction: column; gap: 3px`.
        case stacked
        /// `align-items: baseline; justify-content: space-between`.
        case inline
    }

    let title: String?
    /// The quiet second line: what the panel measured, or where it came from.
    let subtitle: String?
    let headerLayout: HeaderLayout
    /// Tooltip key for the title, from `TooltipText`. Nil leaves the title
    /// inert rather than pointing at a tooltip that does not exist.
    let tooltipKey: String?
    let horizontalPadding: CGFloat
    let contentGap: CGFloat
    @ViewBuilder let content: Content

    init(
        title: String? = nil,
        subtitle: String? = nil,
        headerLayout: HeaderLayout = .stacked,
        tooltipKey: String? = nil,
        horizontalPadding: CGFloat = DashboardMetrics.cardPadding,
        contentGap: CGFloat = DashboardMetrics.cardContentGap,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.headerLayout = headerLayout
        self.tooltipKey = tooltipKey
        self.horizontalPadding = horizontalPadding
        self.contentGap = contentGap
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentGap) {
            if let title {
                header(title)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DashboardMetrics.cardPadding)
        .padding(.horizontal, horizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                // The design's cards sit one step *forward* of the shell they
                // are on: white panels on the cream window. Filling them with
                // `surface` made card and shell the same colour and left the
                // hairline doing all the separating on its own.
                .fill(Theme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(Theme.borderCard, lineWidth: DashboardMetrics.chartGridStroke)
        )
        // Depth is applied here rather than at the six call sites, so that
        // every panel on the window answers the pointer the same way and a
        // seventh panel gets it by being a card at all. The card level, not the
        // row level: this is the whole panel coming forward, and a panel that
        // moved as little as the rows inside it would not read as moving.
        .elevates(.card, cornerRadius: Theme.Radius.card)
    }

    @ViewBuilder
    private func header(_ title: String) -> some View {
        switch headerLayout {
        case .stacked:
            VStack(alignment: .leading, spacing: DashboardMetrics.cardHeaderGap) {
                titleText(title)
                subtitleText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .inline:
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                titleText(title)
                Spacer(minLength: Theme.Space.m)
                subtitleText
                    .multilineTextAlignment(.trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func titleText(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.cardTitle)
            .foregroundStyle(Theme.textPrimary)
            .accessibilityAddTraits(.isHeader)
            .tooltip(tooltipKey.flatMap(TooltipText.tip))
    }

    @ViewBuilder
    private var subtitleText: some View {
        if let subtitle {
            Text(subtitle)
                .font(Theme.Typography.help)
                .foregroundStyle(Theme.textQuaternary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
