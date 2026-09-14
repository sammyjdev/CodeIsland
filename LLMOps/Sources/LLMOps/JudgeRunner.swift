import Foundation
import LLMOpsCore

public struct JudgeRunResult: Equatable {
    public let report: JudgeReport?
    public let rawText: String
    public let costUSD: Double?
    public let model: String

    public init(report: JudgeReport?, rawText: String, costUSD: Double?, model: String) {
        self.report = report
        self.rawText = rawText
        self.costUSD = costUSD
        self.model = model
    }
}

public enum JudgeRunnerError: Error, Equatable {
    case binaryMissing(String)
    case nonZeroExit(Int32, String)
    case timeout
    case badOutput(String)
}

public struct JudgeRunner {
    public var binaryPath: String
    public var model: String
    public var workingDirectory: URL
    public var timeout: TimeInterval = 120

    public init(binaryPath: String, model: String, workingDirectory: URL, timeout: TimeInterval = 120) {
        self.binaryPath = binaryPath
        self.model = model
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    public func run(digest: AnalysisDigest) async throws -> JudgeRunResult {
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            throw JudgeRunnerError.binaryMissing(binaryPath)
        }

        let inputData = try digest.encoded()
        let binaryPath = self.binaryPath
        let model = self.model
        let workingDirectory = self.workingDirectory
        let timeout = self.timeout

        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binaryPath)
            process.currentDirectoryURL = workingDirectory
            process.arguments = [
                "-p",
                "--output-format", "json",
                "--no-session-persistence",
                "--tools", "",
                "--model", model,
                "--system-prompt", JudgePrompt.system
            ]

            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "CLAUDECODE")
            process.environment = env

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            signal(SIGPIPE, SIG_IGN)

            let stdoutHandle = stdoutPipe.fileHandleForReading
            let stderrHandle = stderrPipe.fileHandleForReading

            let stdoutTask = Task.detached {
                stdoutHandle.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderrHandle.readDataToEndOfFile()
            }

            try process.run()

            let stdinHandle = stdinPipe.fileHandleForWriting
            Task.detached {
                _ = try? stdinHandle.write(contentsOf: inputData)
                _ = try? stdinHandle.close()
            }

            let timeoutState = TimeoutState()
            let timeoutTask = Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled {
                    timeoutState.markTimedOut()
                    if process.isRunning {
                        process.terminate()
                    }
                }
            }

            process.waitUntilExit()
            timeoutTask.cancel()

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value

            if timeoutState.isTimedOut {
                throw JudgeRunnerError.timeout
            }

            if process.terminationStatus != 0 {
                let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
                let prefixStderr = String(stderrString.prefix(2000))
                throw JudgeRunnerError.nonZeroExit(process.terminationStatus, prefixStderr)
            }

            let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
            let prefixStdout = String(stdoutString.prefix(500))

            guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any],
                  let result = json["result"] as? String else {
                throw JudgeRunnerError.badOutput(prefixStdout)
            }

            let costUSD = (json["total_cost_usd"] as? NSNumber)?.doubleValue
            let report = JudgeReportParser.parse(result)

            return JudgeRunResult(
                report: report,
                rawText: result,
                costUSD: costUSD,
                model: model
            )
        }.value
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isTimedOut = false

    var isTimedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isTimedOut
    }

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        _isTimedOut = true
    }
}
