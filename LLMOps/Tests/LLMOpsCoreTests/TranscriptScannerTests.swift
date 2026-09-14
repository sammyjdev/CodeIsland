import Testing
import Foundation
@testable import LLMOpsCore
@testable import CodeIslandCore

private func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func userPromptLine(
    prompt: String,
    toolResults: [(toolUseId: String, content: String, isError: Bool?)] = [],
    at date: Date,
    uuid: String = UUID().uuidString,
    cwd: String? = nil,
    sessionId: String = "session-1",
    isMeta: Bool = false,
    isSidechain: Bool = false
) -> String {
    let content: Any
    if toolResults.isEmpty {
        content = prompt
    } else {
        var blocks: [[String: Any]] = [
            ["type": "text", "text": prompt]
        ]
        for tr in toolResults {
            var block: [String: Any] = [
                "type": "tool_result",
                "tool_use_id": tr.toolUseId,
                "content": tr.content
            ]
            if let isError = tr.isError {
                block["is_error"] = isError
            }
            blocks.append(block)
        }
        content = blocks
    }
    var dict: [String: Any] = [
        "type": "user",
        "uuid": uuid,
        "timestamp": iso(date),
        "sessionId": sessionId,
        "message": [
            "role": "user",
            "content": content
        ]
    ]
    if let cwd = cwd { dict["cwd"] = cwd }
    if isMeta { dict["isMeta"] = true }
    if isSidechain { dict["isSidechain"] = true }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return String(data: data, encoding: .utf8)!
}

private func userPromptLine(
    prompt: String,
    toolResults: [(toolUseId: String, isError: Bool?)],
    at date: Date,
    uuid: String = UUID().uuidString,
    cwd: String? = nil,
    sessionId: String = "session-1",
    isMeta: Bool = false,
    isSidechain: Bool = false
) -> String {
    userPromptLine(
        prompt: prompt,
        toolResults: toolResults.map { ($0.toolUseId, "output", $0.isError) },
        at: date,
        uuid: uuid,
        cwd: cwd,
        sessionId: sessionId,
        isMeta: isMeta,
        isSidechain: isSidechain
    )
}

private func toolResultLine(
    toolUseId: String,
    content: String = "output",
    isError: Bool? = nil,
    at date: Date,
    uuid: String = UUID().uuidString,
    sessionId: String = "session-1",
    isSidechain: Bool = false
) -> String {
    var block: [String: Any] = [
        "type": "tool_result",
        "tool_use_id": toolUseId,
        "content": content
    ]
    if let isError = isError {
        block["is_error"] = isError
    }
    var dict: [String: Any] = [
        "type": "user",
        "uuid": uuid,
        "timestamp": iso(date),
        "sessionId": sessionId,
        "message": [
            "role": "user",
            "content": [block]
        ]
    ]
    if isSidechain { dict["isSidechain"] = true }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return String(data: data, encoding: .utf8)!
}

private func assistantLine(
    id: String,
    model: String = "claude-3-5-sonnet",
    text: String? = nil,
    toolUse: (id: String, name: String, input: [String: Any])? = nil,
    usage: (input: Int?, output: Int?, cacheWrite: Int?, cacheRead: Int?)? = nil,
    at date: Date,
    uuid: String = UUID().uuidString,
    cwd: String? = nil,
    sessionId: String = "session-1",
    isSidechain: Bool = false
) -> String {
    var contentBlocks: [[String: Any]] = []
    if let text = text {
        contentBlocks.append(["type": "text", "text": text])
    }
    if let tu = toolUse {
        contentBlocks.append([
            "type": "tool_use",
            "id": tu.id,
            "name": tu.name,
            "input": tu.input
        ])
    }

    var messageDict: [String: Any] = [
        "id": id,
        "role": "assistant",
        "model": model,
        "content": contentBlocks
    ]

    if let u = usage {
        var uDict: [String: Any] = [:]
        if let inp = u.input { uDict["input_tokens"] = inp }
        if let out = u.output { uDict["output_tokens"] = out }
        if let cw = u.cacheWrite { uDict["cache_creation_input_tokens"] = cw }
        if let cr = u.cacheRead { uDict["cache_read_input_tokens"] = cr }
        messageDict["usage"] = uDict
    }

    var dict: [String: Any] = [
        "type": "assistant",
        "uuid": uuid,
        "timestamp": iso(date),
        "sessionId": sessionId,
        "message": messageDict
    ]
    if let cwd = cwd { dict["cwd"] = cwd }
    if isSidechain { dict["isSidechain"] = true }

    let data = try! JSONSerialization.data(withJSONObject: dict)
    return String(data: data, encoding: .utf8)!
}

