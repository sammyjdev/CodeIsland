import Foundation
import Testing
@testable import LLMOpsCore

@Suite("WidgetFormatTests")
struct WidgetFormatTests {
    @Test("percent rounds and clamps to 0...100")
    func percentRoundingAndClamping() {
        #expect(WidgetFormat.percent(42.4) == "42%")
        #expect(WidgetFormat.percent(42.5) == "43%")
        #expect(WidgetFormat.percent(-5.0) == "0%")
        #expect(WidgetFormat.percent(105.0) == "100%")
        #expect(WidgetFormat.percent(0.0) == "0%")
        #expect(WidgetFormat.percent(100.0) == "100%")
    }

    @Test("tokens groups digits with en_US_POSIX commas")
    func tokensGrouping() {
        #expect(WidgetFormat.tokens(0) == "0")
        #expect(WidgetFormat.tokens(999) == "999")
        #expect(WidgetFormat.tokens(1234) == "1,234")
        #expect(WidgetFormat.tokens(1234567) == "1,234,567")
    }

    @Test("usd formats two decimal places")
    func usdFormatting() {
        #expect(WidgetFormat.usd(0.0) == "$0.00")
        #expect(WidgetFormat.usd(1.23) == "$1.23")
        #expect(WidgetFormat.usd(1.234) == "$1.23")
        #expect(WidgetFormat.usd(1.239) == "$1.24")
        #expect(WidgetFormat.usd(12.5) == "$12.50")
    }

    @Test("quotaLine formats provider label and percent")
    func quotaLineFormatting() {
        let q = WidgetQuota(provider: .claude, label: "5h", usedPercent: 42.0, resetsAt: nil)
        #expect(WidgetFormat.quotaLine(q) == "claude 5h  42%")
    }

    @Test("resetsIn formats remaining time")
    func resetsInFormatting() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(WidgetFormat.resetsIn(nil, now: now) == nil)
        #expect(WidgetFormat.resetsIn(now, now: now) == nil)
        #expect(WidgetFormat.resetsIn(now.addingTimeInterval(-100), now: now) == nil)
        #expect(WidgetFormat.resetsIn(now.addingTimeInterval(45 * 60 + 30), now: now) == "45m")
        #expect(WidgetFormat.resetsIn(now.addingTimeInterval(2 * 3600 + 10 * 60), now: now) == "2h 10m")
        #expect(WidgetFormat.resetsIn(now.addingTimeInterval(2 * 3600), now: now) == "2h")
        #expect(WidgetFormat.resetsIn(now.addingTimeInterval(3 * 86400 + 4 * 3600 + 120), now: now) == "3d 4h")
        #expect(WidgetFormat.resetsIn(now.addingTimeInterval(3 * 86400), now: now) == "3d")
    }

    @Test("grouped groups by QuotaProviderID.allCases order and drops empty")
    func groupedQuotas() {
        let quotas = [
            WidgetQuota(provider: .codex, label: "default", usedPercent: 10, resetsAt: nil),
            WidgetQuota(provider: .claude, label: "5h", usedPercent: 20, resetsAt: nil),
            WidgetQuota(provider: .claude, label: "7d", usedPercent: 30, resetsAt: nil),
            WidgetQuota(provider: .openrouter, label: "credits", usedPercent: 40, resetsAt: nil),
        ]
        let groups = WidgetFormat.grouped(quotas)
        #expect(groups.count == 3)
        #expect(groups.map(\.provider) == [.claude, .codex, .openrouter])
        #expect(groups[0].quotas.count == 2)
        #expect(groups[0].quotas.map(\.label) == ["5h", "7d"])
        #expect(groups[1].quotas.count == 1)
        #expect(groups[1].quotas.map(\.label) == ["default"])
        #expect(groups[2].quotas.count == 1)
        #expect(groups[2].quotas.map(\.label) == ["credits"])
        #expect(!groups.contains { $0.provider == .antigravity })
        #expect(!groups.contains { $0.provider == .zai })
    }

    @Test("worstPercent returns max used percent or 0 for empty")
    func worstPercentCalculation() {
        let list = [
            WidgetQuota(provider: .claude, label: "5h", usedPercent: 25.0, resetsAt: nil),
            WidgetQuota(provider: .claude, label: "7d", usedPercent: 85.5, resetsAt: nil),
            WidgetQuota(provider: .codex, label: "default", usedPercent: 50.0, resetsAt: nil),
        ]
        #expect(WidgetFormat.worstPercent(list) == 85.5)
        #expect(WidgetFormat.worstPercent([]) == 0.0)
    }

    @Test("providerName maps antigravity to agy and zai to z.ai")
    func providerNameMapping() {
        #expect(WidgetFormat.providerName(.antigravity) == "agy")
        #expect(WidgetFormat.providerName(.zai) == "z.ai")
        #expect(WidgetFormat.providerName(.claude) == "claude")
        #expect(WidgetFormat.providerName(.codex) == "codex")
        #expect(WidgetFormat.providerName(.openrouter) == "openrouter")
    }
}
