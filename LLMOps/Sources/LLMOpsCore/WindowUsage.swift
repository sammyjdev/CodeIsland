import Foundation
import CodeIslandCore

public struct WindowUsage: Equatable, Sendable {
    public let last5h: ClaudeUsageTotals
    public let today: ClaudeUsageTotals
    public let hourlyOutputTokens: [Int] // element-wise sum across profiles
    public let scannedAt: Date

    public init(
        last5h: ClaudeUsageTotals,
        today: ClaudeUsageTotals,
        hourlyOutputTokens: [Int],
        scannedAt: Date
    ) {
        self.last5h = last5h
        self.today = today
        self.hourlyOutputTokens = hourlyOutputTokens
        self.scannedAt = scannedAt
    }

    /// Calls `ClaudeUsageScanner.scan(claudeHome: profile.expandedConfigDir, now: now, cache: &cache[profile.id])`
    /// for every profile and sums the snapshots. `caches` is keyed by profile id and
    /// created on demand.
    public static func snapshot(
        profiles: [Profile],
        now: Date,
        caches: inout [String: ClaudeUsageScanner.FileCache]
    ) -> WindowUsage {
        var totalLast5h = ClaudeUsageTotals()
        var totalToday = ClaudeUsageTotals()
        var totalHourly = [Int](repeating: 0, count: ClaudeUsageScanner.sparklineHours)

        for profile in profiles {
            var cache = caches[profile.id] ?? ClaudeUsageScanner.FileCache()
            let snap = ClaudeUsageScanner.scan(
                claudeHome: profile.expandedConfigDir,
                now: now,
                cache: &cache
            )
            caches[profile.id] = cache

            totalLast5h = totalLast5h + snap.last5h
            totalToday = totalToday + snap.today
            for i in 0..<min(totalHourly.count, snap.hourlyOutputTokens.count) {
                totalHourly[i] += snap.hourlyOutputTokens[i]
            }
        }

        return WindowUsage(
            last5h: totalLast5h,
            today: totalToday,
            hourlyOutputTokens: totalHourly,
            scannedAt: now
        )
    }
}
