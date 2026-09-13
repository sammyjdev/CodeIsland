import Foundation
import CodeIslandCore

/// USD per 1M tokens. ESTIMATES maintained by hand; header comment must say so.
public struct ModelPrice: Equatable, Sendable {
    public let inputPerM: Double
    public let outputPerM: Double
    public let cacheWritePerM: Double
    public let cacheReadPerM: Double

    public init(inputPerM: Double, outputPerM: Double, cacheWritePerM: Double, cacheReadPerM: Double) {
        self.inputPerM = inputPerM
        self.outputPerM = outputPerM
        self.cacheWritePerM = cacheWritePerM
        self.cacheReadPerM = cacheReadPerM
    }
}

public struct CostEstimate: Equatable, Sendable {
    public let usd: Double
    public let isFallback: Bool // true when the model id was not in the table

    public init(usd: Double, isFallback: Bool) {
        self.usd = usd
        self.isFallback = isFallback
    }
}

public enum CostTable {
    public static let fallbackPrice = ModelPrice(
        inputPerM: 3.0,
        outputPerM: 15.0,
        cacheWritePerM: 3.75,
        cacheReadPerM: 0.30
    )

    /// Exact ids first, then prefix match (longest prefix wins), then fallback.
    /// Seed with these ids and PLACEHOLDER numbers (the owner will correct them):
    ///   "claude-fable-5-1", "claude-opus-5", "claude-sonnet-5",
    ///   "claude-haiku-4-5-20251001", "claude-haiku-4-5",
    ///   plus prefixes "claude-opus", "claude-sonnet", "claude-haiku".
    /// Fallback price: input 3, output 15, cacheWrite 3.75, cacheRead 0.30.
    public static var prices: [String: ModelPrice] {
        [
            "claude-fable-5-1": ModelPrice(inputPerM: 3.0, outputPerM: 15.0, cacheWritePerM: 3.75, cacheReadPerM: 0.30),
            "claude-opus-5": ModelPrice(inputPerM: 15.0, outputPerM: 75.0, cacheWritePerM: 18.75, cacheReadPerM: 1.50),
            "claude-sonnet-5": ModelPrice(inputPerM: 3.0, outputPerM: 15.0, cacheWritePerM: 3.75, cacheReadPerM: 0.30),
            "claude-haiku-4-5-20251001": ModelPrice(inputPerM: 1.0, outputPerM: 5.0, cacheWritePerM: 1.25, cacheReadPerM: 0.10),
            "claude-haiku-4-5": ModelPrice(inputPerM: 1.0, outputPerM: 5.0, cacheWritePerM: 1.25, cacheReadPerM: 0.10),
            "claude-opus": ModelPrice(inputPerM: 15.0, outputPerM: 75.0, cacheWritePerM: 18.75, cacheReadPerM: 1.50),
            "claude-sonnet": ModelPrice(inputPerM: 3.0, outputPerM: 15.0, cacheWritePerM: 3.75, cacheReadPerM: 0.30),
            "claude-haiku": ModelPrice(inputPerM: 1.0, outputPerM: 5.0, cacheWritePerM: 1.25, cacheReadPerM: 0.10)
        ]
    }

    public static func price(for model: String?) -> (ModelPrice, isFallback: Bool) {
        guard let model = model, !model.isEmpty else {
            return (fallbackPrice, true)
        }
        if let exact = prices[model] {
            return (exact, false)
        }
        let matching = prices.filter { key, _ in model.hasPrefix(key) }
        if let best = matching.max(by: { $0.key.count < $1.key.count }) {
            return (best.value, false)
        }
        return (fallbackPrice, true)
    }

    /// usd = in*input + out*output + cacheWrite*cacheWrite + cacheRead*cacheRead, all / 1_000_000.
    public static func estimate(_ usage: ClaudeUsageTotals, model: String?) -> CostEstimate {
        let (p, isFallback) = price(for: model)
        let inCost = Double(usage.inputTokens) * p.inputPerM
        let outCost = Double(usage.outputTokens) * p.outputPerM
        let writeCost = Double(usage.cacheCreationTokens) * p.cacheWritePerM
        let readCost = Double(usage.cacheReadTokens) * p.cacheReadPerM
        let usd = (inCost + outCost + writeCost + readCost) / 1_000_000.0
        return CostEstimate(usd: usd, isFallback: isFallback)
    }
}
