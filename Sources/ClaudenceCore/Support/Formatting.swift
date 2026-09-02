import Foundation

public enum Format {
    /// 1_200 -> "1.2k", 128_000 -> "128k", 1_240_000 -> "1.24M"
    public static func tokens(_ value: Int) -> String {
        let n = abs(value)
        let sign = value < 0 ? "-" : ""
        switch n {
        case 0..<1_000:
            return "\(sign)\(n)"
        case 1_000..<10_000:
            return sign + trim(Double(n) / 1_000, decimals: 1) + "k"
        case 10_000..<1_000_000:
            return sign + trim(Double(n) / 1_000, decimals: n < 100_000 ? 1 : 0) + "k"
        default:
            return sign + trim(Double(n) / 1_000_000, decimals: 2) + "M"
        }
    }

    /// "12m 34s", "2h 14m", "3d 4h"
    public static func duration(_ interval: TimeInterval) -> String {
        let total = Int(max(0, interval))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = (total / 3_600) % 24
        let days = total / 86_400

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// Time until a reset point, or nil when it has passed or is unknown.
    public static func timeUntil(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let interval = date.timeIntervalSince(now)
        guard interval > 0 else { return nil }
        return duration(interval)
    }

    /// The clock time a window rolls over at, or nil when the source did not
    /// report one.
    ///
    /// A countdown answers "how long have I got"; this answers "when do I get
    /// it back", and those are different questions with different uses. `4h 35m`
    /// cannot be put in a calendar, checked against a meeting, or remembered
    /// past the moment it is read, because it is only true at the instant it
    /// was rendered. The absolute stamp stays true, which is also why it can sit
    /// in a view that does not tick.
    ///
    /// The day is named only when it is not today, and only as far as it has to
    /// be: `23:40` today, `Tomorrow 03:00` tomorrow, `Sep 5, 03:00` beyond
    /// that. A date printed on every reading would make the common case, which
    /// is a five-hour window rolling over later the same day, harder to read
    /// for the sake of the rare one.
    ///
    /// A reset already in the past is still stamped. `timeUntil` returns nil
    /// there and is right to, because a countdown to a moment that has gone is
    /// meaningless; a time that has gone is still a time, and the window may
    /// simply not have been re-read yet.
    public static func resetStamp(
        _ date: Date?,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        guard let date else { return nil }
        let time = clockFormatter.string(from: date)

        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday \(time)"
        }
        return "\(dayFormatter.string(from: date)), \(time)"
    }

    /// Both built once. A `DateFormatter` per call re-ran locale lookup for a
    /// format that never varies, and these are read on every popover render.
    ///
    /// `j` and `MMMd` rather than literal patterns: a 24-hour stamp on a machine
    /// set to 12-hour reads as a different time of day, not as a style choice,
    /// and a month-day order is not the same everywhere either.
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    public static func percent(_ value: Double?) -> String {
        // The em dash, which is what the design uses for an absent value and
        // what the session table already prints in its own empty cells. Two
        // ASCII hyphens were a transcription of that glyph, and having both on
        // one window made a missing figure look like two different kinds of
        // missing.
        guard let value else { return "\u{2014}" }
        return "\(Int(value.rounded()))%"
    }

    /// A category's share of a total, for a breakdown where one category can be
    /// a rounding error of another.
    ///
    /// `percent` rounds, and a rounded share prints `0%` for a category that
    /// really did spend tokens. Measured on a live session: fresh input was
    /// 2 k against a 197.7 M total, which is 0.001%, and `0%` printed beside a
    /// non-zero count reads as a contradiction rather than as a small number.
    /// So anything above nothing but below half a point is `<1%`.
    ///
    /// Exactly zero still prints `0%`, because that one is true, and the
    /// distinction is the whole point: this is the difference between "spent
    /// almost nothing" and "spent nothing".
    ///
    /// - Parameter fraction: 0 to 1, not a percentage.
    public static func share(_ fraction: Double) -> String {
        guard fraction > 0 else { return "0%" }
        let percentage = fraction * 100
        guard percentage >= 0.5 else { return "<1%" }
        return "\(Int(percentage.rounded()))%"
    }

    /// Estimated cost. Always rendered with its label by the caller.
    public static func cost(_ value: Double?) -> String {
        guard let value else { return "unavailable" }
        return String(format: "$%.2f", value)
    }

    private static func trim(_ value: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
