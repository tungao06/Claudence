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

    public static func percent(_ value: Double?) -> String {
        guard let value else { return "--" }
        return "\(Int(value.rounded()))%"
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
