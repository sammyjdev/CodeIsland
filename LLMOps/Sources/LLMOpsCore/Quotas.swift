import Foundation

public enum QuotaProviderID: String, CaseIterable, Sendable, Codable {
    case claude, codex, antigravity, zai
    public var displayName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .antigravity: return "antigravity"
        case .zai: return "z.ai"
        }
    }
}

public struct QuotaWindow: Equatable, Sendable, Codable {
    public let label: String          // "5h", "7d", or a model label for antigravity
    public let usedPercent: Double    // 0...100
    public let resetsAt: Date?
    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct QuotaSnapshot: Equatable, Sendable {
    public let provider: QuotaProviderID
    public let windows: [QuotaWindow]
    public let fetchedAt: Date
    public let detail: String?        // plan / account line, e.g. "plan plus", "level pro", an email
    public var worstUsedPercent: Double? { windows.map(\.usedPercent).max() }
    public init(provider: QuotaProviderID, windows: [QuotaWindow], fetchedAt: Date, detail: String?) {
        self.provider = provider
        self.windows = windows
        self.fetchedAt = fetchedAt
        self.detail = detail
    }
}

public enum QuotaError: Error, Equatable {
    case missingCredential(String)
    case network(String)
    case badPayload(String)
    case notFound(String)
    case subprocess(String)
}

public protocol QuotaProvider: Sendable {
    var id: QuotaProviderID { get }
    func fetch(now: Date) async throws -> QuotaSnapshot
}

private func parseISO8601Date(_ str: String) -> Date? {
    let formatterWithFraction = ISO8601DateFormatter()
    formatterWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatterWithFraction.date(from: str) {
        return date
    }
    let formatterPlain = ISO8601DateFormatter()
    formatterPlain.formatOptions = [.withInternetDateTime]
    return formatterPlain.date(from: str)
}

public enum ClaudeQuotaParser {
    public static func parse(_ data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.badPayload("invalid json")
        }

        var windows: [QuotaWindow] = []

        if let fiveHour = json["five_hour"] as? [String: Any] {
            let util = (fiveHour["utilization"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsStr = fiveHour["resets_at"] as? String
            let resetsAt = resetsStr.flatMap(parseISO8601Date)
            windows.append(QuotaWindow(label: "5h", usedPercent: util, resetsAt: resetsAt))
        }

        if let sevenDay = json["seven_day"] as? [String: Any] {
            let util = (sevenDay["utilization"] as? NSNumber)?.doubleValue ?? 0.0
            let resetsStr = sevenDay["resets_at"] as? String
            let resetsAt = resetsStr.flatMap(parseISO8601Date)
            windows.append(QuotaWindow(label: "7d", usedPercent: util, resetsAt: resetsAt))
        }

        guard !windows.isEmpty else {
            throw QuotaError.badPayload("both five_hour and seven_day missing")
        }

        return QuotaSnapshot(provider: .claude, windows: windows, fetchedAt: now, detail: nil)
    }
}

public enum CodexQuotaParser {
    private static func findRateLimits(in obj: Any) -> [String: Any]? {
        if let dict = obj as? [String: Any] {
            if let rl = dict["rate_limits"] as? [String: Any] {
                return rl
            }
            for (_, val) in dict {
                if let found = findRateLimits(in: val) {
                    return found
                }
            }
        } else if let arr = obj as? [Any] {
            for val in arr {
                if let found = findRateLimits(in: val) {
                    return found
                }
            }
        }
        return nil
    }

    private static func formatWindowLabel(minutes: Int) -> String {
        if minutes == 300 { return "5h" }
        if minutes == 10080 { return "7d" }
        return "\(minutes)m"
    }

    public static func parse(fileContents: String, now: Date) -> QuotaSnapshot? {
        let lines = fileContents.components(separatedBy: .newlines)
        for line in lines.reversed() {
            guard line.contains("rate_limits"),
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data),
                  let rateLimits = findRateLimits(in: json),
                  let primary = rateLimits["primary"] as? [String: Any] else {
                continue
            }

            var windows: [QuotaWindow] = []

            let primaryUsed = (primary["used_percent"] as? NSNumber)?.doubleValue ?? 0.0
            let primaryMins = (primary["window_minutes"] as? NSNumber)?.intValue ?? 0
            let primaryResets = (primary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(QuotaWindow(label: formatWindowLabel(minutes: primaryMins), usedPercent: primaryUsed, resetsAt: primaryResets))

            if let secondary = rateLimits["secondary"] as? [String: Any] {
                let secUsed = (secondary["used_percent"] as? NSNumber)?.doubleValue ?? 0.0
                let secMins = (secondary["window_minutes"] as? NSNumber)?.intValue ?? 0
                let secResets = (secondary["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(QuotaWindow(label: formatWindowLabel(minutes: secMins), usedPercent: secUsed, resetsAt: secResets))
            }

            let detail: String?
            if let planType = rateLimits["plan_type"] as? String, !planType.isEmpty {
                detail = "plan \(planType)"
            } else {
                detail = nil
            }

            return QuotaSnapshot(provider: .codex, windows: windows, fetchedAt: now, detail: detail)
        }
        return nil
    }

    public static func latest(in directory: URL, limit: Int, now: Date) throws -> QuotaSnapshot {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw QuotaError.notFound("no rollout with rate limits")
        }

        var candidateFiles: [(url: URL, date: Date)] = []
        for case let fileURL as URL in enumerator {
            let lastComponent = fileURL.lastPathComponent
            guard lastComponent.hasPrefix("rollout-") && fileURL.pathExtension == "jsonl" else {
                continue
            }
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let modDate = values?.contentModificationDate ?? Date.distantPast
            candidateFiles.append((fileURL, modDate))
        }

        candidateFiles.sort { $0.date > $1.date }

        for file in candidateFiles.prefix(limit) {
            guard let content = try? String(contentsOf: file.url, encoding: .utf8) else {
                continue
            }
            if let snapshot = parse(fileContents: content, now: now) {
                return snapshot
            }
        }

        throw QuotaError.notFound("no rollout with rate limits")
    }
}

public enum AntigravityQuotaParser {
    public static func parse(_ data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.badPayload("invalid json")
        }