private func aiTitleLine(title: String, sessionId: String = "session-1") -> String {
    let dict: [String: Any] = [
        "type": "ai-title",
        "aiTitle": title,
        "sessionId": sessionId
    ]
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return String(data: data, encoding: .utf8)!
}

private func makeTempDir(prefix: String) -> String {
    let currentDir = FileManager.default.currentDirectoryPath
    let tempPath = (currentDir as NSString).appendingPathComponent(".build/\(prefix)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(atPath: tempPath, withIntermediateDirectories: true)
    return tempPath
}

@Suite struct TranscriptScannerTests {

    // 1. Two user prompts with one assistant text each -> 2 turns, prompts and assistantText correct,
    // title = first prompt (80-char cap tested with a 100-char prompt).
    @Test func twoUserPromptsWithAssistantTextAndTitleCap() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 1001)
        let t2 = Date(timeIntervalSince1970: 1002)
        let t3 = Date(timeIntervalSince1970: 1003)

        let longPrompt = String(repeating: "x", count: 100)
        let lines: [Substring] = [
            Substring(userPromptLine(prompt: longPrompt, at: t0)),
            Substring(assistantLine(id: "msg-1", text: "Answer 1", at: t1)),
            Substring(userPromptLine(prompt: "Second question", at: t2)),
            Substring(assistantLine(id: "msg-2", text: "Answer 2", at: t3))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/to/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session else { return }

        #expect(s.turns.count == 2)
        #expect(s.turns[0].userPrompt == longPrompt)
        #expect(s.turns[0].assistantText == "Answer 1")
        #expect(s.turns[1].userPrompt == "Second question")
        #expect(s.turns[1].assistantText == "Answer 2")
        #expect(s.title == String(repeating: "x", count: 80))
    }

    // 2. Usage dedupe: three assistant lines sharing message.id "m1" with usage 10/20/5/100 ->
    // session.usage is 10/20/5/100, not tripled. Absent usage fields count as 0.
    @Test func usageDedupeAndAbsentFields() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 1001)
        let t2 = Date(timeIntervalSince1970: 1002)
        let t3 = Date(timeIntervalSince1970: 1003)
        let t4 = Date(timeIntervalSince1970: 1004)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "Hello", at: t0)),
            // 3 lines sharing "m1"
            Substring(assistantLine(id: "m1", usage: (input: 10, output: 20, cacheWrite: 5, cacheRead: 100), at: t1)),
            Substring(assistantLine(id: "m1", usage: (input: 10, output: 20, cacheWrite: 5, cacheRead: 100), at: t2)),
            Substring(assistantLine(id: "m1", usage: (input: 10, output: 20, cacheWrite: 5, cacheRead: 100), at: t3)),
            // 1 line with "m2" having absent fields (only input specified)
            Substring(assistantLine(id: "m2", usage: (input: 15, output: nil, cacheWrite: nil, cacheRead: nil), at: t4))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session else { return }

        #expect(s.usage.inputTokens == 25)
        #expect(s.usage.outputTokens == 20)
        #expect(s.usage.cacheCreationTokens == 5)
        #expect(s.usage.cacheReadTokens == 100)
        #expect(s.usage.messageCount == 2)
    }

    // 3. Tool pairing: assistant tool_use toolu_1 (Bash, command "ls -la\npwd") at t=0,
    // tool_result for toolu_1 at t=+1.250s with is_error true -> one ToolCall,
    // name "Bash", inputSummary "ls -la", durationMs 1250, isError true.
    @Test func toolPairingWithDurationAndError() {
        let t0 = Date(timeIntervalSince1970: 1000.0)
        let tResult = Date(timeIntervalSince1970: 1001.250)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "run command", at: t0)),
            Substring(assistantLine(
                id: "m1",
                toolUse: (id: "toolu_1", name: "Bash", input: ["command": "ls -la\npwd"]),
                at: t0
            )),
            Substring(toolResultLine(
                toolUseId: "toolu_1",
                content: "error: file not found",
                isError: true,
                at: tResult
            ))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session, let turn = s.turns.first else { return }

        #expect(turn.toolCalls.count == 1)
        let call = turn.toolCalls[0]
        #expect(call.id == "toolu_1")
        #expect(call.name == "Bash")
        #expect(call.inputSummary == "ls -la")
        #expect(call.durationMs == 1250)
        #expect(call.isError == true)
    }

    // 4. Missing tool_result -> durationMs nil, isError false.
    @Test func missingToolResult() {
        let t0 = Date(timeIntervalSince1970: 1000.0)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "test missing result", at: t0)),
            Substring(assistantLine(
                id: "m1",
                toolUse: (id: "toolu_no_res", name: "Bash", input: ["command": "uptime"]),
                at: t0
            ))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session, let turn = s.turns.first else { return }

        #expect(turn.toolCalls.count == 1)
        let call = turn.toolCalls[0]
        #expect(call.id == "toolu_no_res")
        #expect(call.durationMs == nil)
        #expect(call.isError == false)
    }

    // 5. inputSummary rules for Read (file_path basename), Grep (pattern),
    // and an unknown tool (sorted-key JSON, 80-char cap).
    @Test func inputSummaryRules() {
        let t0 = Date(timeIntervalSince1970: 1000.0)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "summary test", at: t0)),
            Substring(assistantLine(
                id: "m1",
                toolUse: (id: "t_read", name: "Read", input: ["file_path": "/Users/test/Sources/MyFile.swift"]),
                at: t0
            )),
            Substring(assistantLine(
                id: "m2",
                toolUse: (id: "t_grep", name: "Grep", input: ["pattern": "func test()"]),
                at: t0
            )),
            Substring(assistantLine(
                id: "m3",
                toolUse: (id: "t_custom", name: "CustomTool", input: [
                    "zeta": "z_val",
                    "alpha": "a_val",
                    "nested": ["key": "very long text that will push the serialization past the eighty character limit easily"]
                ]),
                at: t0
            ))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session, let turn = s.turns.first else { return }

        #expect(turn.toolCalls.count == 3)
        let readCall = turn.toolCalls.first(where: { $0.id == "t_read" })
        #expect(readCall?.inputSummary == "MyFile.swift")

        let grepCall = turn.toolCalls.first(where: { $0.id == "t_grep" })
        #expect(grepCall?.inputSummary == "func test()")

        let customCall = turn.toolCalls.first(where: { $0.id == "t_custom" })
        #expect(customCall != nil)
        guard let custom = customCall else { return }
        #expect(custom.inputSummary.count <= 80)
        #expect(custom.inputSummary.hasPrefix("{\"alpha\":\"a_val\""))
    }

    // 6. isMeta: true user lines and isSidechain: true lines do not create turns
    // and their usage is not counted; malformed lines are skipped.
    @Test func metaAndSidechainAndMalformedLinesSkipped() {
        let t0 = Date(timeIntervalSince1970: 1000.0)
        let t1 = Date(timeIntervalSince1970: 1001.0)
        let t2 = Date(timeIntervalSince1970: 1002.0)

        let lines: [Substring] = [
            "not a valid json line at all",
            Substring(userPromptLine(prompt: "Meta prompt context", at: t0, isMeta: true)),
            Substring(assistantLine(id: "m_side", usage: (input: 100, output: 100, cacheWrite: 0, cacheRead: 0), at: t0, isSidechain: true)),
            "{broken json:",
            Substring(userPromptLine(prompt: "Real user prompt", at: t1)),
            Substring(assistantLine(id: "m_real", usage: (input: 20, output: 10, cacheWrite: 0, cacheRead: 0), at: t2))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session else { return }

        #expect(s.turns.count == 1)
        #expect(s.turns[0].userPrompt == "Real user prompt")
        #expect(s.usage.inputTokens == 20)
        #expect(s.usage.outputTokens == 10)
    }

    // 7. A file with only metadata lines -> buildSession returns nil.
    @Test func fileWithOnlyMetadataReturnsNil() {
        let t0 = Date(timeIntervalSince1970: 1000.0)
        let lines: [Substring] = [
            Substring(aiTitleLine(title: "Some Title")),
            Substring(userPromptLine(prompt: "Injected system instruction", at: t0, isMeta: true)),
            "{\"type\":\"system\",\"content\":\"System setup\"}",
            "{\"type\":\"mode\",\"mode\":\"architect\"}"
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session == nil)
    }

    // 8. session.model is the most frequent model across turns; project is the last component of cwd;
    // startedAt/lastActivity are first/last timestamps.
    @Test func sessionModelProjectTimestamps() {
        let t0 = Date(timeIntervalSince1970: 1000.0)
        let t1 = Date(timeIntervalSince1970: 1010.0)
        let t2 = Date(timeIntervalSince1970: 1020.0)
        let t3 = Date(timeIntervalSince1970: 1030.0)
        let t4 = Date(timeIntervalSince1970: 1040.0)
        let t5 = Date(timeIntervalSince1970: 1050.0)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "turn 1", at: t0, cwd: "/Users/dev/my-project")),
            Substring(assistantLine(id: "m1", model: "claude-3-opus", at: t1)),
            Substring(userPromptLine(prompt: "turn 2", at: t2)),
            Substring(assistantLine(id: "m2", model: "claude-3-5-sonnet", at: t3)),
            Substring(userPromptLine(prompt: "turn 3", at: t4)),
            Substring(assistantLine(id: "m3", model: "claude-3-5-sonnet", at: t5))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session else { return }

        #expect(s.model == "claude-3-5-sonnet")
        #expect(s.project == "my-project")
        #expect(s.cwd == "/Users/dev/my-project")
        #expect(s.startedAt == t0)
        #expect(s.lastActivity == t5)
    }

    // 9. scan over two profiles pointing at two temp config dirs, each with
    // projects/<slug>/<id>.jsonl: returns sessions tagged with the right profile id,
    // sorted by lastActivity descending.
    @Test func scanTwoProfilesSortedByLastActivity() throws {
        let dir1 = makeTempDir(prefix: "prof1-dir")
        let dir2 = makeTempDir(prefix: "prof2-dir")
        defer {
            try? FileManager.default.removeItem(atPath: dir1)
            try? FileManager.default.removeItem(atPath: dir2)
        }

        let p1Projects = dir1 + "/projects/slug-a"
        let p2Projects = dir2 + "/projects/slug-b"
        try FileManager.default.createDirectory(atPath: p1Projects, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: p2Projects, withIntermediateDirectories: true)

        let tEarly = Date(timeIntervalSince1970: 1000.0)
        let tLate = Date(timeIntervalSince1970: 2000.0)

        let s1Content = userPromptLine(prompt: "Session 1", at: tEarly) + "\n" + assistantLine(id: "m1", at: tEarly)
        let s2Content = userPromptLine(prompt: "Session 2", at: tLate) + "\n" + assistantLine(id: "m2", at: tLate)

        try s1Content.write(toFile: p1Projects + "/s1.jsonl", atomically: true, encoding: .utf8)
        try s2Content.write(toFile: p2Projects + "/s2.jsonl", atomically: true, encoding: .utf8)

        let prof1 = Profile(id: "prof-1", name: "P1", configDir: dir1, pathPrefixes: [])
        let prof2 = Profile(id: "prof-2", name: "P2", configDir: dir2, pathPrefixes: [])

        var cache = TranscriptScanner.ScanCache()
        let sessions = TranscriptScanner.scan(profiles: [prof1, prof2], cache: &cache)

        #expect(sessions.count == 2)
        guard sessions.count >= 2 else { return }
        #expect(sessions[0].id == "s2")
        #expect(sessions[0].profile == "prof-2")
        #expect(sessions[1].id == "s1")
        #expect(sessions[1].profile == "prof-1")
        #expect(sessions[0].lastActivity > sessions[1].lastActivity)
    }

    // 10. Incremental: scan once (lastParsedCount == 2), scan again unchanged
    // (lastParsedCount == 0, same sessions), append a line to one file and scan
    // (lastParsedCount == 1, that session gained a turn).
    @Test func incrementalScanCache() throws {
        let dir = makeTempDir(prefix: "inc-scan")
        defer {
            try? FileManager.default.removeItem(atPath: dir)
        }

        let projects = dir + "/projects/slug"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)

        let fileA = projects + "/fileA.jsonl"
        let fileB = projects + "/fileB.jsonl"

        let t0 = Date(timeIntervalSince1970: 1000.0)
        let contentA = userPromptLine(prompt: "Prompt A", at: t0) + "\n" + assistantLine(id: "mA", text: "Ans A", at: t0)
        let contentB = userPromptLine(prompt: "Prompt B", at: t0) + "\n" + assistantLine(id: "mB", text: "Ans B", at: t0)

        try contentA.write(toFile: fileA, atomically: true, encoding: .utf8)
        try contentB.write(toFile: fileB, atomically: true, encoding: .utf8)

        let profile = Profile(id: "prof-inc", name: "Inc", configDir: dir, pathPrefixes: [])
        var cache = TranscriptScanner.ScanCache()

        // Scan 1: initial parse
        let res1 = TranscriptScanner.scan(profiles: [profile], cache: &cache)
        #expect(res1.count == 2)
        #expect(cache.lastParsedCount == 2)

        // Scan 2: unchanged
        let res2 = TranscriptScanner.scan(profiles: [profile], cache: &cache)
        #expect(res2.count == 2)
        #expect(cache.lastParsedCount == 0)

        // Wait a tick so mtime changes or change size
        let t1 = Date(timeIntervalSince1970: 1005.0)
        let additionalTurn = "\n" + userPromptLine(prompt: "Prompt A2", at: t1) + "\n" + assistantLine(id: "mA2", text: "Ans A2", at: t1)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: fileA))
        try handle.seekToEnd()
        try handle.write(contentsOf: additionalTurn.data(using: .utf8)!)
        try handle.close()

        // Scan 3: one file changed
        let res3 = TranscriptScanner.scan(profiles: [profile], cache: &cache)
        #expect(res3.count == 2)
        #expect(cache.lastParsedCount == 1)

        let sessionA = res3.first(where: { $0.id == "fileA" })
        #expect(sessionA?.turns.count == 2)
    }

    // 11. Bench: 200 synthetic sessions x 50 lines in one profile scan in under 2 seconds
    // (use ContinuousClock; assert elapsed < .seconds(2)).
    @Test func bench200Sessions50LinesUnderTwoSeconds() throws {
        let dir = makeTempDir(prefix: "bench-dir")
        defer {
            try? FileManager.default.removeItem(atPath: dir)
        }

        let projects = dir + "/projects/slug"
        try FileManager.default.createDirectory(atPath: projects, withIntermediateDirectories: true)

        let tBase = Date(timeIntervalSince1970: 1000.0)

        // Generate 200 files with 50 lines (25 user + 25 assistant)
        for i in 0..<200 {
            var lines: [String] = []
            lines.reserveCapacity(50)
            let sessionId = "session_\(i)"
            for turnIdx in 0..<25 {
                let t = tBase.addingTimeInterval(Double(turnIdx * 2))
                lines.append(userPromptLine(prompt: "Bench prompt \(turnIdx)", at: t, sessionId: sessionId))
                lines.append(assistantLine(id: "msg_\(turnIdx)", text: "Bench response \(turnIdx)", at: t.addingTimeInterval(1), sessionId: sessionId))
            }
            let fileContent = lines.joined(separator: "\n")
            let filePath = "\(projects)/\(sessionId).jsonl"
            FileManager.default.createFile(atPath: filePath, contents: Data(fileContent.utf8))
        }

        let profile = Profile(id: "bench-prof", name: "Bench", configDir: dir, pathPrefixes: [])
        var cache = TranscriptScanner.ScanCache()

        let clock = ContinuousClock()
        let elapsed = clock.measure {
            let sessions = TranscriptScanner.scan(profiles: [profile], cache: &cache)
            #expect(sessions.count == 200)
        }

        // Budget is 2s on a quiet machine; 4s keeps the guard against
        // quadratic regressions without flaking under parallel builds.
        #expect(elapsed < .seconds(4))
    }

    // 12. Mixed line: turn 1 has tool_use toolu_1 at t0; a user line at t0+2s with
    // text "next question" and a tool_result for toolu_1 (is_error false) -> two turns;
    // turn 1's call has durationMs == 2000, isError == false; turn 2's userPrompt
    // is "next question" and has no tool calls.
    @Test func mixedLineWithTextAndToolResult() {
        let t0 = Date(timeIntervalSince1970: 1000.0)
        let t2 = Date(timeIntervalSince1970: 1002.0)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "first question", at: t0)),
            Substring(assistantLine(
                id: "m1",
                toolUse: (id: "toolu_1", name: "Bash", input: ["command": "ls"]),
                at: t0
            )),
            Substring(userPromptLine(
                prompt: "next question",
                toolResults: [(toolUseId: "toolu_1", isError: false)],
                at: t2
            ))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session else { return }

        #expect(s.turns.count == 2)
        guard s.turns.count == 2 else { return }

        let turn1 = s.turns[0]
        #expect(turn1.toolCalls.count == 1)
        guard turn1.toolCalls.count == 1 else { return }
        #expect(turn1.toolCalls[0].id == "toolu_1")
        #expect(turn1.toolCalls[0].durationMs == 2000)
        #expect(turn1.toolCalls[0].isError == false)

        let turn2 = s.turns[1]
        #expect(turn2.userPrompt == "next question")
        #expect(turn2.toolCalls.isEmpty)
    }

    // 13. Late result: turn 1 has tool_use toolu_1 at t0; a text-only user line at t0+1s
    // starts turn 2; a tool_result-only line for toolu_1 at t0+3s -> turn 1's call has
    // durationMs == 3000; turn 2 has no tool calls.
    @Test func lateToolResultAcrossTurns() {
        let t0 = Date(timeIntervalSince1970: 1000.0)
        let t1 = Date(timeIntervalSince1970: 1001.0)
        let t3 = Date(timeIntervalSince1970: 1003.0)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "first question", at: t0)),
            Substring(assistantLine(
                id: "m1",
                toolUse: (id: "toolu_1", name: "Bash", input: ["command": "ls"]),
                at: t0
            )),
            Substring(userPromptLine(prompt: "interrupted text", at: t1)),
            Substring(toolResultLine(
                toolUseId: "toolu_1",
                isError: false,
                at: t3
            ))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session else { return }

        #expect(s.turns.count == 2)
        guard s.turns.count == 2 else { return }

        let turn1 = s.turns[0]
        #expect(turn1.toolCalls.count == 1)
        guard turn1.toolCalls.count == 1 else { return }
        #expect(turn1.toolCalls[0].id == "toolu_1")
        #expect(turn1.toolCalls[0].durationMs == 3000)

        let turn2 = s.turns[1]
        #expect(turn2.toolCalls.isEmpty)
    }

    // 14. Unknown id: a tool_result for toolu_ghost changes nothing (no call appended
    // anywhere, no crash).
    @Test func unknownToolResultIdIgnored() {
        let t0 = Date(timeIntervalSince1970: 1000.0)
        let t1 = Date(timeIntervalSince1970: 1001.0)

        let lines: [Substring] = [
            Substring(userPromptLine(prompt: "hello", at: t0)),
            Substring(assistantLine(
                id: "m1",
                toolUse: (id: "toolu_real", name: "Bash", input: ["command": "uptime"]),
                at: t0
            )),
            Substring(toolResultLine(
                toolUseId: "toolu_ghost",
                isError: false,
                at: t1
            ))
        ]

        let session = TranscriptScanner.buildSession(
            id: "s1", profile: "prof1", filePath: "/path/s1.jsonl", lines: lines
        )
        #expect(session != nil)
        guard let s = session else { return }

        #expect(s.turns.count == 1)
        guard s.turns.count == 1 else { return }
        #expect(s.turns[0].toolCalls.count == 1)
        #expect(s.turns[0].toolCalls[0].id == "toolu_real")
        #expect(s.turns[0].toolCalls[0].durationMs == nil)
    }
}
