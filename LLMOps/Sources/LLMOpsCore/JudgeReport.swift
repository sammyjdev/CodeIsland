import Foundation

public struct JudgeFinding: Codable, Equatable, Sendable, Identifiable {
    public var id: String { title }
    public let severity: String    // "high" | "medium" | "low", stored as given
    public let title: String
    public let evidence: String
    public let suggestion: String

    public init(severity: String, title: String, evidence: String, suggestion: String) {
        self.severity = severity
        self.title = title
        self.evidence = evidence
        self.suggestion = suggestion
    }
}

public struct JudgeReport: Codable, Equatable, Sendable {
    public let verdict: String
    public let findings: [JudgeFinding]

    public init(verdict: String, findings: [JudgeFinding]) {
        self.verdict = verdict
        self.findings = findings
    }
}

public enum JudgeReportParser {
    /// Accepts the raw text a model returned. Trims whitespace. If the text starts
    /// with a fence (three backticks, optionally followed by "json") and ends with a
    /// fence, strips both. Then JSONDecoder. Returns nil on any failure.
    public static func parse(_ text: String) -> JudgeReport? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("```") && trimmed.hasSuffix("```") && trimmed.count >= 6 {
            trimmed.removeFirst(3)
            trimmed.removeLast(3)
            let trimmedLeading = trimmed.trimmingCharacters(in: .whitespaces)
            if trimmedLeading.hasPrefix("json") {
                trimmed = String(trimmedLeading.dropFirst(4))
            } else if trimmedLeading.hasPrefix("JSON") {
                trimmed = String(trimmedLeading.dropFirst(4))
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JudgeReport.self, from: data)
    }
}
