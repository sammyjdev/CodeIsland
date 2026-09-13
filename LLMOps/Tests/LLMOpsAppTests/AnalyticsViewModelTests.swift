import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@Suite("AnalyticsViewModelTests")
struct AnalyticsViewModelTests {
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

    // 1. build over 3 sessions (2 projects, 2 models, two different days) yields
    // sessionCount == 3, perProject.count == 2, perModel.count == 2, perDay.count == 30,
    // and sourceLine contains "n=3".
    @Test func buildAggregatesSessionsAndBuildsSourceLine() {
        let cal = utcCalendar
        let now = isoDate("2026-09-15T14:00:00Z")

        var usage1 = ClaudeUsageTotals()
        usage1.inputTokens = 100
        usage1.outputTokens = 50
        usage1.cacheCreationTokens = 20
        usage1.cacheReadTokens = 10

        var usage2 = ClaudeUsageTotals()
        usage2.inputTokens = 200
        usage2.outputTokens = 100
        usage2.cacheCreationTokens = 40
        usage2.cacheReadTokens = 20

        let s1 = Session(
            id: "s1",
            profile: "prof1",
            filePath: "/fake/s1.jsonl",
            project: "proj-a",
            model: "claude-sonnet-5",
            startedAt: isoDate("2026-09-15T10:00:00Z"),
            lastActivity: isoDate("2026-09-15T10:30:00Z"),
            turns: [],
            usage: usage1
        )
        let s2 = Session(
            id: "s2",
            profile: "prof1",
            filePath: "/fake/s2.jsonl",
            project: "proj-b",
            model: "claude-opus-5",
            startedAt: isoDate("2026-09-15T11:00:00Z"),
            lastActivity: isoDate("2026-09-15T11:30:00Z"),
            turns: [],
            usage: usage2
        )
        let s3 = Session(
            id: "s3",
            profile: "prof2",
            filePath: "/fake/s3.jsonl",
            project: "proj-a",
            model: "claude-sonnet-5",
            startedAt: isoDate("2026-09-14T09:00:00Z"),
            lastActivity: isoDate("2026-09-14T09:30:00Z"),
            turns: [],
            usage: usage1
        )

        let profiles = [
            Profile(id: "prof1", name: "Prof 1", configDir: "~/.claude", pathPrefixes: []),
            Profile(id: "prof2", name: "Prof 2", configDir: "~/.claude-zed", pathPrefixes: [])
        ]
        let window = WindowUsage(
            last5h: usage1,
            today: usage1 + usage2,
            hourlyOutputTokens: [Int](repeating: 0, count: 12),
            scannedAt: now
        )

        let snapshot = AnalyticsViewModel.build(
            sessions: [s1, s2, s3],
            profiles: profiles,
            window: window,
            now: now,
            calendar: cal
        )

        #expect(snapshot.sessionCount == 3)
        #expect(snapshot.perProject.count == 2)
        #expect(snapshot.perModel.count == 2)
        #expect(snapshot.perDay.count == 30)
        #expect(snapshot.sourceLine.contains("n=3"))
    }

    // 2. dailySeries emits exactly 4 points per day in the order input, output,
    // cache read, cache write, with the right token counts for a filled day and zeros
    // for an empty day.
    @Test func dailySeriesEmitsFourPointsPerDayInOrder() {
        let cal = utcCalendar
        let day1 = cal.startOfDay(for: isoDate("2026-09-14T00:00:00Z"))
        let day2 = cal.startOfDay(for: isoDate("2026-09-15T00:00:00Z"))

        var usageFilled = ClaudeUsageTotals()
        usageFilled.inputTokens = 1000
        usageFilled.outputTokens = 500
        usageFilled.cacheReadTokens = 300
        usageFilled.cacheCreationTokens = 200

        let emptyDay = DayUsage(day: day1, usage: ClaudeUsageTotals(), costUSD: 0, cacheReadRatio: 0)
        let filledDay = DayUsage(day: day2, usage: usageFilled, costUSD: 0.05, cacheReadRatio: 0.2)

        let series = AnalyticsViewModel.dailySeries([emptyDay, filledDay])

        #expect(series.count == 8)

        // Empty day points
        #expect(series[0].kind == "input")
        #expect(series[0].tokens == 0)
        #expect(series[0].day == day1)

        #expect(series[1].kind == "output")
        #expect(series[1].tokens == 0)
        #expect(series[1].day == day1)

        #expect(series[2].kind == "cache read")
        #expect(series[2].tokens == 0)
        #expect(series[2].day == day1)

        #expect(series[3].kind == "cache write")
        #expect(series[3].tokens == 0)
        #expect(series[3].day == day1)

        // Filled day points
        #expect(series[4].kind == "input")
        #expect(series[4].tokens == 1000)
        #expect(series[4].day == day2)

        #expect(series[5].kind == "output")
        #expect(series[5].tokens == 500)
        #expect(series[5].day == day2)

        #expect(series[6].kind == "cache read")
        #expect(series[6].tokens == 300)
        #expect(series[6].day == day2)

        #expect(series[7].kind == "cache write")
        #expect(series[7].tokens == 200)
        #expect(series[7].day == day2)
    }

