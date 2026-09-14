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

public struct ToolUsage: Identifiable, Equatable, Sendable, Codable {
    public var id: String { name }
    public let name: String
    public let calls: Int
    public let errors: Int
    public let medianDurationMs: Int?   // nil when no call of this tool has a duration

    public init(name: String, calls: Int, errors: Int, medianDurationMs: Int?) {
        self.name = name
        self.calls = calls
        self.errors = errors
        self.medianDurationMs = medianDurationMs
    }
}

public struct UsageShape: Equatable, Sendable, Codable {
    public let sessions: Int
    public let turns: Int
    public let toolCalls: Int
    public let toolErrors: Int
    public let totalTokens: Int          // input + output + cacheCreation + cacheRead over all turns
    public var turnsPerSession: Double { sessions == 0 ? 0 : Double(turns) / Double(sessions) }
    public var tokensPerTurn: Double { turns == 0 ? 0 : Double(totalTokens) / Double(turns) }
    public var toolErrorRate: Double { toolCalls == 0 ? 0 : Double(toolErrors) / Double(toolCalls) }

    public init(sessions: Int, turns: Int, toolCalls: Int, toolErrors: Int, totalTokens: Int) {
        self.sessions = sessions
        self.turns = turns
        self.toolCalls = toolCalls
        self.toolErrors = toolErrors
        self.totalTokens = totalTokens
    }
}

public enum Aggregates {
    /// One entry per day for the last `days` days ending at `now` (inclusive),
    /// oldest first, zero-filled for days without turns. A turn counts on
    /// the day of its `startedAt`.
    public static func perDay(_ sessions: [Session], days: Int, now: Date, calendar: Calendar) -> [DayUsage] {
        guard days > 0 else { return [] }
        let todayStart = calendar.startOfDay(for: now)
        var result: [DayUsage] = []
        result.reserveCapacity(days)

        var turnsByDay: [Date: (usage: ClaudeUsageTotals, costUSD: Double)] = [:]
        for session in sessions {
            for turn in session.turns {
                let day = calendar.startOfDay(for: turn.startedAt)
                var current = turnsByDay[day] ?? (ClaudeUsageTotals(), 0.0)
                current.usage = current.usage + turn.usage
                let model = turn.model ?? session.model
                current.costUSD += CostTable.estimate(turn.usage, model: model).usd
                turnsByDay[day] = current
            }
        }

        for i in 0..<days {
            let offset = -(days - 1 - i)
            guard let rawDayStart = calendar.date(byAdding: .day, value: offset, to: todayStart) else {
                continue
            }
            let dayStart = calendar.startOfDay(for: rawDayStart)

            let entry = turnsByDay[dayStart] ?? (ClaudeUsageTotals(), 0.0)
            let dayUsage = entry.usage
            let dayCost = entry.costUSD

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
        var totalUSD = 0.0
        for session in sessions {
            for turn in session.turns {
                if calendar.startOfDay(for: turn.startedAt) == todayStart {
                    let model = turn.model ?? session.model
                    totalUSD += CostTable.estimate(turn.usage, model: model).usd
                }
            }
        }
        return totalUSD
    }

    /// ISO week (Monday start) containing `now`.
    public static func weekCost(_ sessions: [Session], now: Date, calendar: Calendar) -> Double {
        var isoCalendar = calendar
        isoCalendar.firstWeekday = 2
        guard let interval = isoCalendar.dateInterval(of: .weekOfYear, for: now) else {
            return 0.0
        }
        var totalUSD = 0.0
        for session in sessions {
            for turn in session.turns {
                if turn.startedAt >= interval.start && turn.startedAt < interval.end {
                    let model = turn.model ?? session.model
                    totalUSD += CostTable.estimate(turn.usage, model: model).usd
                }
            }
        }
        return totalUSD
    }
}

extension Aggregates {
    /// One entry per distinct ToolCall.name across every turn of every session.
    /// Sorted by calls descending, ties by name ascending.
    /// medianDurationMs: lower median of the non-nil durationMs values (for an even
    /// count take the smaller of the two middle values); nil when there are none.
    public static func perTool(_ sessions: [Session]) -> [ToolUsage] {
        var grouped: [String: (calls: Int, errors: Int, durations: [Int])] = [:]
        for session in sessions {
            for turn in session.turns {
                for call in turn.toolCalls {
                    var current = grouped[call.name] ?? (calls: 0, errors: 0, durations: [])
                    current.calls += 1
                    if call.isError {
                        current.errors += 1
                    }
                    if let d = call.durationMs {
                        current.durations.append(d)
                    }
                    grouped[call.name] = current
                }
            }
        }

        var usages = grouped.map { name, val -> ToolUsage in
            let median: Int?
            if val.durations.isEmpty {
                median = nil
            } else {
                let sorted = val.durations.sorted()
                let index = (sorted.count - 1) / 2
                median = sorted[index]
            }
            return ToolUsage(
                name: name,
                calls: val.calls,
                errors: val.errors,
                medianDurationMs: median
            )
        }

        usages.sort { a, b in
            if a.calls != b.calls {
                return a.calls > b.calls
            }
            return a.name < b.name
        }

        return usages
    }

    /// Always 24 entries. Entry h is the sum of total tokens (four kinds) of every
    /// turn whose calendar.component(.hour, from: turn.startedAt) == h.
    public static func perHour(_ sessions: [Session], calendar: Calendar) -> [Int] {
        var hourly = Array(repeating: 0, count: 24)
        for session in sessions {
            for turn in session.turns {
                let hour = calendar.component(.hour, from: turn.startedAt)
                if hour >= 0 && hour < 24 {
                    let tokens = turn.usage.inputTokens + turn.usage.outputTokens + turn.usage.cacheCreationTokens + turn.usage.cacheReadTokens
                    hourly[hour] += tokens
                }
            }
        }
        return hourly
    }

    /// sessions.count, total turns, total tool calls, tool calls with isError,
    /// total tokens over all turns.
    public static func shape(_ sessions: [Session]) -> UsageShape {
        let sessionsCount = sessions.count
        var totalTurns = 0
        var totalToolCalls = 0
        var totalToolErrors = 0
        var totalTokens = 0

        for session in sessions {
            totalTurns += session.turns.count
            for turn in session.turns {
                let tokens = turn.usage.inputTokens + turn.usage.outputTokens + turn.usage.cacheCreationTokens + turn.usage.cacheReadTokens
                totalTokens += tokens
                totalToolCalls += turn.toolCalls.count
                for call in turn.toolCalls {
                    if call.isError {
                        totalToolErrors += 1
                    }
                }
            }
        }

        return UsageShape(
            sessions: sessionsCount,
            turns: totalTurns,
            toolCalls: totalToolCalls,
            toolErrors: totalToolErrors,
            totalTokens: totalTokens
        )
    }
}
