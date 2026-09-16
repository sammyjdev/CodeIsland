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

    public static func resetsIn(_ date: Date?, now: Date) -> String? {
        guard let date, date > now else { return nil }
        let totalSeconds = Int(date.timeIntervalSince(now))
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let totalHours = totalMinutes / 60
        if totalHours < 24 {
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return "\(totalHours)h"
            }
            return "\(totalHours)h \(minutes)m"
        }
        let days = totalHours / 24
        let hours = totalHours % 24
        if hours == 0 {
            return "\(days)d"
        }
        return "\(days)d \(hours)h"
    }

    public static func grouped(_ quotas: [WidgetQuota]) -> [(provider: QuotaProviderID, quotas: [WidgetQuota])] {
        QuotaProviderID.allCases.compactMap { provider in
            let matching = quotas.filter { $0.provider == provider }
            guard !matching.isEmpty else { return nil }
            return (provider: provider, quotas: matching)
        }
    }

    public static func worstPercent(_ quotas: [WidgetQuota]) -> Double {
        quotas.map(\.usedPercent).max() ?? 0.0
    }

    public static func providerName(_ id: QuotaProviderID) -> String {
        switch id {
        case .antigravity:
            return "agy"
        case .zai:
            return "z.ai"
        default:
            return id.rawValue
        }
    }
}
