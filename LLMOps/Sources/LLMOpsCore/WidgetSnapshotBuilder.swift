import Foundation
import CodeIslandCore

public enum WidgetSnapshotBuilder {
    /// One WidgetQuota per window of every successful snapshot, in QuotaProviderID.allCases order,
    /// windows in their original order. Failed providers contribute nothing.
    public static func quotas(from results: [QuotaProviderID: Result<QuotaSnapshot, QuotaError>]) -> [WidgetQuota] {
        var quotas: [WidgetQuota] = []
        for provider in QuotaProviderID.allCases {
            guard let result = results[provider],
                  case .success(let snapshot) = result else {
                continue
            }
            for window in snapshot.windows {
                quotas.append(WidgetQuota(
                    provider: provider,
                    label: window.label,
                    usedPercent: window.usedPercent,
                    resetsAt: window.resetsAt
                ))
            }
        }
        return quotas
    }

    /// sessions = count of sessions with at least one turn started today; tokens = sum over those
    /// turns of input + output + cacheCreation + cacheRead; costUSD = Aggregates.todayCost.
    public static func today(_ sessions: [Session], now: Date, calendar: Calendar) -> TodaySummary {
        let todayStart = calendar.startOfDay(for: now)
        var todaySessionsCount = 0
        var totalTokens = 0

        for session in sessions {
            var sessionHasTurnToday = false
            for turn in session.turns {
                if calendar.startOfDay(for: turn.startedAt) == todayStart {
                    sessionHasTurnToday = true
                    totalTokens += turn.usage.inputTokens
                        + turn.usage.outputTokens
                        + turn.usage.cacheCreationTokens
                        + turn.usage.cacheReadTokens
                }
            }
            if sessionHasTurnToday {
                todaySessionsCount += 1
            }
        }

        let costUSD = Aggregates.todayCost(sessions, now: now, calendar: calendar)
        return TodaySummary(sessions: todaySessionsCount, tokens: totalTokens, costUSD: costUSD)
    }

    /// cpuPercent and memoryUsedPercent (0...100) from the sample; batteryPercent from the sample's
    /// battery when present. Read SystemSampler.swift for the exact field names.
    public static func system(_ sample: SystemSample) -> SystemSummary {
        let memoryUsedPercent = sample.memory.total > 0
            ? (Double(sample.memory.used) / Double(sample.memory.total)) * 100.0
            : 0.0
        let batteryPercent = sample.battery.map { Double($0.percent) }
        return SystemSummary(
            cpuPercent: sample.cpuPercent,
            memoryUsedPercent: memoryUsedPercent,
            batteryPercent: batteryPercent
        )
    }
}
