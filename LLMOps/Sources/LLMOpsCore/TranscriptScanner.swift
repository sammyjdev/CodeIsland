import Foundation
import CodeIslandCore

public enum TranscriptScanner {
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainFormatter = ISO8601DateFormatter()

    private static func parseISO8601(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }

    private static func summarizeInput(name: String, input: Any?) -> String {
        guard let dict = input as? [String: Any] else { return "" }
        switch name {
        case "Bash":
            guard let command = dict["command"] as? String else { return "" }
            let firstLine = command.components(separatedBy: "\n").first ?? ""
            return String(firstLine.prefix(120))
        case "Read", "Edit", "Write", "MultiEdit":
            guard let filePath = dict["file_path"] as? String else { return "" }
            return (filePath as NSString).lastPathComponent
        case "Grep", "Glob":
            guard let pattern = dict["pattern"] as? String else { return "" }
            return pattern
        default:
            guard JSONSerialization.isValidJSONObject(dict),
                  let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                  let str = String(data: data, encoding: .utf8) else {
                return ""
            }
            return String(str.prefix(80))
        }
    }

    private static func processToolResults(
        _ blocks: [[String: Any]],
        into turn: inout Turn,
        lineTimestamp: Date?
    ) {
        for block in blocks {
            guard let toolUseId = block["tool_use_id"] as? String else { continue }
            let isError = (block["is_error"] as? Bool) ?? false

            if let idx = turn.toolCalls.firstIndex(where: { $0.id == toolUseId && $0.durationMs == nil })
                ?? turn.toolCalls.firstIndex(where: { $0.id == toolUseId }) {
                let call = turn.toolCalls[idx]
                let durationMs: Int?
                if let resultTime = lineTimestamp {
                    durationMs = Int(round(resultTime.timeIntervalSince(call.startedAt) * 1000))
                } else {
                    durationMs = nil
                }
                turn.toolCalls[idx] = ToolCall(
                    id: call.id,
                    name: call.name,
                    inputSummary: call.inputSummary,
                    startedAt: call.startedAt,
                    durationMs: durationMs,
                    isError: isError
                )
            }
        }
    }

