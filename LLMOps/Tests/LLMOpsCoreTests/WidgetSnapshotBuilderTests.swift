import Foundation
import Testing
import CodeIslandCore
@testable import LLMOpsCore

@Suite("WidgetSnapshotBuilderTests")
struct WidgetSnapshotBuilderTests {
    @Test("quotas(from:) preserves allCases order and window order, drops failures")
    func quotasFromResults() {
        let now = Date(timeIntervalSince1970: 1789300000)
        let resetDate = now.addingTimeInterval(3600)

        let claudeSnapshot = QuotaSnapshot(
            provider: .claude,
            windows: [
                QuotaWindow(label: "primary", usedPercent: 12.5, resetsAt: nil)
            ],
            fetchedAt: now,
            detail: nil
        )

        let codexSnapshot = QuotaSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(label: "5h", usedPercent: 45.0, resetsAt: nil),
                QuotaWindow(label: "7d", usedPercent: 80.0, resetsAt: resetDate)
            ],
            fetchedAt: now,
            detail: nil
        )

        let results: [QuotaProviderID: Result<QuotaSnapshot, QuotaError>] = [
            .codex: .success(codexSnapshot),
            .claude: .success(claudeSnapshot),
            .antigravity: .failure(.network("timeout"))
        ]

        let quotas = WidgetSnapshotBuilder.quotas(from: results)

        #expect(quotas.count == 3)
        #expect(quotas == [
            WidgetQuota(provider: .claude, label: "primary", usedPercent: 12.5, resetsAt: nil),
            WidgetQuota(provider: .codex, label: "5h", usedPercent: 45.0, resetsAt: nil),
            WidgetQuota(provider: .codex, label: "7d", usedPercent: 80.0, resetsAt: resetDate)
        ])
    }

    @Test("today counts sessions with turn today, sums tokens, and matches Aggregates.todayCost")
    func todaySummary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: 1789305000)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!

        var usage1 = ClaudeUsageTotals()
        usage1.inputTokens = 100
        usage1.outputTokens = 50
        usage1.cacheCreationTokens = 25
        usage1.cacheReadTokens = 10

        let turnToday = Turn(id: "t-today", startedAt: now, model: "claude-sonnet-5", usage: usage1)
        let sToday = Session(
            id: "s1",
            profile: "p1",
            filePath: "/tmp/s1.jsonl",
            model: "claude-sonnet-5",
            startedAt: now,
            lastActivity: now,
            turns: [turnToday],
            usage: usage1
        )

        var usage2 = ClaudeUsageTotals()
        usage2.inputTokens = 1000
        usage2.outputTokens = 500
        usage2.cacheCreationTokens = 250
        usage2.cacheReadTokens = 100

        let turnYesterday = Turn(id: "t-yesterday", startedAt: yesterday, model: "claude-sonnet-5", usage: usage2)
        let sYesterday = Session(
            id: "s2",
            profile: "p1",
            filePath: "/tmp/s2.jsonl",
            model: "claude-sonnet-5",
            startedAt: yesterday,
            lastActivity: yesterday,
            turns: [turnYesterday],
            usage: usage2
        )

        let summary = WidgetSnapshotBuilder.today([sToday, sYesterday], now: now, calendar: calendar)

        #expect(summary.sessions == 1)
        #expect(summary.tokens == 185)
        let expectedCost = Aggregates.todayCost([sToday, sYesterday], now: now, calendar: calendar)
        #expect(summary.costUSD == expectedCost)
        #expect(summary.costUSD > 0)
    }

    @Test("system maps cpu, memoryUsedPercent, and battery")
    func systemSummary() {
        let memory = MemorySample(total: 1000, used: 650, wired: 100, compressed: 100, free: 350)
        let battery = BatterySample(percent: 88, isCharging: false, isPluggedIn: true, minutesRemaining: 180, cycleCount: 42, healthPercent: 98)

        let sampleWithBattery = SystemSample(
            at: Date(),
            cpuPercent: 34.5,
            memory: memory,
            topByCPU: [],
            topByMemory: [],
            battery: battery
        )

        let summaryWithBattery = WidgetSnapshotBuilder.system(sampleWithBattery)
        #expect(summaryWithBattery.cpuPercent == 34.5)
        #expect(summaryWithBattery.memoryUsedPercent == 65.0)
        #expect(summaryWithBattery.batteryPercent == 88.0)

        let sampleWithoutBattery = SystemSample(
            at: Date(),
            cpuPercent: 12.0,
            memory: memory,
            topByCPU: [],
            topByMemory: [],
            battery: nil
        )

        let summaryWithoutBattery = WidgetSnapshotBuilder.system(sampleWithoutBattery)
        #expect(summaryWithoutBattery.cpuPercent == 12.0)
        #expect(summaryWithoutBattery.memoryUsedPercent == 65.0)
        #expect(summaryWithoutBattery.batteryPercent == nil)
    }
}
