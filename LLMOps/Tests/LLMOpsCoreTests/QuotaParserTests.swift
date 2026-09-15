import Foundation
import Testing
@testable import LLMOpsCore

@Suite("QuotaParserTests")
struct QuotaParserTests {
    private var fixedNow: Date {
        Date(timeIntervalSince1970: 1789300000)
    }

    private func makeFractionalDateFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    // 1. Claude sample parsing
    @Test("Claude: parsed sample windows, resetsAt, worstUsedPercent")
    func claudeSampleParsing() throws {
        let payload = """
        {
          "five_hour": {
            "utilization": 53.0,
            "resets_at": "2026-09-15T03:20:00.286331+00:00"
          },
          "seven_day": {
            "utilization": 49.0,
            "resets_at": "2026-09-22T03:20:00.123456+00:00"
          }
        }
        """
        let data = Data(payload.utf8)
        let snapshot = try ClaudeQuotaParser.parse(data, now: fixedNow)

        #expect(snapshot.provider == .claude)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.worstUsedPercent == 53.0)
        #expect(snapshot.fetchedAt == fixedNow)

        let w0 = snapshot.windows[0]
        #expect(w0.label == "5h")
        #expect(w0.usedPercent == 53.0)
        let expectedDate0 = makeFractionalDateFormatter().date(from: "2026-09-15T03:20:00.286331+00:00")!
        #expect(w0.resetsAt != nil)
        #expect(abs(w0.resetsAt!.timeIntervalSince1970 - expectedDate0.timeIntervalSince1970) < 0.001)

        let w1 = snapshot.windows[1]
        #expect(w1.label == "7d")
        #expect(w1.usedPercent == 49.0)
        let expectedDate1 = makeFractionalDateFormatter().date(from: "2026-09-22T03:20:00.123456+00:00")!
        #expect(w1.resetsAt != nil)
        #expect(abs(w1.resetsAt!.timeIntervalSince1970 - expectedDate1.timeIntervalSince1970) < 0.001)
    }

    // 2. Claude null blocks throw badPayload, single window works
    @Test("Claude: null blocks throw badPayload, single window parses")
    func claudeNullBlocksAndSingleWindow() throws {
        let nullPayload = "{\"five_hour\": null, \"seven_day\": null}"
        #expect(throws: QuotaError.badPayload("both five_hour and seven_day missing")) {
            try ClaudeQuotaParser.parse(Data(nullPayload.utf8), now: fixedNow)
        }

