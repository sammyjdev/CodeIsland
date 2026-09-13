import Foundation
import CodeIslandCore
import LLMOpsCore

struct AnalyticsSnapshot: Equatable {
    let window: WindowUsage                 // from WindowUsage.snapshot
    let perDay: [DayUsage]                  // Aggregates.perDay(days: 30)
    let perProject: [BucketUsage]           // Aggregates.perProject(top: 8)
    let perModel: [BucketUsage]             // Aggregates.perModel
    let todayCostUSD: Double
    let weekCostUSD: Double
    let sessionCount: Int
    let sourceLine: String                  // "src: <configDir list joined by ", ">, n=<sessionCount> sessions"
}

enum AnalyticsViewModel {
    /// Pure composition over already-scanned sessions plus a window snapshot.
    static func build(
        sessions: [Session],
        profiles: [Profile],
        window: WindowUsage,
        now: Date,
        calendar: Calendar
    ) -> AnalyticsSnapshot {
        let perDay = Aggregates.perDay(sessions, days: 30, now: now, calendar: calendar)
        let perProject = Aggregates.perProject(sessions, top: 8)
        let perModel = Aggregates.perModel(sessions)
        let todayCost = Aggregates.todayCost(sessions, now: now, calendar: calendar)
        let weekCost = Aggregates.weekCost(sessions, now: now, calendar: calendar)
        let count = sessions.count

        let configDirs = profiles.map(\.configDir).joined(separator: ", ")
        let sourceLine = configDirs.isEmpty
            ? "src: n=\(count) sessions"
            : "src: \(configDirs), n=\(count) sessions"

        return AnalyticsSnapshot(
            window: window,
            perDay: perDay,
            perProject: perProject,
            perModel: perModel,
            todayCostUSD: todayCost,
            weekCostUSD: weekCost,
            sessionCount: count,
            sourceLine: sourceLine
        )
    }

    /// Stacked series for the per-day chart: one point per (day, kind) with kind in
    /// ["input", "output", "cache read", "cache write"], in that order per day.
    static func dailySeries(_ perDay: [DayUsage]) -> [DailyPoint] {
        var points: [DailyPoint] = []
        points.reserveCapacity(perDay.count * 4)
        for day in perDay {
            points.append(DailyPoint(day: day.day, kind: "input", tokens: day.usage.inputTokens))
            points.append(DailyPoint(day: day.day, kind: "output", tokens: day.usage.outputTokens))
            points.append(DailyPoint(day: day.day, kind: "cache read", tokens: day.usage.cacheReadTokens))
            points.append(DailyPoint(day: day.day, kind: "cache write", tokens: day.usage.cacheCreationTokens))
        }
        return points
    }

    /// Ratio series for the cache chart: (day, ratio 0...1).
    static func cacheSeries(_ perDay: [DayUsage]) -> [RatioPoint] {
        perDay.map { RatioPoint(day: $0.day, ratio: $0.cacheReadRatio) }
    }
}

struct DailyPoint: Identifiable, Equatable {
    var id: String { "\(day.timeIntervalSince1970)-\(kind)" }
    let day: Date
    let kind: String
    let tokens: Int
}

struct RatioPoint: Identifiable, Equatable {
    var id: Date { day }
    let day: Date
    let ratio: Double
}

/// Per-view state (ObservableObject, see toolchain rule): holds the latest
/// snapshot and the WindowUsage caches between refreshes.
@MainActor
final class AnalyticsState: ObservableObject {
    @Published var snapshot: AnalyticsSnapshot?
    var windowCaches: [String: ClaudeUsageScanner.FileCache] = [:]

    private var currentRefreshTask: Task<Void, Never>?

    /// Runs WindowUsage.snapshot on a background task, then build(...) on the main actor.
    @discardableResult
    func refresh(
        sessions: [Session],
        profiles: [Profile],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Task<Void, Never> {
        currentRefreshTask?.cancel()
        let currentCaches = self.windowCaches
        let task = Task {
            let (window, newCaches) = await Task.detached {
                var cachesCopy = currentCaches
                let win = WindowUsage.snapshot(profiles: profiles, now: now, caches: &cachesCopy)
                return (win, cachesCopy)
            }.value

            guard !Task.isCancelled else { return }
            self.windowCaches = newCaches
            let snap = AnalyticsViewModel.build(
                sessions: sessions,
                profiles: profiles,
                window: window,
                now: now,
                calendar: calendar
            )
            self.snapshot = snap
        }
        currentRefreshTask = task
        return task
    }

    func refreshNow(
        sessions: [Session],
        profiles: [Profile],
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        await refresh(sessions: sessions, profiles: profiles, now: now, calendar: calendar).value
    }
}

// Note: HistoryFormat is missing from this workspace (Task 9 not yet merged),
// so tokens and usd formatters are implemented here as helper functions.
func tokens(_ count: Int) -> String {
    ClaudeUsageScanner.formatTokens(count)
}

func usd(_ amount: Double) -> String {
    String(format: "$%.2f", amount)
}
