import Foundation
import Testing
import CodeIslandCore
@testable import LLMOpsCore

@Suite("AnalysisDigestTests")
struct AnalysisDigestTests {
    private var utcCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    private var fixedNow: Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")!
        return f.date(from: "2026-09-14T12:00:00Z")!
    }

    private func makeThreeSessionFixture() -> [Session] {
        let cal = utcCalendar
        let d1 = cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 9, minute: 0, second: 0))!
        let d2 = cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 10, minute: 0, second: 0))!
        let d3 = cal.date(from: DateComponents(year: 2026, month: 9, day: 14, hour: 11, minute: 0, second: 0))!

        // Session 1: sonnet, 2 tool errors, userPrompt "SECRET_PROMPT_MARKER", 1500 tokens
        var u1 = ClaudeUsageTotals()
        u1.inputTokens = 1000
        u1.outputTokens = 500
        let s1 = Session(
            id: "s1",
            profile: "default",
            filePath: "/tmp/s1.jsonl",
            project: "proj-a",
            title: "First Session",
            model: "claude-sonnet-5",
            startedAt: d1,
            lastActivity: d1,
            turns: [
                Turn(
                    id: "t1",
                    startedAt: d1,
                    model: "claude-sonnet-5",
                    userPrompt: "SECRET_PROMPT_MARKER",
                    usage: u1,
                    toolCalls: [
                        ToolCall(id: "tc1", name: "read", inputSummary: "{}", startedAt: d1, isError: true),
                        ToolCall(id: "tc2", name: "read", inputSummary: "{}", startedAt: d1, isError: true)
                    ]
                )
            ],
            usage: u1
        )

        // Session 2: opus (highest cost), 1 tool error, 7000 tokens
        var u2 = ClaudeUsageTotals()
        u2.inputTokens = 5000
        u2.outputTokens = 2000
        let s2 = Session(
            id: "s2",
            profile: "default",
            filePath: "/tmp/s2.jsonl",
            project: "proj-b",
            title: "Second Session",
            model: "claude-opus-5",
            startedAt: d2,
            lastActivity: d2,
            turns: [
                Turn(
                    id: "t2",
                    startedAt: d2,
                    model: "claude-opus-5",
                    usage: u2,
                    toolCalls: [
                        ToolCall(id: "tc3", name: "bash", inputSummary: "{}", startedAt: d2, isError: true)
                    ]
                )
            ],
            usage: u2
        )

        // Session 3: haiku (lowest cost), 0 tool errors, 150 tokens
        var u3 = ClaudeUsageTotals()
        u3.inputTokens = 100
        u3.outputTokens = 50
        let s3 = Session(
            id: "s3",
            profile: "default",
            filePath: "/tmp/s3.jsonl",
            project: "proj-c",
            title: "Third Session",
            model: "claude-haiku-3.5",
            startedAt: d3,
            lastActivity: d3,
            turns: [
                Turn(
                    id: "t3",
                    startedAt: d3,
                    model: "claude-haiku-3.5",
                    usage: u3,
                    toolCalls: [
                        ToolCall(id: "tc4", name: "bash", inputSummary: "{}", startedAt: d3, isError: false)
                    ]
                )
            ],
            usage: u3
        )

        return [s1, s2, s3]
    }

    // 1. Three session fixture (costs differ, one has 2 tool errors, one has 1, one has 0;
    // one session has userPrompt "SECRET_PROMPT_MARKER" in a turn).
    // build gives sessionCount == 3, topByCost ordered by costUSD desc,
    // topByErrors.count == 2 ordered [2 errors, 1 error], totals.sessions == 3,
    // totals.totalTokens equals the sum over the three sessions.
    @Test func threeSessionFixtureBuildSummary() {
        let sessions = makeThreeSessionFixture()
        let digest = AnalysisDigest.build(
            sessions: sessions,
            profile: nil,
            periodDays: 7,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(digest.sessionCount == 3)
        #expect(digest.topByCost.map(\.id) == ["s2", "s1", "s3"])
        #expect(digest.topByErrors.count == 2)
        #expect(digest.topByErrors.map(\.toolErrors) == [2, 1])
        #expect(digest.topByErrors.map(\.id) == ["s1", "s2"])
        #expect(digest.totals.sessions == 3)
        let expectedTokens = (1000 + 500) + (5000 + 2000) + (100 + 50)
        #expect(digest.totals.totalTokens == expectedTokens)
    }

    // 2. A title longer than 80 characters is truncated to exactly 80 in SessionRow.title; a nil title becomes "".
    @Test func titleTruncationAndNilHandling() {
        let longTitle = String(repeating: "x", count: 100)
        let s1 = Session(
            id: "s1",
            profile: "default",
            filePath: "/tmp/s1.jsonl",
            title: longTitle,
            startedAt: fixedNow,
            lastActivity: fixedNow
        )
        let s2 = Session(
            id: "s2",
            profile: "default",
            filePath: "/tmp/s2.jsonl",
            title: nil,
            startedAt: fixedNow,
            lastActivity: fixedNow
        )

        let digest = AnalysisDigest.build(
            sessions: [s1, s2],
            profile: nil,
            periodDays: 7,
            now: fixedNow,
            calendar: utcCalendar
        )

        let row1 = digest.topByCost.first { $0.id == "s1" }
        let row2 = digest.topByCost.first { $0.id == "s2" }

        #expect(row1?.title.count == 80)
        #expect(row1?.title == String(repeating: "x", count: 80))
        #expect(row2?.title == "")
    }

    // 3. encoded() of the fixture, decoded as a String, does NOT contain "SECRET_PROMPT_MARKER".
    @Test func encodedDigestOmitsPromptText() throws {
        let sessions = makeThreeSessionFixture()
        let digest = AnalysisDigest.build(
            sessions: sessions,
            profile: nil,
            periodDays: 7,
            now: fixedNow,
            calendar: utcCalendar
        )
        let data = try digest.encoded()
        let jsonString = String(decoding: data, as: UTF8.self)
        #expect(!jsonString.contains("SECRET_PROMPT_MARKER"))
    }

    // 4. encoded() round trips: decoding with a JSONDecoder using .iso8601 dates gives an equal digest.
    @Test func encodedRoundTrips() throws {
        let sessions = makeThreeSessionFixture()
        let digest = AnalysisDigest.build(
            sessions: sessions,
            profile: nil,
            periodDays: 7,
            now: fixedNow,
            calendar: utcCalendar
        )
        let data = try digest.encoded()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AnalysisDigest.self, from: data)
        #expect(decoded == digest)
    }

    // 5. days.count == periodDays for periodDays: 7.
    @Test func daysCountMatchesPeriodDays() {
        let sessions = makeThreeSessionFixture()
        let digest = AnalysisDigest.build(
            sessions: sessions,
            profile: nil,
            periodDays: 7,
            now: fixedNow,
            calendar: utcCalendar
        )
        #expect(digest.days.count == 7)
    }

    // 6. tools.count <= 15 with a fixture of 20 distinct tool names, and tools is the prefix of Aggregates.perTool.
    @Test func toolsPrefixCapAt15() {
        var calls: [ToolCall] = []
        for i in 0..<20 {
            for _ in 0..<(25 - i) {
                calls.append(ToolCall(id: "tc_\(i)", name: "tool_\(i)", inputSummary: "{}", startedAt: fixedNow))
            }
        }
        let session = Session(
            id: "s-tools",
            profile: "default",
            filePath: "/tmp/tools.jsonl",
            startedAt: fixedNow,
            lastActivity: fixedNow,
            turns: [Turn(id: "t1", startedAt: fixedNow, toolCalls: calls)]
        )

        let digest = AnalysisDigest.build(
            sessions: [session],
            profile: nil,
            periodDays: 7,
            now: fixedNow,
            calendar: utcCalendar
        )

        #expect(digest.tools.count == 15)
        let expectedPrefix = Array(Aggregates.perTool([session]).prefix(15))
        #expect(digest.tools == expectedPrefix)
    }

    // 7. 200 session fixture (each 5 turns, 3 tool calls per turn, titles 60 characters): encoded().count < 20_000.
    @Test func largeFixtureEncodedSizeUnder20KB() throws {
        var sessions: [Session] = []
        sessions.reserveCapacity(200)
        let title60 = String(repeating: "a", count: 60)

        for i in 0..<200 {
            var turns: [Turn] = []
            turns.reserveCapacity(5)
            for j in 0..<5 {
                var u = ClaudeUsageTotals()
                u.inputTokens = 100
                u.outputTokens = 50
                let calls = [
                    ToolCall(id: "tc-\(i)-\(j)-1", name: "read", inputSummary: "{}", startedAt: fixedNow),
                    ToolCall(id: "tc-\(i)-\(j)-2", name: "edit", inputSummary: "{}", startedAt: fixedNow),
                    ToolCall(id: "tc-\(i)-\(j)-3", name: "bash", inputSummary: "{}", startedAt: fixedNow)
                ]
                turns.append(Turn(id: "t-\(i)-\(j)", startedAt: fixedNow, usage: u, toolCalls: calls))
            }
            sessions.append(Session(
                id: "sess-\(i)",
                profile: "default",
                filePath: "/tmp/sess-\(i).jsonl",
                title: title60,
                startedAt: fixedNow,
                lastActivity: fixedNow,
                turns: turns
            ))
        }

        let digest = AnalysisDigest.build(
            sessions: sessions,
            profile: nil,
            periodDays: 30,
            now: fixedNow,
            calendar: utcCalendar
        )
        let data = try digest.encoded()
        #expect(data.count < 20_000)
    }

    // 8. JudgeReportParser.parse on plain JSON gives a report with one finding.
    @Test func judgeReportParserPlainJSON() {
        let json = """
        {"verdict":"ok","findings":[{"severity":"high","title":"t","evidence":"e","suggestion":"s"}]}
        """
        let report = JudgeReportParser.parse(json)
        #expect(report == JudgeReport(verdict: "ok", findings: [
            JudgeFinding(severity: "high", title: "t", evidence: "e", suggestion: "s")
        ]))
    }

    // 9. parse on the same JSON wrapped in a "```json ... ```" fence gives the same report.
    @Test func judgeReportParserFencedJSON() {
        let json = """
        {"verdict":"ok","findings":[{"severity":"high","title":"t","evidence":"e","suggestion":"s"}]}
        """
        let fenced = "```json\n\(json)\n```"
        let report = JudgeReportParser.parse(fenced)
        #expect(report == JudgeReport(verdict: "ok", findings: [
            JudgeFinding(severity: "high", title: "t", evidence: "e", suggestion: "s")
        ]))
    }

    // 10. parse on "The usage looks fine overall." returns nil; parse on "" returns nil.
    @Test func judgeReportParserInvalidInputs() {
        #expect(JudgeReportParser.parse("The usage looks fine overall.") == nil)
        #expect(JudgeReportParser.parse("") == nil)
    }
}
