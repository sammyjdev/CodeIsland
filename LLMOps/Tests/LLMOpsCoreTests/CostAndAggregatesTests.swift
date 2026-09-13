import Foundation
import Testing
import CodeIslandCore
@testable import LLMOpsCore

@Suite("CostAndAggregatesTests")
struct CostAndAggregatesTests {
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private func isoDate(_ str: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")!
        if let d = f.date(from: str) { return d }
        let plain = ISO8601DateFormatter()
        plain.timeZone = TimeZone(identifier: "UTC")!
        return plain.date(from: str)!
    }

    // 1. CostTable.estimate with usage 1M/1M/1M/1M and a known model equals the sum of its four prices; isFallback == false.
    @Test func estimateWithKnownModelEqualsSumOfPrices() {
        var usage = ClaudeUsageTotals()
        usage.inputTokens = 1_000_000
        usage.outputTokens = 1_000_000
        usage.cacheCreationTokens = 1_000_000
        usage.cacheReadTokens = 1_000_000

        let model = "claude-sonnet-5"
        let estimate = CostTable.estimate(usage, model: model)
        let price = CostTable.prices[model]!
        let expectedUSD = price.inputPerM + price.outputPerM + price.cacheWritePerM + price.cacheReadPerM

        #expect(abs(estimate.usd - expectedUSD) < 0.0001)
        #expect(estimate.isFallback == false)
    }

    // 2. Prefix match: model "claude-opus-5-20270101" resolves to the "claude-opus" prefix price (not fallback); an unknown "gpt-x" uses the fallback price and isFallback == true.
    @Test func prefixMatchAndFallbackResolution() {
        let (opusPrice, opusFallback) = CostTable.price(for: "claude-opus-5-20270101")
        let opusExpected = CostTable.prices["claude-opus"]!
        #expect(opusPrice == opusExpected)
        #expect(opusFallback == false)

        let (fallbackPrice, isFallback) = CostTable.price(for: "gpt-x")
        let expectedFallback = ModelPrice(inputPerM: 3, outputPerM: 15, cacheWritePerM: 3.75, cacheReadPerM: 0.30)
        #expect(fallbackPrice == expectedFallback)
        #expect(isFallback == true)
    }

    // 3. sessionCost sums per-turn estimates by turn model; a turn with nil model uses session.model.
    @Test func sessionCostSumsPerTurnEstimatesWithModelFallback() {
        var turn1Usage = ClaudeUsageTotals()
        turn1Usage.inputTokens = 100_000
        turn1Usage.outputTokens = 20_000
        let turn1 = Turn(
            id: "turn-1",
            startedAt: isoDate("2026-09-15T10:00:00Z"),
            model: "claude-opus-5",
            usage: turn1Usage
        )

        var turn2Usage = ClaudeUsageTotals()
        turn2Usage.inputTokens = 200_000
        turn2Usage.outputTokens = 40_000
        let turn2 = Turn(
            id: "turn-2",
            startedAt: isoDate("2026-09-15T10:05:00Z"),
            model: nil, // Should fallback to session.model
            usage: turn2Usage
        )

        let sessionModel = "claude-sonnet-5"
        let session = Session(
            id: "session-1",
            profile: "default",
            filePath: "/tmp/fake.jsonl",
            model: sessionModel,
            startedAt: isoDate("2026-09-15T10:00:00Z"),
            lastActivity: isoDate("2026-09-15T10:05:00Z"),
            turns: [turn1, turn2],
            usage: turn1Usage + turn2Usage
        )

        let turn1Expected = CostTable.estimate(turn1Usage, model: "claude-opus-5")
        let turn2Expected = CostTable.estimate(turn2Usage, model: sessionModel)
        let totalExpected = turn1Expected.usd + turn2Expected.usd

        let sessionEstimate = Aggregates.sessionCost(session)
        #expect(abs(sessionEstimate.usd - totalExpected) < 0.00001)
        #expect(sessionEstimate.isFallback == false)
    }