        let singlePayload = "{\"seven_day\": {\"utilization\": 10, \"resets_at\": \"2026-09-20T07:00:00+00:00\"}}"
        let snap = try ClaudeQuotaParser.parse(Data(singlePayload.utf8), now: fixedNow)
        #expect(snap.windows.count == 1)
        #expect(snap.windows[0].label == "7d")
        #expect(snap.windows[0].usedPercent == 10.0)
    }

    // 3. Codex parse(fileContents:)
    @Test("Codex: parse fileContents finds last line with primary rate limits")
    func codexParseFileContents() throws {
        let fixture = """
        {"rate_limits":{"limit_id":"premium","primary":null}}
        {"rate_limits":{"limit_id":"codex","primary":{"used_percent":82.0,"window_minutes":300,"resets_at":1788499442},"secondary":{"used_percent":33.0,"window_minutes":10080,"resets_at":1788785228},"plan_type":"plus"}}
        {"other":"data"}
        """
        let snap = CodexQuotaParser.parse(fileContents: fixture, now: fixedNow)
        #expect(snap != nil)
        guard let snap else { return }

        #expect(snap.provider == .codex)
        #expect(snap.windows.count == 2)
        #expect(snap.windows[0].label == "5h")
        #expect(snap.windows[0].usedPercent == 82.0)
        #expect(snap.windows[0].resetsAt == Date(timeIntervalSince1970: 1788499442))

        #expect(snap.windows[1].label == "7d")
        #expect(snap.windows[1].usedPercent == 33.0)
        #expect(snap.windows[1].resetsAt == Date(timeIntervalSince1970: 1788785228))

        #expect(snap.detail == "plan plus")

        let nullFixture = "{\"rate_limits\":{\"limit_id\":\"premium\",\"primary\":null}}"
        #expect(CodexQuotaParser.parse(fileContents: nullFixture, now: fixedNow) == nil)
    }

    // 4. Codex latest(in:limit:now:)
    @Test("Codex: latest in directory finds newest matching rollout")
    func codexLatestInDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dirA = tempDir.appendingPathComponent("a")
        let dirB = tempDir.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let populatedContent = """
        {"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1788499442},"plan_type":"plus"}}
        """
        let nullContent = """
        {"rate_limits":{"limit_id":"codex","primary":null}}
        """

        let fileOld = dirA.appendingPathComponent("rollout-old.jsonl")
        let fileNew = dirB.appendingPathComponent("rollout-new.jsonl")

        try populatedContent.write(to: fileOld, atomically: true, encoding: .utf8)
        try nullContent.write(to: fileNew, atomically: true, encoding: .utf8)

        let oldDate = Date(timeIntervalSince1970: 1000)
        let newDate = Date(timeIntervalSince1970: 2000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fileOld.path)
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: fileNew.path)

        let result = try CodexQuotaParser.latest(in: tempDir, limit: 10, now: fixedNow)
        #expect(result.windows.count == 1)
        #expect(result.windows[0].usedPercent == 42.0)

        let emptyDir = tempDir.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        #expect(throws: QuotaError.notFound("no rollout with rate limits")) {
            try CodexQuotaParser.latest(in: emptyDir, limit: 10, now: fixedNow)
        }
    }

    // 5. Antigravity parse
    @Test("Antigravity: filter models, compute usedPercent, detail is email")
    func antigravityParse() throws {
        let fixture = """
        {
          "email": "x@y",
          "models": [
            {
              "label": "Gemini 3.8 Flash (Medium)",
              "modelId": "gemini-3.8-flash-medium",
              "remainingPercentage": 0.77,
              "isExhausted": false,
              "resetTime": "2026-09-15T04:42:37Z",
              "isAutocompleteOnly": false
            },
            {
              "label": "Claude Opus",
              "modelId": "claude-opus",
              "remainingPercentage": 1.0,
              "isExhausted": false,
              "resetTime": "2026-09-15T04:42:37Z",
              "isAutocompleteOnly": false
            },
            {
              "label": "Gemini 2.5 Pro",
              "modelId": "gemini-2.5-pro",
              "remainingPercentage": 0.5,
              "isExhausted": false,
              "resetTime": "2026-09-15T04:42:37Z",
              "isAutocompleteOnly": true
            },
            {
              "label": "Gemini 3 Flash",
              "modelId": "gemini-3-flash",
              "remainingPercentage": 0.2,
              "isExhausted": false,
              "resetTime": "2026-09-15T04:42:37Z",
              "isAutocompleteOnly": false
            }
          ]
        }
        """
        let data = Data(fixture.utf8)
        let snap = try AntigravityQuotaParser.parse(data, now: fixedNow)

        #expect(snap.provider == .antigravity)
        #expect(snap.detail == "x@y")
        #expect(snap.windows.count == 3)

        #expect(snap.windows[0].label == "Gemini 3.8 Flash (Medium)")
        #expect(snap.windows[0].usedPercent == 23.0)

        #expect(snap.windows[1].label == "Claude Opus")
        #expect(snap.windows[1].usedPercent == 0.0)

        #expect(snap.windows[2].label == "Gemini 3 Flash")
        #expect(snap.windows[2].usedPercent == 80.0)

        #expect(snap.worstUsedPercent == 80.0)

        let emptyPayload = Data("{\"email\":\"x\",\"models\":[]}".utf8)
        #expect(throws: QuotaError.badPayload("models array missing or empty")) {
            try AntigravityQuotaParser.parse(emptyPayload, now: fixedNow)
        }
    }

    // 6. Z.ai parse
    @Test("Zai: parse token limits, epoch ms, detail is level")
    func zaiParse() throws {
        let fixture = """
        {
          "data": {
            "level": "pro",
            "limits": [
              {
                "type": "TOKENS_LIMIT",
                "unit": 3,
                "percentage": 22,
                "nextResetTime": 1789443226585
              },
              {
                "type": "TOKENS_LIMIT",
                "unit": 6,
                "percentage": 55,
                "nextResetTime": 1789697025984
              },
              {
                "type": "TIME_LIMIT",
                "unit": 1,
                "percentage": 10,
                "nextResetTime": 1789443226585
              }
            ]
          }
        }
        """
        let snap = try ZaiQuotaParser.parse(Data(fixture.utf8), now: fixedNow)
        #expect(snap.provider == .zai)
        #expect(snap.detail == "level pro")
        #expect(snap.windows.count == 2)

        #expect(snap.windows[0].label == "5h")
        #expect(snap.windows[0].usedPercent == 22.0)
        #expect(snap.windows[0].resetsAt == Date(timeIntervalSince1970: 1789443226.585))

        #expect(snap.windows[1].label == "7d")
        #expect(snap.windows[1].usedPercent == 55.0)
        #expect(snap.windows[1].resetsAt == Date(timeIntervalSince1970: 1789697025.984))

        let onlyTimeLimit = """
        {
          "data": {
            "level": "pro",
            "limits": [
              {
                "type": "TIME_LIMIT",
                "unit": 1,
                "percentage": 10,
                "nextResetTime": 1789443226585
              }
            ]
          }
        }
        """
        #expect(throws: QuotaError.badPayload("no valid token limits found")) {
            try ZaiQuotaParser.parse(Data(onlyTimeLimit.utf8), now: fixedNow)
        }
    }

    // 7. ZaiKey.fromOpencodeAuth
    @Test("ZaiKey: loads key from auth json or throws missingCredential")
    func zaiKeyAuth() throws {
        let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent("auth-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let validContent = "{\"zai-coding-plan\":{\"type\":\"api\",\"key\":\"abc\"}}"
        try validContent.write(to: tempFile, atomically: true, encoding: .utf8)
        let key = try ZaiKey.fromOpencodeAuth(path: tempFile.path)
        #expect(key == "abc")

        let emptyContent = "{}"
        try emptyContent.write(to: tempFile, atomically: true, encoding: .utf8)
        #expect(throws: QuotaError.missingCredential("zai-coding-plan.key missing in \(tempFile.path)")) {
            try ZaiKey.fromOpencodeAuth(path: tempFile.path)
        }
    }

    // 8. ClaudeQuotaProvider
    @Test("ClaudeQuotaProvider: injected request and token loader")
    func claudeQuotaProvider() async throws {
        let capturedRequest = CapturedRequest()
        let samplePayload = """
        {
          "five_hour": {"utilization": 53.0, "resets_at": "2026-09-15T03:20:00.286331+00:00"},
          "seven_day": {"utilization": 49.0, "resets_at": "2026-09-22T03:20:00.123456+00:00"}
        }
        """

        let provider = ClaudeQuotaProvider(
            tokenLoader: { "tok" },
            request: { req in
                await capturedRequest.record(req)
                return Data(samplePayload.utf8)
            }
        )

        let snap = try await provider.fetch(now: fixedNow)
        let req = await capturedRequest.value
        #expect(req?.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(req?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(snap.windows.count == 2)

        enum TestError: Error { case failed }
        let failingProvider = ClaudeQuotaProvider(
            tokenLoader: { throw TestError.failed },
            request: { _ in Data() }
        )

        do {
            _ = try await failingProvider.fetch(now: fixedNow)
            #expect(Bool(false), "Expected missingCredential error")
        } catch let QuotaError.missingCredential(msg) {
            #expect(!msg.isEmpty)
        } catch {
            #expect(Bool(false), "Expected missingCredential, got \(error)")
        }
    }

    // 9. ZaiQuotaProvider
    @Test("ZaiQuotaProvider: injected request and key loader")
    func zaiQuotaProvider() async throws {
        let capturedRequest = CapturedRequest()
        let fixture = """
        {
          "data": {
            "level": "pro",
            "limits": [
              {"type": "TOKENS_LIMIT", "unit": 3, "percentage": 22, "nextResetTime": 1789443226585},
              {"type": "TOKENS_LIMIT", "unit": 6, "percentage": 55, "nextResetTime": 1789697025984}
            ]
          }
        }
        """

        let provider = ZaiQuotaProvider(
            keyLoader: { "k" },
            request: { req in
                await capturedRequest.record(req)
                return Data(fixture.utf8)
            }
        )

        let snap = try await provider.fetch(now: fixedNow)
        let req = await capturedRequest.value
        #expect(req?.url?.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
        #expect(req?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(snap.windows.count == 2)
    }

    // 10. AntigravityQuotaProvider
    @Test("AntigravityQuotaProvider: injected runner and default runner against stub")
    func antigravityQuotaProvider() async throws {
        let fixture = """
        {
          "email": "x@y",
          "models": [
            {
              "label": "Gemini 3.8 Flash (Medium)",
              "remainingPercentage": 0.77,
              "isAutocompleteOnly": false
            },
            {
              "label": "Claude Opus",
              "remainingPercentage": 1.0,
              "isAutocompleteOnly": false
            },
            {
              "label": "Gemini 3 Flash",
              "remainingPercentage": 0.2,
              "isAutocompleteOnly": false
            }
          ]
        }
        """

        // Injected runner
        let provider = AntigravityQuotaProvider(
            executablePath: "/mock/bin/antigravity-usage",
            runner: { _ in Data(fixture.utf8) }
        )
        let snap = try await provider.fetch(now: fixedNow)
        #expect(snap.windows.count == 3)

        // Default runner with stub script
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ag-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let successScript = tempDir.appendingPathComponent("success-stub.sh")
        let scriptContent = """
        #!/bin/sh
        cat << 'EOF'
        \(fixture)
        EOF
        """
        try scriptContent.write(to: successScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: successScript.path)

        let defaultProvider = AntigravityQuotaProvider(executablePath: successScript.path)
        let defaultSnap = try await defaultProvider.fetch(now: fixedNow)
        #expect(defaultSnap.windows.count == 3)

        // Stub that exits with error and stderr "nope"
        let failScript = tempDir.appendingPathComponent("fail-stub.sh")
        let failContent = """
        #!/bin/sh
        echo "nope" >&2
        exit 2
        """
        try failContent.write(to: failScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failScript.path)

        let failProvider = AntigravityQuotaProvider(executablePath: failScript.path)
        do {
            _ = try await failProvider.fetch(now: fixedNow)
            #expect(Bool(false), "Expected subprocess error")
        } catch let QuotaError.subprocess(msg) {
            #expect(msg.contains("nope"))
        } catch {
            #expect(Bool(false), "Expected QuotaError.subprocess, got \(error)")
        }
    }

    // 11. OpenRouter sample parsing
    @Test("OpenRouter: parse credits and key limit windows, detail formatting")
    func openRouterSampleParsing() throws {
        let creditsPayload = """
        {"data":{"total_credits":74,"total_usage":69.353701717}}
        """
        let keyPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":5,"limit_reset":"daily","limit_remaining":5,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """
        let snapshot = try OpenRouterQuotaParser.parse(
            creditsData: Data(creditsPayload.utf8),
            keyData: Data(keyPayload.utf8),
            now: fixedNow
        )

        #expect(snapshot.provider == .openrouter)
        #expect(snapshot.windows.count == 2)
        #expect(snapshot.windows[0].label == "credits")
        #expect(abs(snapshot.windows[0].usedPercent - 93.7) < 0.1)
        #expect(snapshot.windows[0].resetsAt == nil)

        #expect(snapshot.windows[1].label == "key limit (daily)")
        #expect(snapshot.windows[1].usedPercent == 0.0)
        #expect(snapshot.windows[1].resetsAt == nil)

        #expect(snapshot.detail == "$4.65 left of $74.00, today $0.0000, week $0.0079, month $0.0583")
    }

    // 12. OpenRouter null limits and edge cases
    @Test("OpenRouter: null limits yields only credits window, zero total credits, missing data throws badPayload")
    func openRouterNullLimitsAndEdgeCases() throws {
        let creditsPayload = """
        {"data":{"total_credits":74,"total_usage":69.353701717}}
        """
        let keyPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":null,"limit_reset":"daily","limit_remaining":null,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """
        let snap = try OpenRouterQuotaParser.parse(
            creditsData: Data(creditsPayload.utf8),
            keyData: Data(keyPayload.utf8),
            now: fixedNow
        )
        #expect(snap.windows.count == 1)
        #expect(snap.windows[0].label == "credits")

        let zeroCreditsPayload = """
        {"data":{"total_credits":0,"total_usage":0}}
        """
        let zeroSnap = try OpenRouterQuotaParser.parse(
            creditsData: Data(zeroCreditsPayload.utf8),
            keyData: Data(keyPayload.utf8),
            now: fixedNow
        )
        #expect(zeroSnap.windows.count == 1)
        #expect(zeroSnap.windows[0].usedPercent == 0.0)

        let nilRemainingPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":5,"limit_reset":"daily","limit_remaining":null,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """
        let nilRemainingSnap = try OpenRouterQuotaParser.parse(
            creditsData: Data(creditsPayload.utf8),
            keyData: Data(nilRemainingPayload.utf8),
            now: fixedNow
        )
        #expect(nilRemainingSnap.windows.count == 2)
        #expect(nilRemainingSnap.windows[1].label == "key limit (daily)")
        #expect(nilRemainingSnap.windows[1].usedPercent == 0.0)

        let missingDataCredits = """
        {"other":123}
        """
        do {
            _ = try OpenRouterQuotaParser.parse(
                creditsData: Data(missingDataCredits.utf8),
                keyData: Data(keyPayload.utf8),
                now: fixedNow
            )
            #expect(Bool(false), "Expected badPayload error")
        } catch let QuotaError.badPayload(msg) {
            #expect(!msg.isEmpty)
        } catch {
            #expect(Bool(false), "Expected badPayload, got \(error)")
        }
    }

    // 13. OpenRouterQuotaProvider
    @Test("OpenRouterQuotaProvider: captured URLRequests and keyLoader error")
    func openRouterQuotaProvider() async throws {
        let captured = CapturedRequests()
        let creditsPayload = """
        {"data":{"total_credits":74,"total_usage":69.353701717}}
        """
        let keyPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":5,"limit_reset":"daily","limit_remaining":5,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """

        let provider = OpenRouterQuotaProvider(
            keyLoader: { "k" },
            request: { req in
                await captured.record(req)
                if req.url?.path == "/api/v1/credits" {
                    return Data(creditsPayload.utf8)
                } else {
                    return Data(keyPayload.utf8)
                }
            }
        )

        let snap = try await provider.fetch(now: fixedNow)
        let requests = await captured.values
        #expect(requests.count == 2)
        #expect(requests[0].url?.absoluteString == "https://openrouter.ai/api/v1/credits")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(requests[1].url?.absoluteString == "https://openrouter.ai/api/v1/auth/key")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(snap.windows.count == 2)

        enum TestError: Error { case failed }
        let failingProvider = OpenRouterQuotaProvider(
            keyLoader: { throw TestError.failed },
            request: { _ in Data() }
        )

        do {
            _ = try await failingProvider.fetch(now: fixedNow)
            #expect(Bool(false), "Expected missingCredential error")
        } catch let QuotaError.missingCredential(msg) {
            #expect(!msg.isEmpty)
        } catch {
            #expect(Bool(false), "Expected missingCredential, got \(error)")
        }
    }

    // 14. OpenRouterKey.load(environment:)
    @Test("OpenRouterKey: load keychain priority, fallback to environment, or throws missingCredential")
    func openRouterKeyLoad() throws {
        let envVal = try OpenRouterKey.load(environment: ["OPENROUTER_API_KEY": "envk"], keychainReader: { nil })
        #expect(envVal == "envk")

        let kcVal = try OpenRouterKey.load(environment: ["OPENROUTER_API_KEY": "envk"], keychainReader: { "kc" })
        #expect(kcVal == "kc")

        do {
            _ = try OpenRouterKey.load(environment: [:], keychainReader: { nil })
            #expect(Bool(false), "Expected missingCredential error")
        } catch let QuotaError.missingCredential(msg) {
            #expect(msg == "set the OpenRouter key in settings")
        } catch {
            #expect(Bool(false), "Expected missingCredential, got \(error)")
        }
    }

    // 15. OpenRouterTopUp observing lifecycle
    @Test("OpenRouterTopUp: first observation records seen only, growth sets amount and at, equal or lower keeps amount and at")
    func openRouterTopUpObservingLifecycle() {
        let t0 = fixedNow
        let t1 = Date(timeIntervalSince1970: 1789303600)
        let t2 = Date(timeIntervalSince1970: 1789307200)

        // First observation (seenTotalCredits == 0): records seenTotalCredits, amount and at unchanged
        let initial = OpenRouterTopUp(seenTotalCredits: 0, amount: 0, at: nil)
        let afterFirst = initial.observing(totalCredits: 50, now: t0)
        #expect(afterFirst.seenTotalCredits == 50)
        #expect(afterFirst.amount == 0)
        #expect(afterFirst.at == nil)

        // First observation with pre-set amount (e.g. entered by hand)
        let manual = OpenRouterTopUp(seenTotalCredits: 0, amount: 15, at: t0)
        let afterManualFirst = manual.observing(totalCredits: 50, now: t1)
        #expect(afterManualFirst.seenTotalCredits == 50)
        #expect(afterManualFirst.amount == 15)
        #expect(afterManualFirst.at == t0)

        // Growth (totalCredits > seenTotalCredits): amount = totalCredits - seenTotalCredits, at = now
        let afterGrowth = afterFirst.observing(totalCredits: 74, now: t1)
        #expect(afterGrowth.seenTotalCredits == 74)
        #expect(afterGrowth.amount == 24)
        #expect(afterGrowth.at == t1)

        // Equal (totalCredits == seenTotalCredits): unchanged except seenTotalCredits = totalCredits
        let afterEqual = afterGrowth.observing(totalCredits: 74, now: t2)
        #expect(afterEqual.seenTotalCredits == 74)
        #expect(afterEqual.amount == 24)
        #expect(afterEqual.at == t1)

        // Lower (totalCredits < seenTotalCredits): amount and at kept, seen updated
        let afterLower = afterGrowth.observing(totalCredits: 70, now: t2)
        #expect(afterLower.seenTotalCredits == 70)
        #expect(afterLower.amount == 24)
        #expect(afterLower.at == t1)
    }

    // 16. OpenRouter parse with topUp
    @Test("OpenRouter: parse with topUp calculates usedPercent from amount and formats loaded date")
    func openRouterParseWithTopUp() throws {
        let creditsPayload = """
        {"data":{"total_credits":74,"total_usage":69.353701717}}
        """
        let keyPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":null,"limit_reset":"daily","limit_remaining":null,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """
        let topUp = OpenRouterTopUp(seenTotalCredits: 74, amount: 10, at: fixedNow)
        let snapshot = try OpenRouterQuotaParser.parse(
            creditsData: Data(creditsPayload.utf8),
            keyData: Data(keyPayload.utf8),
            now: fixedNow,
            topUp: topUp
        )

        let creditsWindow = try #require(snapshot.windows.first(where: { $0.label == "credits" }))
        #expect(abs(creditsWindow.usedPercent - 53.5) < 0.1)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.calendar = Calendar.current
        df.timeZone = TimeZone.current
        let expectedDate = df.string(from: fixedNow)
        let expectedPrefix = "$4.65 left of $10.00 loaded \(expectedDate)"
        let detail = try #require(snapshot.detail)
        #expect(detail.hasPrefix(expectedPrefix))
        #expect(detail == "$4.65 left of $10.00 loaded \(expectedDate), today $0.0000, week $0.0079, month $0.0583")
    }

    // 17. OpenRouter parse with amount and nil date omits loaded fragment
    @Test("OpenRouter: parse with amount and nil date omits loaded fragment")
    func openRouterParseNilDateOmitted() throws {
        let creditsPayload = """
        {"data":{"total_credits":74,"total_usage":69.353701717}}
        """
        let keyPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":null,"limit_reset":"daily","limit_remaining":null,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """
        let topUp = OpenRouterTopUp(seenTotalCredits: 74, amount: 10, at: nil)
        let snapshot = try OpenRouterQuotaParser.parse(
            creditsData: Data(creditsPayload.utf8),
            keyData: Data(keyPayload.utf8),
            now: fixedNow,
            topUp: topUp
        )

        let detail = try #require(snapshot.detail)
        #expect(!detail.contains("loaded"))
        #expect(detail == "$4.65 left of $10.00, today $0.0000, week $0.0079, month $0.0583")
    }

    // 18. OpenRouter parse remaining above amount clamps usedPercent to zero
    @Test("OpenRouter: parse with remaining above amount clamps usedPercent to zero")
    func openRouterParseRemainingAboveAmountClampsUsedPercentToZero() throws {
        let creditsPayload = """
        {"data":{"total_credits":74,"total_usage":60}}
        """
        let keyPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":null,"limit_reset":"daily","limit_remaining":null,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """
        let topUp = OpenRouterTopUp(seenTotalCredits: 74, amount: 10, at: nil)
        let snapshot = try OpenRouterQuotaParser.parse(
            creditsData: Data(creditsPayload.utf8),
            keyData: Data(keyPayload.utf8),
            now: fixedNow,
            topUp: topUp
        )

        let creditsWindow = try #require(snapshot.windows.first(where: { $0.label == "credits" }))
        #expect(creditsWindow.usedPercent == 0.0)
    }

    // 19. OpenRouterQuotaProvider top-up tracking and sink invocation
    @Test("OpenRouterQuotaProvider: top-up tracking invokes sink on growth and skips on identical ledger")
    func openRouterQuotaProviderTopUpTracking() async throws {
        let creditsPayload = """
        {"data":{"total_credits":74,"total_usage":69.353701717}}
        """
        let keyPayload = """
        {"data":{"label":"sk-or-v1-1f5...cac","limit":null,"limit_reset":"daily","limit_remaining":null,"usage":7.162991102,"usage_daily":0,"usage_weekly":0.007938767,"usage_monthly":0.05828838}}
        """

        final class TopUpBox: @unchecked Sendable {
            var current: OpenRouterTopUp
            var sinkCalls: [OpenRouterTopUp] = []
            init(current: OpenRouterTopUp) {
                self.current = current
            }
        }

        let box = TopUpBox(current: OpenRouterTopUp(seenTotalCredits: 50, amount: 0, at: nil))

        let provider = OpenRouterQuotaProvider(
            keyLoader: { "k" },
            request: { req in
                if req.url?.path == "/api/v1/credits" {
                    return Data(creditsPayload.utf8)
                } else {
                    return Data(keyPayload.utf8)
                }
            },
            topUpLoader: { box.current },
            topUpSink: { newLedger in
                box.sinkCalls.append(newLedger)
                box.current = newLedger
            }
        )

        // First fetch: total_credits is 74, previous seen was 50 -> sink receives amount 24, seen 74, at == fixedNow
        _ = try await provider.fetch(now: fixedNow)
        #expect(box.sinkCalls.count == 1)
        #expect(box.sinkCalls[0].seenTotalCredits == 74)
        #expect(box.sinkCalls[0].amount == 24)
        #expect(box.sinkCalls[0].at == fixedNow)

        // Second fetch: total_credits is still 74, seen is 74 -> ledger does not differ, sink not called
        _ = try await provider.fetch(now: fixedNow)
        #expect(box.sinkCalls.count == 1)
    }
}

private actor CapturedRequest {
    var value: URLRequest?
    func record(_ req: URLRequest) {
        value = req
    }
}

private actor CapturedRequests {
    var values: [URLRequest] = []
    func record(_ req: URLRequest) {
        values.append(req)
    }
}