        guard let models = json["models"] as? [[String: Any]], !models.isEmpty else {
            throw QuotaError.badPayload("models array missing or empty")
        }

        var windows: [QuotaWindow] = []
        for model in models {
            let isAutocomplete = model["isAutocompleteOnly"] as? Bool ?? false
            guard !isAutocomplete else { continue }

            let label = model["label"] as? String ?? ""
            guard label.hasPrefix("Gemini 3") || label.hasPrefix("Claude") else { continue }

            let rem = (model["remainingPercentage"] as? NSNumber)?.doubleValue ?? 0.0
            let usedPercent = (((1.0 - rem) * 100.0) * 10.0).rounded() / 10.0

            let resetStr = model["resetTime"] as? String
            let resetsAt = resetStr.flatMap(parseISO8601Date)

            windows.append(QuotaWindow(label: label, usedPercent: usedPercent, resetsAt: resetsAt))
        }

        let detail = json["email"] as? String
        return QuotaSnapshot(provider: .antigravity, windows: windows, fetchedAt: now, detail: detail)
    }
}

public enum ZaiQuotaParser {
    public static func parse(_ data: Data, now: Date) throws -> QuotaSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any],
              let limits = dataObj["limits"] as? [[String: Any]] else {
            throw QuotaError.badPayload("invalid json payload")
        }

        var window5h: QuotaWindow?
        var window7d: QuotaWindow?

        for limit in limits {
            guard (limit["type"] as? String) == "TOKENS_LIMIT" else { continue }
            let unit = (limit["unit"] as? NSNumber)?.intValue
            let percentage = (limit["percentage"] as? NSNumber)?.doubleValue ?? 0.0
            let nextResetTime = (limit["nextResetTime"] as? NSNumber)?.doubleValue
            let resetsAt = nextResetTime.map { Date(timeIntervalSince1970: $0 / 1000.0) }

            if unit == 3 {
                window5h = QuotaWindow(label: "5h", usedPercent: percentage, resetsAt: resetsAt)
            } else if unit == 6 {
                window7d = QuotaWindow(label: "7d", usedPercent: percentage, resetsAt: resetsAt)
            }
        }

        var windows: [QuotaWindow] = []
        if let w5 = window5h { windows.append(w5) }
        if let w7 = window7d { windows.append(w7) }

        guard !windows.isEmpty else {
            throw QuotaError.badPayload("no valid token limits found")
        }

        let detail: String?
        if let level = dataObj["level"] as? String, !level.isEmpty {
            detail = "level \(level)"
        } else {
            detail = nil
        }

        return QuotaSnapshot(provider: .zai, windows: windows, fetchedAt: now, detail: detail)
    }
}

public enum KeychainToken {
    @Sendable
    public static func claudeCode() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw QuotaError.missingCredential("failed to run security: \(error.localizedDescription)")
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw QuotaError.missingCredential("security command exited with status \(process.terminationStatus)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            throw QuotaError.missingCredential("no access token in Claude Code-credentials")
        }

        return token
    }
}

public struct ClaudeQuotaProvider: QuotaProvider {
    public let id: QuotaProviderID = .claude
    public var tokenLoader: @Sendable () throws -> String
    public var request: @Sendable (URLRequest) async throws -> Data

    public init(
        tokenLoader: @escaping @Sendable () throws -> String = { try KeychainToken.claudeCode() },
        request: @escaping @Sendable (URLRequest) async throws -> Data = ClaudeQuotaProvider.defaultRequest
    ) {
        self.tokenLoader = tokenLoader
        self.request = request
    }

