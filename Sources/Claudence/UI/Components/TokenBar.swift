import SwiftUI
import ClaudenceCore

/// Token energy for one session or one roll-up.
///
/// The bar always measures `usage.total`; the breakdown always shows cache
/// separately from fresh input, because cache reads cost roughly an order of
/// magnitude less and collapsing them makes the display disagree with the bill.
/// Nothing here recomputes a total: `TokenUsage` owns the formula.
/// See spec section 5.
struct TokenBar: View {
    /// Nil means no transcript has been read for this session yet.
    let usage: TokenUsage?
    /// The value that corresponds to a full bar. Nil means we have no scale, so
    /// no bar is drawn: a fill without a denominator would be a made-up ratio.
    let scaleMaximum: Int?
    /// Severity of the fill. Token volume alone is not an alarm, so the default
    /// is the neutral healthy token; a caller holding a context percentage can
    /// pass a real severity.
    let severity: Severity
    let height: CGFloat
    let isExpandable: Bool
    /// When a container owns the disclosure state (a session row, say), it
    /// passes a binding and supplies its own control. Otherwise the bar keeps
    /// its own local UI state and draws its own chevron.
    let expansion: Binding<Bool>?
    let unavailableMessage: String

    @State private var localExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        usage: TokenUsage?,
        scaleMaximum: Int? = nil,
        severity: Severity = .healthy,
        height: CGFloat = Theme.Bar.row,
        isExpandable: Bool = true,
        startsExpanded: Bool = false,
        expansion: Binding<Bool>? = nil,
        unavailableMessage: String = "Token usage unavailable"
    ) {
        self.usage = usage
        self.scaleMaximum = scaleMaximum
        self.severity = severity
        self.height = height
        self.isExpandable = isExpandable
        self.expansion = expansion
        self.unavailableMessage = unavailableMessage
        _localExpanded = State(initialValue: startsExpanded)
    }

    private var isShowingBreakdown: Bool {
        guard isExpandable else { return false }
        return expansion?.wrappedValue ?? localExpanded
    }

    private var showsDisclosureControl: Bool { isExpandable && expansion == nil }

    private var fraction: Double? {
        guard let usage, let scaleMaximum, scaleMaximum > 0 else { return nil }
        return min(1, max(0, Double(usage.total) / Double(scaleMaximum)))
    }

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                summary(usage)
                if let fraction {
                    bar(fraction: fraction)
                }
                if isShowingBreakdown {
                    breakdown(usage)
                        .transition(.opacity)
                }
            }
            .animation(
                Theme.animation(Theme.Motion.disclosure, reduceMotion: reduceMotion),
                value: isShowingBreakdown
            )
        } else {
            UnavailableView(unavailableMessage, compact: true)
        }
    }

    // MARK: - Summary line

    private func summary(_ usage: TokenUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Text("Token energy")
                .font(Theme.Typography.label)
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: Theme.Space.xs)
            Text(Format.tokens(usage.total))
                .font(Theme.Typography.value)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if showsDisclosureControl {
                Button {
                    localExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.Bar.statusGlyph, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(localExpanded ? Theme.Motion.disclosureRotation : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localExpanded ? "Hide token breakdown" : "Show token breakdown")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryLabel(usage))
    }

    private func summaryLabel(_ usage: TokenUsage) -> String {
        var text = "Token energy, \(Format.tokens(usage.total)) total"
        if let fraction {
            text += ", \(Format.percent(fraction * 100)) of scale"
        }
        return text
    }

    // MARK: - Bar

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(Theme.track)
                Capsule(style: .continuous)
                    .fill(Theme.color(for: severity))
                    .frame(width: fraction <= 0 ? 0 : max(height, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(
            Theme.animation(Theme.Motion.valueChange, reduceMotion: reduceMotion),
            value: fraction
        )
        .accessibilityHidden(true)
    }

    // MARK: - Breakdown

    private func breakdown(_ usage: TokenUsage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            row("Fresh input", usage.freshInput)
            row("Cache write", usage.cacheCreation)
            row("Cache read", usage.cacheRead)
            row("Output", usage.output)
            Divider().overlay(Theme.separator)
            row("Total", usage.total, emphasised: true)
        }
        .padding(.top, Theme.Space.xxs)
    }

    private func row(_ name: String, _ value: Int, emphasised: Bool = false) -> some View {
        HStack(spacing: Theme.Space.xs) {
            Text(name)
                .font(Theme.Typography.body)
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Space.m)
            Text(Format.tokens(value))
                .font(Theme.Typography.numeric)
                .foregroundStyle(emphasised ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(Format.tokens(value)) tokens")
    }
}