    // 3. cacheSeries yields one point per day with ratio in 0...1 and 0 on empty days.
    @Test func cacheSeriesEmitsOnePointPerDay() {
        let cal = utcCalendar
        let day1 = cal.startOfDay(for: isoDate("2026-09-14T00:00:00Z"))
        let day2 = cal.startOfDay(for: isoDate("2026-09-15T00:00:00Z"))

        let emptyDay = DayUsage(day: day1, usage: ClaudeUsageTotals(), costUSD: 0, cacheReadRatio: 0)
        let filledDay = DayUsage(day: day2, usage: ClaudeUsageTotals(), costUSD: 0.05, cacheReadRatio: 0.42)

        let series = AnalyticsViewModel.cacheSeries([emptyDay, filledDay])

        #expect(series.count == 2)
        #expect(series[0].day == day1)
        #expect(series[0].ratio == 0.0)
        #expect(series[1].day == day2)
        #expect(series[1].ratio == 0.42)
        #expect(series[1].ratio >= 0.0 && series[1].ratio <= 1.0)
    }

    // 4. todayCostUSD / weekCostUSD equal Aggregates.todayCost / weekCost for the same inputs.
    @Test func todayCostAndWeekCostMatchAggregates() {
        let cal = utcCalendar
        let now = isoDate("2026-09-15T14:00:00Z")

        var usage = ClaudeUsageTotals()
        usage.inputTokens = 100_000
        usage.outputTokens = 20_000

        let s1 = Session(
            id: "s1",
            profile: "prof1",
            filePath: "/fake/s1.jsonl",
            project: "proj-a",
            model: "claude-sonnet-5",
            startedAt: isoDate("2026-09-15T10:00:00Z"),
            lastActivity: isoDate("2026-09-15T10:30:00Z"),
            turns: [],
            usage: usage
        )
        let s2 = Session(
            id: "s2",
            profile: "prof1",
            filePath: "/fake/s2.jsonl",
            project: "proj-b",
            model: "claude-sonnet-5",
            startedAt: isoDate("2026-09-14T10:00:00Z"),
            lastActivity: isoDate("2026-09-14T10:30:00Z"),
            turns: [],
            usage: usage
        )

        let sessions = [s1, s2]
        let profiles: [Profile] = []
        let window = WindowUsage(
            last5h: usage,
            today: usage,
            hourlyOutputTokens: [Int](repeating: 0, count: 12),
            scannedAt: now
        )

        let snapshot = AnalyticsViewModel.build(
            sessions: sessions,
            profiles: profiles,
            window: window,
            now: now,
            calendar: cal
        )

        let expectedToday = Aggregates.todayCost(sessions, now: now, calendar: cal)
        let expectedWeek = Aggregates.weekCost(sessions, now: now, calendar: cal)

        #expect(abs(snapshot.todayCostUSD - expectedToday) < 0.00001)
        #expect(abs(snapshot.weekCostUSD - expectedWeek) < 0.00001)
    }

    // 5. AnalyticsState.refresh (with two temp config dirs each holding projects/p/x.jsonl
    // with one assistant usage line at now - 1h) ends with a non-nil snapshot whose
    // window.last5h.outputTokens is the sum of both files, and windowCaches has two entries.
    // (Await the refresh via async func refreshNow or refresh().value.)
    @Test @MainActor func refreshAggregatesAcrossProfilesAndCaches() async throws {
        let fm = FileManager.default
        let tempDir1 = NSTemporaryDirectory() + "analytics-p1-" + UUID().uuidString
        let tempDir2 = NSTemporaryDirectory() + "analytics-p2-" + UUID().uuidString

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

        let state = AnalyticsState()
        #expect(state.snapshot == nil)
        #expect(state.windowCaches.isEmpty)

        await state.refreshNow(sessions: [], profiles: [p1, p2], now: now, calendar: .current)

        #expect(state.snapshot != nil)
        #expect(state.windowCaches.count == 2)
        #expect(state.windowCaches["prof-1"] != nil)
        #expect(state.windowCaches["prof-2"] != nil)
        #expect(state.snapshot?.window.last5h.outputTokens == 40)
    }
}
