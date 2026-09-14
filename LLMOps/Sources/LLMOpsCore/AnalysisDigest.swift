import Foundation
import CodeIslandCore

public struct AnalysisDigest: Codable, Equatable, Sendable {
    public struct SessionRow: Codable, Equatable, Sendable {
        public let id: String
        public let title: String          // session.title ?? "" truncated to 80 characters
        public let project: String
        public let model: String          // session.model ?? "unknown"
        public let startedAt: Date
        public let turns: Int
        public let totalTokens: Int       // four kinds summed from session.usage
        public let toolCalls: Int
        public let toolErrors: Int
        public let cacheReadRatio: Double // cacheRead / (input + cacheRead + cacheWrite), 0 when denominator 0
        public let costUSD: Double        // Aggregates.sessionCost(session).usd

        public init(
            id: String,
            title: String,
            project: String,
            model: String,
            startedAt: Date,
            turns: Int,
            totalTokens: Int,
            toolCalls: Int,
            toolErrors: Int,
            cacheReadRatio: Double,
            costUSD: Double
        ) {
            self.id = id
            self.title = title
            self.project = project
            self.model = model
            self.startedAt = startedAt
            self.turns = turns
            self.totalTokens = totalTokens
            self.toolCalls = toolCalls
            self.toolErrors = toolErrors
            self.cacheReadRatio = cacheReadRatio
            self.costUSD = costUSD
        }
    }

    public struct DayRow: Codable, Equatable, Sendable {
        public let day: Date
        public let totalTokens: Int
        public let costUSD: Double
        public let cacheReadRatio: Double

        public init(
            day: Date,
            totalTokens: Int,
            costUSD: Double,
            cacheReadRatio: Double
        ) {
            self.day = day
            self.totalTokens = totalTokens
            self.costUSD = costUSD
            self.cacheReadRatio = cacheReadRatio
        }
    }

    public struct BucketRow: Codable, Equatable, Sendable {
        public let key: String
        public let totalTokens: Int
        public let sessions: Int
        public let costUSD: Double

        public init(
            key: String,
            totalTokens: Int,
            sessions: Int,
            costUSD: Double
        ) {
            self.key = key
            self.totalTokens = totalTokens
            self.sessions = sessions
            self.costUSD = costUSD
        }
    }

    public let generatedAt: Date
    public let profile: String?          // nil means all profiles
    public let periodDays: Int
    public let sessionCount: Int
    public let totals: BucketRow         // key "total", sums over every session
    public let days: [DayRow]            // Aggregates.perDay(days: periodDays), oldest first
    public let projects: [BucketRow]     // Aggregates.perProject(top: 8)
    public let models: [BucketRow]       // Aggregates.perModel
    public let tools: [ToolUsage]        // Aggregates.perTool, first 15
    public let shape: UsageShape
    public let topByCost: [SessionRow]   // 10 sessions with highest costUSD, desc, ties by id asc
    public let topByErrors: [SessionRow] // sessions with toolErrors > 0, by toolErrors desc, ties by id asc, first 10

    public init(
        generatedAt: Date,
        profile: String?,
        periodDays: Int,
        sessionCount: Int,
        totals: BucketRow,
        days: [DayRow],
        projects: [BucketRow],
        models: [BucketRow],
        tools: [ToolUsage],
        shape: UsageShape,
        topByCost: [SessionRow],
        topByErrors: [SessionRow]
    ) {
        self.generatedAt = generatedAt
        self.profile = profile
        self.periodDays = periodDays
        self.sessionCount = sessionCount
        self.totals = totals
        self.days = days
        self.projects = projects
        self.models = models
        self.tools = tools
        self.shape = shape
        self.topByCost = topByCost
        self.topByErrors = topByErrors
    }

