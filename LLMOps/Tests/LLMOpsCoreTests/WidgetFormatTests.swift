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
}
