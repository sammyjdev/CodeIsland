import Foundation
import CodeIslandCore   // for ClaudeUsageTotals (public struct with public vars)

public struct ToolCall: Identifiable, Equatable, Sendable {
    public let id: String            // tool_use id
    public let name: String
    public let inputSummary: String
    public let startedAt: Date
    public let durationMs: Int?      // tool_result.timestamp - tool_use.timestamp, nil if no result
    public let isError: Bool         // tool_result.is_error == true

    public init(
        id: String,
        name: String,
        inputSummary: String,
        startedAt: Date,
        durationMs: Int? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.inputSummary = inputSummary
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.isError = isError
    }
}

public struct Turn: Identifiable, Equatable, Sendable {
    public let id: String            // uuid of the user line that started it
    public let startedAt: Date
    public var model: String?        // model of the first assistant line in the turn
    public var userPrompt: String?   // nil for turns started by tool_result-only lines
    public var assistantText: String? // all assistant text blocks joined with "\n"
    public var usage: ClaudeUsageTotals
    public var toolCalls: [ToolCall]

    public init(
        id: String,
        startedAt: Date,
        model: String? = nil,
        userPrompt: String? = nil,
        assistantText: String? = nil,
        usage: ClaudeUsageTotals = ClaudeUsageTotals(),
        toolCalls: [ToolCall] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.model = model
        self.userPrompt = userPrompt
        self.assistantText = assistantText
        self.usage = usage
        self.toolCalls = toolCalls
    }
}

public struct Session: Identifiable, Equatable, Sendable {
    public let id: String            // sessionId (file basename without .jsonl)
    public let profile: String       // Profile.id
    public let filePath: String
    public var cwd: String?
    public var project: String       // last path component of cwd, or "unknown"
    public var title: String?        // from ai-title, else first 80 chars of the first userPrompt
    public var model: String?        // most frequent assistant model
    public var startedAt: Date
    public var lastActivity: Date
    public var turns: [Turn]
    public var usage: ClaudeUsageTotals   // sum of turns (already deduped)

    public init(
        id: String,
        profile: String,
        filePath: String,
        cwd: String? = nil,
        project: String = "unknown",
        title: String? = nil,
        model: String? = nil,
        startedAt: Date,
        lastActivity: Date,
        turns: [Turn] = [],
        usage: ClaudeUsageTotals = ClaudeUsageTotals()
    ) {
        self.id = id
        self.profile = profile
        self.filePath = filePath
        self.cwd = cwd
        self.project = project
        self.title = title
        self.model = model
        self.startedAt = startedAt
        self.lastActivity = lastActivity
        self.turns = turns
        self.usage = usage
    }
}

/// Sum helper; ClaudeUsageTotals.add is internal to CodeIslandCore, so define our own.
public func + (lhs: ClaudeUsageTotals, rhs: ClaudeUsageTotals) -> ClaudeUsageTotals {
    var result = ClaudeUsageTotals()
    result.inputTokens = lhs.inputTokens + rhs.inputTokens
    result.outputTokens = lhs.outputTokens + rhs.outputTokens
    result.cacheCreationTokens = lhs.cacheCreationTokens + rhs.cacheCreationTokens
    result.cacheReadTokens = lhs.cacheReadTokens + rhs.cacheReadTokens
    result.messageCount = lhs.messageCount + rhs.messageCount
    return result
}