    /// Parses one whole transcript. `lines` are raw JSONL lines. Pure.
    public static func buildSession(id: String, profile: String, filePath: String, lines: [Substring]) -> Session? {
        var turns: [Turn] = []
        var seenMessageIds: Set<String> = []
        var aiTitle: String? = nil
        var cwd: String? = nil
        var firstTimestamp: Date? = nil
        var lastTimestamp: Date? = nil

        for rawLine in lines {
            var slice = rawLine[...]
            while let first = slice.first, first == " " || first == "\t" || first == "\r" || first == "\n" {
                slice = slice.dropFirst()
            }
            while let last = slice.last, last == " " || last == "\t" || last == "\r" || last == "\n" {
                slice = slice.dropLast()
            }
            if slice.isEmpty { continue }

            guard slice.contains("\"user\"") || slice.contains("\"assistant\"") || slice.contains("\"ai-title\"") else {
                continue
            }

            guard let obj = try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any] else {
                continue
            }

            if (obj["isSidechain"] as? Bool) == true {
                continue
            }

            guard let type = obj["type"] as? String else { continue }

            let timestampRaw = obj["timestamp"] as? String
            let lineTimestamp = timestampRaw.flatMap(parseISO8601)

            if let lineCwd = obj["cwd"] as? String, !lineCwd.isEmpty {
                cwd = lineCwd
            }

            if type == "ai-title" {
                if let title = obj["aiTitle"] as? String, !title.isEmpty {
                    aiTitle = title
                }
                if let t = lineTimestamp {
                    if firstTimestamp == nil { firstTimestamp = t }
                    lastTimestamp = t
                }
                continue
            }

            guard type == "user" || type == "assistant" else { continue }

            if type == "user" {
                if (obj["isMeta"] as? Bool) == true {
                    continue
                }

                if let t = lineTimestamp {
                    if firstTimestamp == nil { firstTimestamp = t }
                    lastTimestamp = t
                }

                let uuid = (obj["uuid"] as? String) ?? UUID().uuidString
                let message = obj["message"] as? [String: Any]
                let content = message?["content"] ?? obj["content"]

                if let promptStr = content as? String {
                    let newTurn = Turn(
                        id: uuid,
                        startedAt: lineTimestamp ?? Date(),
                        model: nil,
                        userPrompt: promptStr,
                        assistantText: nil,
                        usage: ClaudeUsageTotals(),
                        toolCalls: []
                    )
                    turns.append(newTurn)
                } else if let blocks = content as? [[String: Any]] {
                    let textBlocks = blocks.compactMap { block -> String? in
                        guard (block["type"] as? String) == "text",
                              let text = block["text"] as? String else { return nil }
                        return text
                    }
                    let toolResultBlocks = blocks.filter { ($0["type"] as? String) == "tool_result" }

                    if !textBlocks.isEmpty {
                        let promptStr = textBlocks.joined(separator: "\n")
                        let newTurn = Turn(
                            id: uuid,
                            startedAt: lineTimestamp ?? Date(),
                            model: nil,
                            userPrompt: promptStr,
                            assistantText: nil,
                            usage: ClaudeUsageTotals(),
                            toolCalls: []
                        )
                        turns.append(newTurn)
                        if !toolResultBlocks.isEmpty && !turns.isEmpty {
                            processToolResults(toolResultBlocks, into: &turns[turns.count - 1], lineTimestamp: lineTimestamp)
                        }
                    } else if !toolResultBlocks.isEmpty {
                        if turns.isEmpty {
                            turns.append(Turn(
                                id: uuid,
                                startedAt: lineTimestamp ?? Date(),
                                model: nil,
                                userPrompt: nil,
                                assistantText: nil,
                                usage: ClaudeUsageTotals(),
                                toolCalls: []
                            ))
                        }
                        processToolResults(toolResultBlocks, into: &turns[turns.count - 1], lineTimestamp: lineTimestamp)
                    }
                }
            } else if type == "assistant" {
                if let t = lineTimestamp {
                    if firstTimestamp == nil { firstTimestamp = t }
                    lastTimestamp = t
                }

                let uuid = (obj["uuid"] as? String) ?? UUID().uuidString
                let message = obj["message"] as? [String: Any]

                if turns.isEmpty {
                    turns.append(Turn(
                        id: uuid,
                        startedAt: lineTimestamp ?? Date(),
                        model: nil,
                        userPrompt: nil,
                        assistantText: nil,
                        usage: ClaudeUsageTotals(),
                        toolCalls: []
                    ))
                }

                let turnIndex = turns.count - 1

                if turns[turnIndex].model == nil, let model = message?["model"] as? String {
                    turns[turnIndex].model = model
                }

                if let messageId = message?["id"] as? String {
                    if !seenMessageIds.contains(messageId) {
                        seenMessageIds.insert(messageId)
                        if let usageDict = message?["usage"] as? [String: Any] {
                            var u = ClaudeUsageTotals()
                            u.inputTokens = usageDict["input_tokens"] as? Int ?? 0
                            u.outputTokens = usageDict["output_tokens"] as? Int ?? 0
                            u.cacheCreationTokens = usageDict["cache_creation_input_tokens"] as? Int ?? 0
                            u.cacheReadTokens = usageDict["cache_read_input_tokens"] as? Int ?? 0
                            u.messageCount = 1
                            turns[turnIndex].usage = turns[turnIndex].usage + u
                        }
                    }
                }

                if let contentBlocks = message?["content"] as? [[String: Any]] {
                    for block in contentBlocks {
                        guard let blockType = block["type"] as? String else { continue }
                        if blockType == "text", let text = block["text"] as? String {
                            if let existing = turns[turnIndex].assistantText {
                                turns[turnIndex].assistantText = existing + "\n" + text
                            } else {
                                turns[turnIndex].assistantText = text
                            }
                        } else if blockType == "tool_use" {
                            let toolId = (block["id"] as? String) ?? ""
                            let toolName = (block["name"] as? String) ?? ""
                            let input = block["input"]
                            let summary = summarizeInput(name: toolName, input: input)
                            let call = ToolCall(
                                id: toolId,
                                name: toolName,
                                inputSummary: summary,
                                startedAt: lineTimestamp ?? Date(),
                                durationMs: nil,
                                isError: false
                            )
                            turns[turnIndex].toolCalls.append(call)
                        }
                    }
                } else if let text = message?["content"] as? String {
                    if let existing = turns[turnIndex].assistantText {
                        turns[turnIndex].assistantText = existing + "\n" + text
                    } else {
                        turns[turnIndex].assistantText = text
                    }
                }
            }
        }

