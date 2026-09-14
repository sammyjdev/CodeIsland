import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@Suite struct HistoryFilterTests {
    private func makeSession(
        id: String = UUID().uuidString,
        profile: String = "default",
        filePath: String = "/tmp/test.jsonl",
        cwd: String? = nil,
        project: String = "unknown",
        title: String? = nil,
        model: String? = nil,
        startedAt: Date = Date(),
        lastActivity: Date = Date(),
        turns: [Turn] = [],
        usage: ClaudeUsageTotals = ClaudeUsageTotals()
    ) -> Session {
        Session(
            id: id,
            profile: profile,
            filePath: filePath,
            cwd: cwd,
            project: project,
            title: title,
            model: model,
            startedAt: startedAt,
            lastActivity: lastActivity,
            turns: turns,
            usage: usage
        )
    }

    private func makeTurn(
        id: String = UUID().uuidString,
        startedAt: Date = Date(),
        model: String? = nil,
        userPrompt: String? = nil,
        assistantText: String? = nil,
        usage: ClaudeUsageTotals = ClaudeUsageTotals(),
        toolCalls: [ToolCall] = []
    ) -> Turn {
        Turn(
            id: id,
            startedAt: startedAt,
            model: model,
            userPrompt: userPrompt,
            assistantText: assistantText,
            usage: usage,
            toolCalls: toolCalls
        )
    }

    // 1. apply with no criteria returns the input unchanged (same order).
    @Test func applyWithNoCriteriaReturnsInputUnchanged() {
        let s1 = makeSession(id: "s1", project: "projA")
        let s2 = makeSession(id: "s2", project: "projB")
        let s3 = makeSession(id: "s3", project: "projC")
        let filter = HistoryFilter()
        let result = filter.apply(to: [s1, s2, s3])
        #expect(result == [s1, s2, s3])
    }

    // 2. Project and model filters are exact and combine with AND.
    @Test func projectAndModelFiltersAreExactAndCombineWithAnd() {
        let s1 = makeSession(id: "s1", project: "alpha", model: "claude-3-opus")
        let s2 = makeSession(id: "s2", project: "alpha", model: "claude-3-sonnet")
        let s3 = makeSession(id: "s3", project: "beta", model: "claude-3-opus")
        let s4 = makeSession(id: "s4", project: "beta", model: "claude-3-sonnet")

        var filter = HistoryFilter(project: "alpha")
        #expect(filter.apply(to: [s1, s2, s3, s4]) == [s1, s2])

        filter = HistoryFilter(model: "claude-3-opus")
        #expect(filter.apply(to: [s1, s2, s3, s4]) == [s1, s3])

        filter = HistoryFilter(project: "alpha", model: "claude-3-opus")
        #expect(filter.apply(to: [s1, s2, s3, s4]) == [s1])

        filter = HistoryFilter(project: "nonexistent", model: "claude-3-opus")
        #expect(filter.apply(to: [s1, s2, s3, s4]).isEmpty)
    }

    // 3. Date range is inclusive on both ends and works with only from or only to.
    @Test func dateRangeIsInclusiveAndWorksWithOnlyFromOrOnlyTo() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let d1 = Date(timeIntervalSince1970: 0)
        let d2 = Date(timeIntervalSince1970: 86400)
        let d3 = Date(timeIntervalSince1970: 172800)

        let s1 = makeSession(id: "s1", startedAt: d1)
        let s2 = makeSession(id: "s2", startedAt: d2)
        let s3 = makeSession(id: "s3", startedAt: d3)
        let sessions = [s1, s2, s3]

        var filter = HistoryFilter(from: d2)
        filter.calendar = cal
        #expect(filter.apply(to: sessions) == [s2, s3])

        filter = HistoryFilter(to: d2)
        filter.calendar = cal
        #expect(filter.apply(to: sessions) == [s1, s2])

        filter = HistoryFilter(from: d2, to: d2)
        filter.calendar = cal
        #expect(filter.apply(to: sessions) == [s2])

        filter = HistoryFilter(from: d1, to: d3)
        filter.calendar = cal
        #expect(filter.apply(to: sessions) == [s1, s2, s3])

        filter = HistoryFilter(from: Date(timeIntervalSince1970: 250000), to: Date(timeIntervalSince1970: 260000))
        filter.calendar = cal
        #expect(filter.apply(to: sessions).isEmpty)
    }

    // 4. Search is case-insensitive and matches a turn prompt or the title; a session with no matching turn and a non-matching title is excluded.
    @Test func searchIsCaseInsensitiveAndMatchesTurnPromptOrTitle() {
        let t1 = makeTurn(id: "t1", userPrompt: "Fix the Swift build error")
        let s1 = makeSession(id: "s1", title: "Debugging issue", turns: [t1])

        let t2 = makeTurn(id: "t2", userPrompt: "Add unit tests")
        let s2 = makeSession(id: "s2", title: "Swift testing improvements", turns: [t2])

        let t3 = makeTurn(id: "t3", userPrompt: "Refactor database queries")
        let s3 = makeSession(id: "s3", title: "Performance audit", turns: [t3])

        let sessions = [s1, s2, s3]

        var filter = HistoryFilter(search: "swift")
        #expect(filter.apply(to: sessions) == [s1, s2])

        filter = HistoryFilter(search: "AUDIT")
        #expect(filter.apply(to: sessions) == [s3])

        filter = HistoryFilter(search: "UNIT TESTS")
        #expect(filter.apply(to: sessions) == [s2])

        filter = HistoryFilter(search: "nonexistent query")
        #expect(filter.apply(to: sessions).isEmpty)
    }

    // 5. projects(in:) and models(in:) are distinct and sorted; models drops nil.
    @Test func projectsAndModelsAreDistinctAndSorted() {
        let s1 = makeSession(id: "s1", project: "zebra", model: "claude-3-opus")
        let s2 = makeSession(id: "s2", project: "apple", model: "claude-3-sonnet")
        let s3 = makeSession(id: "s3", project: "zebra", model: nil)
        let s4 = makeSession(id: "s4", project: "banana", model: "claude-3-opus")

        let sessions = [s1, s2, s3, s4]
        #expect(HistoryFilter.projects(in: sessions) == ["apple", "banana", "zebra"])
        #expect(HistoryFilter.models(in: sessions) == ["claude-3-opus", "claude-3-sonnet"])
    }

    // 6. HistoryFormat.tokens: 999 -> "999", 1234 -> "1,234", 12_345 -> "12.3K", 1_234_567 -> "1.2M".
    @Test func historyFormatTokens() {
        #expect(HistoryFormat.tokens(999) == "999")
        #expect(HistoryFormat.tokens(1234) == "1,234")
        #expect(HistoryFormat.tokens(12_345) == "12.3K")
        #expect(HistoryFormat.tokens(1_234_567) == "1.2M")
    }

    // 7. HistoryFormat.cacheRatio, usd (0.04213 -> "$0.0421", 12.4 -> "$12.40"), duration (nil, 850, 1250, 61000) per the contract.
    @Test func historyFormatCacheRatioUsdAndDuration() {
        var uZero = ClaudeUsageTotals()
        uZero.inputTokens = 0
        uZero.cacheReadTokens = 0
        uZero.cacheCreationTokens = 0
        #expect(HistoryFormat.cacheRatio(uZero) == "0%")

        var u87 = ClaudeUsageTotals()
        u87.inputTokens = 130
        u87.cacheReadTokens = 870
        u87.cacheCreationTokens = 0
        #expect(HistoryFormat.cacheRatio(u87) == "87%")

        #expect(HistoryFormat.usd(0.04213) == "$0.0421")
        #expect(HistoryFormat.usd(12.4) == "$12.40")

        #expect(HistoryFormat.duration(ms: nil) == "n/a")
        #expect(HistoryFormat.duration(ms: 850) == "850ms")
        #expect(HistoryFormat.duration(ms: 1250) == "1.3s")
        #expect(HistoryFormat.duration(ms: 61000) == "1m 01s")
    }

    // 8. to date includes the whole calendar day in filter's calendar
    @Test func historyFilterToDateIncludesWholeDay() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")!

        let toDate = f.date(from: "2026-09-10T00:00:00Z")!
        let sSameDayEvening = makeSession(id: "s1", startedAt: f.date(from: "2026-09-10T18:00:00Z")!)
        let sNextDayMidnight = makeSession(id: "s2", startedAt: f.date(from: "2026-09-11T00:00:00Z")!)

        var filter = HistoryFilter(to: toDate)
        filter.calendar = cal

        let result = filter.apply(to: [sSameDayEvening, sNextDayMidnight])
        #expect(result == [sSameDayEvening])
    }

    // 1. period .d7 keeps a session started 6 days before now and drops one started 8 days before.
    @Test func periodD7Keeps6DaysOldAndDrops8DaysOld() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sKept = makeSession(id: "sKept", startedAt: now.addingTimeInterval(-6 * 86400))
        let sDropped = makeSession(id: "sDropped", startedAt: now.addingTimeInterval(-8 * 86400))

        var filter = HistoryFilter()
        filter.calendar = cal
        filter.period = .d7

        let result = filter.apply(to: [sKept, sDropped], now: now)
        #expect(result == [sKept])
    }

    // 2. period .d30 (the default) keeps a session 29 days old and drops one 31 days old.
    @Test func periodD30DefaultKeeps29DaysOldAndDrops31DaysOld() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sKept = makeSession(id: "sKept", startedAt: now.addingTimeInterval(-29 * 86400))
        let sDropped = makeSession(id: "sDropped", startedAt: now.addingTimeInterval(-31 * 86400))

        var filter = HistoryFilter()
        filter.calendar = cal
        #expect(filter.period == .d30)

        let result = filter.apply(to: [sKept, sDropped], now: now)
        #expect(result == [sKept])
    }

    // 3. period .all with no dates keeps a session 400 days old.
    @Test func periodAllWithNoDatesKeeps400DaysOld() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sOld = makeSession(id: "sOld", startedAt: now.addingTimeInterval(-400 * 86400))

        var filter = HistoryFilter()
        filter.calendar = cal
        filter.period = .all

        let result = filter.apply(to: [sOld], now: now)
        #expect(result == [sOld])
    }

    // 4. An explicit from older than the preset window overrides it: period .d7 plus from = now - 20 days keeps a session 15 days old.
    @Test func explicitFromOlderThanPresetWindowOverridesIt() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let s15 = makeSession(id: "s15", startedAt: now.addingTimeInterval(-15 * 86400))
        let s25 = makeSession(id: "s25", startedAt: now.addingTimeInterval(-25 * 86400))

        var filter = HistoryFilter()
        filter.calendar = cal
        filter.period = .d7
        filter.from = now.addingTimeInterval(-20 * 86400)

        let result = filter.apply(to: [s15, s25], now: now)
        #expect(result == [s15])
    }

    // 5. select(period: .d90) clears from and to.
    @Test func selectPeriodClearsFromAndTo() {
        var filter = HistoryFilter()
        filter.from = Date()
        filter.to = Date()

        filter.select(period: .d90)
        #expect(filter.period == .d90)
        #expect(filter.from == nil)
        #expect(filter.to == nil)
    }

    // 6. setFrom(date) switches period to .all; setTo(date) does the same.
    @Test func setFromSwitchesPeriodToAll() {
        var filter = HistoryFilter()
        #expect(filter.period == .d30)

        let date = Date(timeIntervalSince1970: 12345)
        filter.setFrom(date)
        #expect(filter.period == .all)
        #expect(filter.from == date)
    }

    @Test func setToSwitchesPeriodToAll() {
        var filter = HistoryFilter()
        filter.select(period: .d7)
        #expect(filter.period == .d7)

        let date = Date(timeIntervalSince1970: 67890)
        filter.setTo(date)
        #expect(filter.period == .all)
        #expect(filter.to == date)
    }

    // 7. dayCount(now:earliest:): .d7 gives 7, .d30 gives 30, .d90 gives 90; .all with earliest 44 days before now gives 45; .all with earliest nil gives 1; .all with earliest later than now gives 1.
    @Test func dayCountPresetValues() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var filter = HistoryFilter()
        filter.calendar = cal

        filter.period = .d7
        #expect(filter.dayCount(now: now, earliest: nil) == 7)

        filter.period = .d30
        #expect(filter.dayCount(now: now, earliest: nil) == 30)

        filter.period = .d90
        #expect(filter.dayCount(now: now, earliest: nil) == 90)
    }

    @Test func dayCountAllWithEarliest44DaysBeforeNowGives45() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var filter = HistoryFilter()
        filter.calendar = cal
        filter.period = .all

        let earliest44 = cal.date(byAdding: .day, value: -44, to: now)!
        #expect(filter.dayCount(now: now, earliest: earliest44) == 45)
    }

    @Test func dayCountAllWithEarliestNilGives1() {
        var filter = HistoryFilter()
        filter.period = .all
        #expect(filter.dayCount(now: Date(), earliest: nil) == 1)
    }

    @Test func dayCountAllWithEarliestLaterThanNowGives1() {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var filter = HistoryFilter()
        filter.calendar = cal
        filter.period = .all

        let future = cal.date(byAdding: .day, value: 5, to: now)!
        #expect(filter.dayCount(now: now, earliest: future) == 1)
    }

    // 8. Period.label gives 7d, 30d, 90d, all
    @Test func periodLabels() {
        #expect(Period.d7.label == "7d")
        #expect(Period.d30.label == "30d")
        #expect(Period.d90.label == "90d")
        #expect(Period.all.label == "all")
    }

    // 9. HistoryFormat.bytes: 512 -> "512 B", 12_288 -> "12 KB", 3_565_158 -> "3.4 MB", 356_515_840 -> "340 MB", 1_288_490_189 -> "1.2 GB".
    @Test func bytesFormatting() {
        #expect(HistoryFormat.bytes(512) == "512 B")
        #expect(HistoryFormat.bytes(12_288) == "12 KB")
        #expect(HistoryFormat.bytes(3_565_158) == "3.4 MB")
        #expect(HistoryFormat.bytes(356_515_840) == "340 MB")
        #expect(HistoryFormat.bytes(1_288_490_189) == "1.2 GB")
    }
}

