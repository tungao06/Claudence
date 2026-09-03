import ClaudenceCore
import SwiftUI

/// The one dollar figure this application does not measure.
///
/// Every other figure in Claudence's money story is derived: token counts
/// come from transcripts, and a price comes from a published API rate table.
/// A subscription's own price is neither -- Claude Code's account file names
/// a tier (`Max 5x`, `Pro`) but never states what that tier costs, and
/// CLAUDE.md forbids hard-coding a published price here, since none of them
/// are measured anywhere in this codebase and a baked-in number goes stale
/// silently the next time Anthropic changes one. So it is the one figure the
/// user supplies once, rather than the one the application reads.
///
/// Empty by default. `StatTilesView`'s cost tile shows it beside the
/// API-equivalent estimate only once it is set, so a friend who never opens
/// this screen sees that tile exactly as it read before this preference
/// existed (9.14).
struct SubscriptionSettings: View {
    @Bindable var preferences: Preferences

    /// A local text buffer rather than a binding straight to the `Double?`
    /// preference. A number typed one keystroke at a time passes through
    /// intermediate strings that are not valid numbers at all ("", "-", "12."
    /// before the digit after the point lands), and persisting each of those
    /// would either reject the keystroke or silently round it away.
    @State private var text: String = ""

    var body: some View {
        SettingsSection(title: "Subscription") {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Plan price")
                    .font(Theme.Typography.cardTitle.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)

                priceField

                SettingsExplanation(text: Self.explanation)
            }
        }
        .onAppear { text = Self.format(preferences.subscriptionMonthlyPrice) }
    }

    private var priceField: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("$")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textTertiary)
            TextField("Not set", text: $text)
                .textFieldStyle(.plain)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.textPrimary)
                .onChange(of: text) { _, newValue in commit(newValue) }
            Text("/ month")
                .font(Theme.Typography.help)
                .foregroundStyle(Theme.textQuaternary)
        }
        .padding(.vertical, Theme.Space.s)
        .padding(.horizontal, Theme.Space.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(Theme.surfaceControl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 1)
        )
        .accessibilityLabel("Subscription price per month")
        .accessibilityValue(
            preferences.subscriptionMonthlyPrice.map { Format.cost($0) } ?? "not set"
        )
        .accessibilityHint(Self.explanation)
    }

    /// Blank clears the preference back to "not set" rather than to zero --
    /// zero is a real price and this application has never measured one.
    /// Anything that does not parse as a positive number is left alone rather
    /// than persisted, so a stray character mid-edit never overwrites a
    /// previously valid figure with `nil`.
    private func commit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            preferences.subscriptionMonthlyPrice = nil
            return
        }
        guard let value = Double(trimmed), value > 0 else { return }
        preferences.subscriptionMonthlyPrice = value
    }

    private static func format(_ price: Double?) -> String {
        guard let price else { return "" }
        return price.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(price))
            : String(price)
    }

    private static let explanation = """
    What this subscription costs you, so the API-equivalent estimate below \
    reads beside a real price instead of standing on its own. Not published \
    anywhere Claudence can read, so nothing is shown until you type it here.
    """
}
