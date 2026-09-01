import SwiftUI

/// The honest empty state.
///
/// Rendered wherever a value is nil. It never substitutes a zero, a dash in a
/// bar, or a placeholder fill, because a fabricated number is worse than an
/// absent one. See spec section 9.4.
struct UnavailableView: View {
    /// What is missing, in plain words.
    let message: String
    /// Optional second line explaining why, when a reason is actually known.
    let reason: String?
    /// Compact form fits inside a session row; regular form stands alone.
    let isCompact: Bool

    init(_ message: String = "Usage unavailable", reason: String? = nil, compact: Bool = false) {
        self.message = message
        self.reason = reason
        self.isCompact = compact
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Image(systemName: "minus.circle")
                .font(.system(size: isCompact ? Theme.Bar.statusGlyph : Theme.Bar.severityGlyph))
                .foregroundStyle(Theme.textTertiary)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(message)
                    .font(isCompact ? Theme.Typography.caption : Theme.Typography.body)
                    .foregroundStyle(Theme.textSecondary)
                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .lineLimit(isCompact ? 1 : 2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        guard let reason, !reason.isEmpty else { return message }
        return "\(message). \(reason)"
    }
}