    public static let defaultRequest: @Sendable (URLRequest) async throws -> Data = { req in
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw QuotaError.network("HTTP \(http.statusCode)")
        }
        return data
    }

    public func fetch(now: Date) async throws -> QuotaSnapshot {
        let token: String
        do {
            token = try tokenLoader()
        } catch let err as QuotaError {
            throw err
        } catch {
            throw QuotaError.missingCredential(error.localizedDescription)
        }

        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw QuotaError.network("invalid url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 15

        let data: Data
        do {
            data = try await request(req)
        } catch let err as QuotaError {
            throw err
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }

        return try ClaudeQuotaParser.parse(data, now: now)
    }
}

public struct CodexQuotaProvider: QuotaProvider {
    public let id: QuotaProviderID = .codex
    public var sessionsDirectory: URL
    public var fileLimit: Int

    public init(
        sessionsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"),
        fileLimit: Int = 30
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.fileLimit = fileLimit
    }

    public func fetch(now: Date) async throws -> QuotaSnapshot {
        try CodexQuotaParser.latest(in: sessionsDirectory, limit: fileLimit, now: now)
    }
}

public struct AntigravityQuotaProvider: QuotaProvider {
    public let id: QuotaProviderID = .antigravity
    public var executablePath: String
    public var runner: @Sendable (String) async throws -> Data

    public init(
        executablePath: String,
        runner: @escaping @Sendable (String) async throws -> Data = AntigravityQuotaProvider.defaultRunner
    ) {
        self.executablePath = executablePath
        self.runner = runner
    }

    public static let defaultRunner: @Sendable (String) async throws -> Data = { executablePath in
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw QuotaError.subprocess("not found at \(executablePath)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executablePath)
                    process.arguments = ["quota", "--json"]

                    var env = ProcessInfo.processInfo.environment
                    let dir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
                    let currentPath = env["PATH"] ?? ""
                    env["PATH"] = "\(dir):\(currentPath)"
                    process.environment = env

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    let stdoutHandle = stdoutPipe.fileHandleForReading
                    let stderrHandle = stderrPipe.fileHandleForReading

                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
                    timer.schedule(deadline: .now() + 30.0)
                    var timedOut = false
                    timer.setEventHandler {
                        timedOut = true
                        if process.isRunning {
                            process.terminate()
                        }
                    }
                    timer.resume()

                    try process.run()

                    let stdoutData = stdoutHandle.readDataToEndOfFile()
                    let stderrData = stderrHandle.readDataToEndOfFile()

                    process.waitUntilExit()
                    timer.cancel()

                    if timedOut {
                        continuation.resume(throwing: QuotaError.subprocess("timed out after 30s"))
                        return
                    }

                    if process.terminationStatus != 0 {
                        let errStr = String(data: stderrData, encoding: .utf8) ?? ""
                        let prefixErr = String(errStr.prefix(300))
                        continuation.resume(throwing: QuotaError.subprocess(prefixErr))
                        return
                    }

                    continuation.resume(returning: stdoutData)
                } catch let error as QuotaError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: QuotaError.subprocess(error.localizedDescription))
                }
            }
        }
    }

    public func fetch(now: Date) async throws -> QuotaSnapshot {
        let data: Data
        do {
            data = try await runner(executablePath)
        } catch let err as QuotaError {
            throw err
        } catch {
            throw QuotaError.subprocess(error.localizedDescription)
        }
        return try AntigravityQuotaParser.parse(data, now: now)
    }
}

public enum ZaiKey {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json").path
    }

    @Sendable
    public static func fromOpencodeAuth(path: String = defaultPath) throws -> String {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path) else {
            throw QuotaError.missingCredential("auth file missing at \(path)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let zai = json["zai-coding-plan"] as? [String: Any],
              let key = zai["key"] as? String,
              !key.isEmpty else {
            throw QuotaError.missingCredential("zai-coding-plan.key missing in \(path)")
        }

        return key
    }
}

public struct ZaiQuotaProvider: QuotaProvider {
    public let id: QuotaProviderID = .zai
    public var keyLoader: @Sendable () throws -> String
    public var request: @Sendable (URLRequest) async throws -> Data

    public init(
        keyLoader: @escaping @Sendable () throws -> String = { try ZaiKey.fromOpencodeAuth() },
        request: @escaping @Sendable (URLRequest) async throws -> Data = ZaiQuotaProvider.defaultRequest
    ) {
        self.keyLoader = keyLoader
        self.request = request
    }

    public static let defaultRequest: @Sendable (URLRequest) async throws -> Data = { req in
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QuotaError.network("invalid response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw QuotaError.network("HTTP \(http.statusCode)")
        }
        return data
    }

    public func fetch(now: Date) async throws -> QuotaSnapshot {
        let key: String
        do {
            key = try keyLoader()
        } catch let err as QuotaError {
            throw err
        } catch {
            throw QuotaError.missingCredential(error.localizedDescription)
        }

        guard let url = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit") else {
            throw QuotaError.network("invalid url")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15

        let data: Data
        do {
            data = try await request(req)
        } catch let err as QuotaError {
            throw err
        } catch {
            throw QuotaError.network(error.localizedDescription)
        }

        return try ZaiQuotaParser.parse(data, now: now)
    }
}
