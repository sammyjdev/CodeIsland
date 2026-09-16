import Foundation

public enum WidgetFormat: Sendable {
    public static func percent(_ v: Double) -> String {
        guard v.isFinite else { return "-" }
        let clamped = min(max(v, 0.0), 100.0)
        let rounded = Int(clamped.rounded())
        return "\(rounded)%"
    }

    public static func tokens(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func usd(_ v: Double) -> String {
        String(format: "$%.2f", v)
    }

    public static func quotaLine(_ q: WidgetQuota) -> String {
        "\(q.provider.rawValue) \(q.label)  \(percent(q.usedPercent))"
    }
}
