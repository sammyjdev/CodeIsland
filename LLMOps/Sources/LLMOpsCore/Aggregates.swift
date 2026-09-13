import Foundation
import CodeIslandCore

public struct DayUsage: Identifiable, Equatable, Sendable {
    public var id: Date { day }
    public let day: Date // start of day in `calendar`
    public let usage: ClaudeUsageTotals
    public let costUSD: Double
    public var cacheReadRatio: Double // cacheRead / (input + cacheRead + cacheWrite), 0 when denominator is 0

    public init(day: Date, usage: ClaudeUsageTotals, costUSD: Double, cacheReadRatio: Double) {
        self.day = day
        self.usage = usage
        self.costUSD = costUSD
        self.cacheReadRatio = cacheReadRatio
    }
}

public struct BucketUsage: Identifiable, Equatable, Sendable {
    public var id: String { key }
    public let key: String // project name or model id
    public let usage: ClaudeUsageTotals
    public let costUSD: Double
    public let sessions: Int

    public init(key: String, usage: ClaudeUsageTotals, costUSD: Double, sessions: Int) {
        self.key = key
        self.usage = usage
        self.costUSD = costUSD
        self.sessions = sessions
    }
}

public enum Aggregates {
    /// One entry per day for the last `days` days ending at `now` (inclusive),
    /// oldest first, zero-filled for days without sessions. A session counts on
    /// the day of its `startedAt`.
    public static func perDay(_ sessions: [Session], days: Int, now: Date, calendar: Calendar) -> [DayUsage] {
        guard days > 0 else { return [] }
        let todayStart = calendar.startOfDay(for: now)
        var result: [DayUsage] = []
        result.reserveCapacity(days)

        for i in 0..<days {
            let offset = -(days - 1 - i)
            guard let dayStart = calendar.date(byAdding: .day, value: offset, to: todayStart) else {
                continue
            }

            let sessionsOnDay = sessions.filter { session in
                calendar.startOfDay(for: session.startedAt) == dayStart
            }

            var dayUsage = ClaudeUsageTotals()
            var dayCost = 0.0

            for s in sessionsOnDay {
                dayUsage = dayUsage + s.usage
                dayCost += sessionCost(s).usd
            }

            let denom = Double(dayUsage.inputTokens + dayUsage.cacheReadTokens + dayUsage.cacheCreationTokens)
            let cacheReadRatio = denom > 0 ? Double(dayUsage.cacheReadTokens) / denom : 0.0

            result.append(DayUsage(
                day: dayStart,
                usage: dayUsage,
                costUSD: dayCost,
                cacheReadRatio: cacheReadRatio
            ))
        }

        return result
    }

    /// Top `top` projects by total tokens (input+output+cacheWrite+cacheRead), descending; ties by key.
    public static func perProject(_ sessions: [Session], top: Int) -> [BucketUsage] {
        guard top > 0 else { return [] }
        var grouped: [String: (usage: ClaudeUsageTotals, cost: Double, count: Int)] = [:]
        for s in sessions {
            let key = s.project
            var current = grouped[key] ?? (ClaudeUsageTotals(), 0.0, 0)
            current.usage = current.usage + s.usage
            current.cost += sessionCost(s).usd
            current.count += 1
            grouped[key] = current
        }

        var buckets = grouped.map { key, val in
            BucketUsage(key: key, usage: val.usage, costUSD: val.cost, sessions: val.count)
        }

        buckets.sort { a, b in
            let aTokens = a.usage.inputTokens + a.usage.outputTokens + a.usage.cacheCreationTokens + a.usage.cacheReadTokens
            let bTokens = b.usage.inputTokens + b.usage.outputTokens + b.usage.cacheCreationTokens + b.usage.cacheReadTokens
            if aTokens != bTokens {
                return aTokens > bTokens
            }
            return a.key < b.key
        }

        return Array(buckets.prefix(top))
    }

    /// key = session.model ?? "unknown"
    public static func perModel(_ sessions: [Session]) -> [BucketUsage] {
        var grouped: [String: (usage: ClaudeUsageTotals, cost: Double, count: Int)] = [:]
        for s in sessions {
            let key = s.model ?? "unknown"
            var current = grouped[key] ?? (ClaudeUsageTotals(), 0.0, 0)
            current.usage = current.usage + s.usage
            current.cost += sessionCost(s).usd
            current.count += 1
            grouped[key] = current
        }

        var buckets = grouped.map { key, val in
            BucketUsage(key: key, usage: val.usage, costUSD: val.cost, sessions: val.count)
        }

        buckets.sort { a, b in
            let aTokens = a.usage.inputTokens + a.usage.outputTokens + a.usage.cacheCreationTokens + a.usage.cacheReadTokens
            let bTokens = b.usage.inputTokens + b.usage.outputTokens + b.usage.cacheCreationTokens + b.usage.cacheReadTokens
            if aTokens != bTokens {
                return aTokens > bTokens
            }
            return a.key < b.key
        }

        return buckets
    }

    /// sums per-turn estimates using each turn's model (falls back to session.model)
    public static func sessionCost(_ session: Session) -> CostEstimate {
        if session.turns.isEmpty {
            return CostTable.estimate(session.usage, model: session.model)
        }
        var totalUSD = 0.0
        var hasFallback = false
        for turn in session.turns {
            let model = turn.model ?? session.model
            let est = CostTable.estimate(turn.usage, model: model)
            totalUSD += est.usd
            if est.isFallback {
                hasFallback = true
            }
        }
        return CostEstimate(usd: totalUSD, isFallback: hasFallback)
    }

    public static func todayCost(_ sessions: [Session], now: Date, calendar: Calendar) -> Double {
        let todayStart = calendar.startOfDay(for: now)
        let sessionsToday = sessions.filter {
            calendar.startOfDay(for: $0.startedAt) == todayStart
        }
        return sessionsToday.reduce(0.0) { $0 + sessionCost($1).usd }
    }

    /// ISO week (Monday start) containing `now`.
    public static func weekCost(_ sessions: [Session], now: Date, calendar: Calendar) -> Double {
        var isoCalendar = calendar
        isoCalendar.firstWeekday = 2
        guard let interval = isoCalendar.dateInterval(of: .weekOfYear, for: now) else {
            return 0.0
        }
        let sessionsThisWeek = sessions.filter {
            $0.startedAt >= interval.start && $0.startedAt < interval.end
        }
        return sessionsThisWeek.reduce(0.0) { $0 + sessionCost($1).usd }
    }
}