    // 4. perDay(days: 3) for sessions on day D-2 and D returns 3 entries oldest first with the middle one zero-filled; cacheReadRatio is 0 for the empty day and correct (cacheRead / (input + cacheRead + cacheWrite)) for a filled day.
    @Test func perDayReturnsZeroFilledEntriesAndCorrectCacheReadRatio() {
        let cal = utcCalendar
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 14, minute: 0, second: 0))!

        // Day D-2: 2026-09-13
        var d2Usage = ClaudeUsageTotals()
        d2Usage.inputTokens = 100
        d2Usage.outputTokens = 50
        d2Usage.cacheCreationTokens = 200
        d2Usage.cacheReadTokens = 700
        let sessionD2 = Session(
            id: "session-d2",
            profile: "default",
            filePath: "/tmp/d2.jsonl",
            model: "claude-sonnet-5",
            startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10, minute: 0, second: 0))!,
            lastActivity: cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10, minute: 5, second: 0))!,
            turns: [
                Turn(id: "t1", startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10, minute: 0, second: 0))!, model: "claude-sonnet-5", usage: d2Usage)
            ],
            usage: d2Usage
        )

        // Day D: 2026-09-15
        var dUsage = ClaudeUsageTotals()
        dUsage.inputTokens = 50
        dUsage.outputTokens = 50
        let sessionD = Session(
            id: "session-d",
            profile: "default",
            filePath: "/tmp/d.jsonl",
            model: "claude-sonnet-5",
            startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 8, minute: 0, second: 0))!,
            lastActivity: cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 8, minute: 2, second: 0))!,
            turns: [
                Turn(id: "t2", startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 8, minute: 0, second: 0))!, model: "claude-sonnet-5", usage: dUsage)
            ],
            usage: dUsage
        )

        let days = Aggregates.perDay([sessionD2, sessionD], days: 3, now: now, calendar: cal)
        #expect(days.count == 3)

        // Oldest first: D-2, D-1, D
        let dayD2Start = cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 0, minute: 0, second: 0))!
        let dayD1Start = cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 0, minute: 0, second: 0))!
        let dayDStart = cal.date(from: DateComponents(year: 2026, month: 9, day: 15, hour: 0, minute: 0, second: 0))!

        #expect(days[0].day == dayD2Start)
        #expect(days[0].usage.inputTokens == 100)
        let expectedRatioD2 = 700.0 / (100.0 + 700.0 + 200.0) // 0.7
        #expect(abs(days[0].cacheReadRatio - expectedRatioD2) < 0.0001)

        // Middle day D-1 is zero-filled
        #expect(days[1].day == dayD1Start)
        #expect(days[1].usage.inputTokens == 0)
        #expect(days[1].costUSD == 0.0)
        #expect(days[1].cacheReadRatio == 0.0)

        // Current day D
        #expect(days[2].day == dayDStart)
        #expect(days[2].usage.inputTokens == 50)
    }

    // 5. perProject(top: 2) over 3 projects returns the 2 largest by total tokens, descending, with correct session counts; tie broken by key ascending.
    @Test func perProjectRanksDescendingAndBreaksTiesByKeyAscending() {
        // 3 projects:
        // Project "gamma": 1 session with 500 total tokens
        // Project "beta": 2 sessions with 500 tokens each (1000 total tokens)
        // Project "alpha": 1 session with 1000 total tokens
        // Top 2 by total tokens descending: "alpha" (1000) and "beta" (1000) tie, so "alpha" < "beta" key ascending.
        // "gamma" (500) is 3rd and excluded.

        var usageAlpha = ClaudeUsageTotals()
        usageAlpha.inputTokens = 1000
        let sAlpha = Session(
            id: "s-alpha",
            profile: "default",
            filePath: "/tmp/a.jsonl",
            project: "alpha",
            startedAt: isoDate("2026-09-15T01:00:00Z"),
            lastActivity: isoDate("2026-09-15T01:10:00Z"),
            usage: usageAlpha
        )

        var usageBeta1 = ClaudeUsageTotals()
        usageBeta1.inputTokens = 300
        let sBeta1 = Session(
            id: "s-beta-1",
            profile: "default",
            filePath: "/tmp/b1.jsonl",
            project: "beta",
            startedAt: isoDate("2026-09-15T02:00:00Z"),
            lastActivity: isoDate("2026-09-15T02:10:00Z"),
            usage: usageBeta1
        )

        var usageBeta2 = ClaudeUsageTotals()
        usageBeta2.outputTokens = 700
        let sBeta2 = Session(
            id: "s-beta-2",
            profile: "default",
            filePath: "/tmp/b2.jsonl",
            project: "beta",
            startedAt: isoDate("2026-09-15T03:00:00Z"),
            lastActivity: isoDate("2026-09-15T03:10:00Z"),
            usage: usageBeta2
        )

        var usageGamma = ClaudeUsageTotals()
        usageGamma.inputTokens = 500
        let sGamma = Session(
            id: "s-gamma",
            profile: "default",
            filePath: "/tmp/g.jsonl",
            project: "gamma",
            startedAt: isoDate("2026-09-15T04:00:00Z"),
            lastActivity: isoDate("2026-09-15T04:10:00Z"),
            usage: usageGamma
        )

        let topProjects = Aggregates.perProject([sGamma, sBeta1, sAlpha, sBeta2], top: 2)
        #expect(topProjects.count == 2)
        #expect(topProjects[0].key == "alpha")
        #expect(topProjects[0].sessions == 1)
        let alphaTotal = topProjects[0].usage.inputTokens + topProjects[0].usage.outputTokens
        #expect(alphaTotal == 1000)

        #expect(topProjects[1].key == "beta")
        #expect(topProjects[1].sessions == 2)
        let betaTotal = topProjects[1].usage.inputTokens + topProjects[1].usage.outputTokens
        #expect(betaTotal == 1000)
    }

    // 6. perModel groups nil model under "unknown".
    @Test func perModelGroupsNilUnderUnknown() {
        let s1 = Session(
            id: "s1",
            profile: "p1",
            filePath: "/tmp/s1.jsonl",
            model: nil,
            startedAt: isoDate("2026-09-15T01:00:00Z"),
            lastActivity: isoDate("2026-09-15T01:10:00Z")
        )
        let s2 = Session(
            id: "s2",
            profile: "p1",
            filePath: "/tmp/s2.jsonl",
            model: nil,
            startedAt: isoDate("2026-09-15T02:00:00Z"),
            lastActivity: isoDate("2026-09-15T02:10:00Z")
        )
        let s3 = Session(
            id: "s3",
            profile: "p1",
            filePath: "/tmp/s3.jsonl",
            model: "claude-sonnet-5",
            startedAt: isoDate("2026-09-15T03:00:00Z"),
            lastActivity: isoDate("2026-09-15T03:10:00Z")
        )

        let models = Aggregates.perModel([s1, s2, s3])
        let unknownBucket = models.first { $0.key == "unknown" }
        #expect(unknownBucket != nil)
        #expect(unknownBucket?.sessions == 2)

        let sonnetBucket = models.first { $0.key == "claude-sonnet-5" }
        #expect(sonnetBucket != nil)
        #expect(sonnetBucket?.sessions == 1)
    }

    // 7. todayCost counts only sessions starting on now's day; weekCost counts a session from the Monday of now's ISO week and excludes one from the previous Sunday.
    @Test func todayCostAndWeekCostBoundaries() {
        let cal = utcCalendar
        // 2026-09-16 is Wednesday
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12, minute: 0, second: 0))!

        var usage = ClaudeUsageTotals()
        usage.inputTokens = 1_000_000
        let price = CostTable.prices["claude-sonnet-5"]!
        let costPerSession = price.inputPerM

        // Wednesday (today)
        let sessionToday = Session(
            id: "s-today",
            profile: "p1",
            filePath: "/tmp/today.jsonl",
            model: "claude-sonnet-5",
            startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 8, minute: 0, second: 0))!,
            lastActivity: cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 8, minute: 5, second: 0))!,
            turns: [
                Turn(id: "t-today", startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 8, minute: 0, second: 0))!, model: "claude-sonnet-5", usage: usage)
            ],
            usage: usage
        )

        // Monday of same ISO week: 2026-09-14
        let sessionMonday = Session(
            id: "s-monday",
            profile: "p1",
            filePath: "/tmp/monday.jsonl",
            model: "claude-sonnet-5",
            startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 0, second: 0))!,
            lastActivity: cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 5, second: 0))!,
            turns: [
                Turn(id: "t-mon", startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 0, second: 0))!, model: "claude-sonnet-5", usage: usage)
            ],
            usage: usage
        )

        // Sunday of previous ISO week: 2026-09-13
        let sessionPrevSunday = Session(
            id: "s-sunday",
            profile: "p1",
            filePath: "/tmp/sunday.jsonl",
            model: "claude-sonnet-5",
            startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 23, minute: 0, second: 0))!,
            lastActivity: cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 23, minute: 5, second: 0))!,
            turns: [
                Turn(id: "t-sun", startedAt: cal.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 23, minute: 0, second: 0))!, model: "claude-sonnet-5", usage: usage)
            ],
            usage: usage
        )

        let allSessions = [sessionToday, sessionMonday, sessionPrevSunday]

        let todayCost = Aggregates.todayCost(allSessions, now: now, calendar: cal)
        #expect(abs(todayCost - costPerSession) < 0.0001)

        let weekCost = Aggregates.weekCost(allSessions, now: now, calendar: cal)
        #expect(abs(weekCost - (costPerSession * 2)) < 0.0001)
    }

    // 8. WindowUsage.snapshot over two temp config dirs (each with projects/p/x.jsonl containing one assistant line with usage at now - 1h) sums last5h.outputTokens across both profiles and hourlyOutputTokens element-wise; the caches dictionary ends with one entry per profile.
    @Test func windowUsageSnapshotAggregatesAcrossProfiles() throws {
        let fm = FileManager.default
        let tempDir1 = NSTemporaryDirectory() + "window-p1-" + UUID().uuidString
        let tempDir2 = NSTemporaryDirectory() + "window-p2-" + UUID().uuidString

        defer {
            try? fm.removeItem(atPath: tempDir1)
            try? fm.removeItem(atPath: tempDir2)
        }

        try fm.createDirectory(atPath: tempDir1 + "/projects/p", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: tempDir2 + "/projects/p", withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let oneHourAgo = now.addingTimeInterval(-3600)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oneHourAgoStr = isoFormatter.string(from: oneHourAgo)

        let line1 = """
        {"type":"assistant","timestamp":"\(oneHourAgoStr)","message":{"id":"msg-p1","role":"assistant","usage":{"input_tokens":100,"output_tokens":15,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
        let line2 = """
        {"type":"assistant","timestamp":"\(oneHourAgoStr)","message":{"id":"msg-p2","role":"assistant","usage":{"input_tokens":200,"output_tokens":25,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """

        let file1 = tempDir1 + "/projects/p/x.jsonl"
        let file2 = tempDir2 + "/projects/p/x.jsonl"
        try (line1 + "\n").write(toFile: file1, atomically: true, encoding: .utf8)
        try (line2 + "\n").write(toFile: file2, atomically: true, encoding: .utf8)

        let p1 = Profile(id: "prof-1", name: "Profile 1", configDir: tempDir1, pathPrefixes: [])
        let p2 = Profile(id: "prof-2", name: "Profile 2", configDir: tempDir2, pathPrefixes: [])

        var caches: [String: ClaudeUsageScanner.FileCache] = [:]
        let usage = WindowUsage.snapshot(profiles: [p1, p2], now: now, caches: &caches)

        #expect(caches.count == 2)
        #expect(caches["prof-1"] != nil)
        #expect(caches["prof-2"] != nil)

        // 15 + 25 = 40 output tokens in last 5h
        #expect(usage.last5h.outputTokens == 40)
        #expect(usage.today.outputTokens == 40)

        // hourlyOutputTokens element-wise sum (index ClaudeUsageScanner.sparklineHours - 1 - 1 = 10)
        let lastIdx = ClaudeUsageScanner.sparklineHours - 1
        #expect(usage.hourlyOutputTokens[lastIdx - 1] == 40)
    }
}