    public static func build(
        sessions: [Session],
        profile: String?,
        periodDays: Int,
        now: Date,
        calendar: Calendar
    ) -> AnalysisDigest {
        var totalTokens = 0
        var totalCost = 0.0
        var sessionRows: [SessionRow] = []
        sessionRows.reserveCapacity(sessions.count)

        for session in sessions {
            let rawTitle = session.title ?? ""
            let title = String(rawTitle.prefix(80))
            let project = session.project
            let model = session.model ?? "unknown"
            let startedAt = session.startedAt
            let turns = session.turns.count
            let sTokens = session.usage.inputTokens + session.usage.outputTokens + session.usage.cacheCreationTokens + session.usage.cacheReadTokens
            totalTokens += sTokens

            var toolCalls = 0
            var toolErrors = 0
            for turn in session.turns {
                toolCalls += turn.toolCalls.count
                for call in turn.toolCalls {
                    if call.isError {
                        toolErrors += 1
                    }
                }
            }

            let denom = Double(session.usage.inputTokens + session.usage.cacheReadTokens + session.usage.cacheCreationTokens)
            let cacheReadRatio = denom > 0 ? Double(session.usage.cacheReadTokens) / denom : 0.0
            let costUSD = Aggregates.sessionCost(session).usd
            totalCost += costUSD

            sessionRows.append(SessionRow(
                id: session.id,
                title: title,
                project: project,
                model: model,
                startedAt: startedAt,
                turns: turns,
                totalTokens: sTokens,
                toolCalls: toolCalls,
                toolErrors: toolErrors,
                cacheReadRatio: cacheReadRatio,
                costUSD: costUSD
            ))
        }

        let totals = BucketRow(
            key: "total",
            totalTokens: totalTokens,
            sessions: sessions.count,
            costUSD: totalCost
        )

        let perDay = Aggregates.perDay(sessions, days: periodDays, now: now, calendar: calendar)
        let days = perDay.map { d in
            let dTokens = d.usage.inputTokens + d.usage.outputTokens + d.usage.cacheCreationTokens + d.usage.cacheReadTokens
            return DayRow(
                day: d.day,
                totalTokens: dTokens,
                costUSD: d.costUSD,
                cacheReadRatio: d.cacheReadRatio
            )
        }

        let perProject = Aggregates.perProject(sessions, top: 8)
        let projects = perProject.map { b in
            let bTokens = b.usage.inputTokens + b.usage.outputTokens + b.usage.cacheCreationTokens + b.usage.cacheReadTokens
            return BucketRow(
                key: b.key,
                totalTokens: bTokens,
                sessions: b.sessions,
                costUSD: b.costUSD
            )
        }

        let perModel = Aggregates.perModel(sessions)
        let models = perModel.map { b in
            let bTokens = b.usage.inputTokens + b.usage.outputTokens + b.usage.cacheCreationTokens + b.usage.cacheReadTokens
            return BucketRow(
                key: b.key,
                totalTokens: bTokens,
                sessions: b.sessions,
                costUSD: b.costUSD
            )
        }

        let tools = Array(Aggregates.perTool(sessions).prefix(15))
        let shape = Aggregates.shape(sessions)

        let topByCost = Array(sessionRows.sorted { a, b in
            if a.costUSD != b.costUSD {
                return a.costUSD > b.costUSD
            }
            return a.id < b.id
        }.prefix(10))

        let topByErrors = Array(sessionRows.filter { $0.toolErrors > 0 }.sorted { a, b in
            if a.toolErrors != b.toolErrors {
                return a.toolErrors > b.toolErrors
            }
            return a.id < b.id
        }.prefix(10))

        return AnalysisDigest(
            generatedAt: now,
            profile: profile,
            periodDays: periodDays,
            sessionCount: sessions.count,
            totals: totals,
            days: days,
            projects: projects,
            models: models,
            tools: tools,
            shape: shape,
            topByCost: topByCost,
            topByErrors: topByErrors
        )
    }

    /// JSON with ISO 8601 dates and sorted keys, no pretty printing.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
