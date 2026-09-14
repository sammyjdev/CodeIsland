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
}