        guard !turns.isEmpty else { return nil }

        let project: String
        if let c = cwd, !c.isEmpty {
            let basename = (c as NSString).lastPathComponent
            project = (basename.isEmpty || basename == "/") ? "unknown" : basename
        } else {
            project = "unknown"
        }

        let firstUserPrompt = turns.compactMap { $0.userPrompt }.first
        let title = aiTitle ?? firstUserPrompt.map { String($0.prefix(80)) }

        var modelCounts: [String: Int] = [:]
        var modelFirstIndex: [String: Int] = [:]
        for (idx, turn) in turns.enumerated() {
            guard let m = turn.model else { continue }
            modelCounts[m, default: 0] += 1
            if modelFirstIndex[m] == nil {
                modelFirstIndex[m] = idx
            }
        }
        let mostFrequentModel = modelCounts.max { a, b in
            if a.value != b.value {
                return a.value < b.value
            }
            return (modelFirstIndex[a.key] ?? 0) > (modelFirstIndex[b.key] ?? 0)
        }?.key

        let startedAt = firstTimestamp ?? turns.first?.startedAt ?? Date()
        let lastActivity = lastTimestamp ?? turns.last?.startedAt ?? startedAt
        let totalUsage = turns.reduce(ClaudeUsageTotals()) { $0 + $1.usage }

        return Session(
            id: id,
            profile: profile,
            filePath: filePath,
            cwd: cwd,
            project: project,
            title: title,
            model: mostFrequentModel,
            startedAt: startedAt,
            lastActivity: lastActivity,
            turns: turns,
            usage: totalUsage
        )
    }

    /// Walks every profile's `projectsDir` recursively for *.jsonl files, uses
    /// `cache` to skip files whose (size, mtime) did not change, and returns all
    /// sessions sorted by lastActivity descending. Files that changed are
    /// re-parsed in full (transcripts are append-only but turn grouping needs
    /// the whole file; full re-parse of one changed file is acceptable).
    public static func scan(profiles: [Profile], cache: inout ScanCache) -> [Session] {
        var parsedCount = 0
        var allSessions: [Session] = []
        let fm = FileManager.default

        for profile in profiles {
            let projectsDir = profile.projectsDir
            guard fm.fileExists(atPath: projectsDir) else { continue }

            guard let enumerator = fm.enumerator(atPath: projectsDir) else { continue }

            while let relativePath = enumerator.nextObject() as? String {
                guard relativePath.hasSuffix(".jsonl") else { continue }
                let fullPath = (projectsDir as NSString).appendingPathComponent(relativePath)

                guard let attrs = try? fm.attributesOfItem(atPath: fullPath) else { continue }
                let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)

                let filename = (relativePath as NSString).lastPathComponent
                let sessionId = String(filename.dropLast(6))

                if let entry = cache.files[fullPath], entry.size == size, entry.mtime == mtime {
                    if let cachedSession = entry.session {
                        allSessions.append(cachedSession)
                    }
                } else {
                    parsedCount += 1
                    var session: Session? = nil
                    if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
                        session = buildSession(id: sessionId, profile: profile.id, filePath: fullPath, lines: lines)
                    }
                    cache.files[fullPath] = ScanCache.Entry(size: size, mtime: mtime, session: session)
                    if let s = session {
                        allSessions.append(s)
                    }
                }
            }
        }

        cache.lastParsedCount = parsedCount
        allSessions.sort { $0.lastActivity > $1.lastActivity }
        return allSessions
    }

    public struct ScanCache: Sendable {
        public init() {
            self.files = [:]
            self.lastParsedCount = 0
        }
        public var files: [String: Entry]          // filePath -> Entry
        public struct Entry: Sendable {
            public var size: UInt64
            public var mtime: Date
            public var session: Session?

            public init(size: UInt64, mtime: Date, session: Session? = nil) {
                self.size = size
                self.mtime = mtime
                self.session = session
            }
        }
        /// Number of files actually parsed during the last scan (for tests).
        public var lastParsedCount: Int = 0
    }
}
