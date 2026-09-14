import Foundation
import Testing
import LLMOpsCore
@testable import LLMOps

@Suite("JudgeRunnerTests")
struct JudgeRunnerTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("judge-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStubScript(in dir: URL, name: String = "stub.sh", content: String) throws -> String {
        let scriptURL = dir.appendingPathComponent(name)
        try content.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL.path
    }

    private func makeDigest() -> AnalysisDigest {
        AnalysisDigest.build(sessions: [], profile: nil, periodDays: 7, now: Date(), calendar: .current)
    }

    // 1. Happy path: copies stdin to $PWD/stdin.txt and prints CLI json output
    @Test func happyPath() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = """
        #!/bin/sh
        cat > "$PWD/stdin.txt"
        printf '%s' '{"type":"result","result":"```json\\n{\\"verdict\\":\\"ok\\",\\"findings\\":[]}\\n```","total_cost_usd":0.0123}'
        """
        let scriptPath = try makeStubScript(in: tempDir, content: script)

        let runner = JudgeRunner(binaryPath: scriptPath, model: "test-model", workingDirectory: tempDir)
        let digest = makeDigest()
        let result = try await runner.run(digest: digest)

        #expect(result.report?.verdict == "ok")
        #expect(result.rawText.hasPrefix("```"))
        #expect(result.costUSD == 0.0123)
        #expect(result.model == "test-model")

        let stdinURL = tempDir.appendingPathComponent("stdin.txt")
        let stdinData = try Data(contentsOf: stdinURL)
        let stdinText = String(decoding: stdinData, as: UTF8.self)
        #expect(stdinText.contains("\"periodDays\":7"))
    }

    // 2. Arguments: all args joined by |
    @Test func argumentsPassedCorrectly() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = """
        #!/bin/sh
        IFS='|'
        # The system prompt contains double quotes; escape them so the stub emits valid JSON.
        ARGS=$(printf '%s' "$*" | sed 's/"/\\\\"/g')
        printf '{"result":"%s"}' "$ARGS"
        """
        let scriptPath = try makeStubScript(in: tempDir, content: script)

        let runner = JudgeRunner(binaryPath: scriptPath, model: "test-model", workingDirectory: tempDir)
        let digest = makeDigest()
        let result = try await runner.run(digest: digest)

        #expect(result.rawText.contains("-p|--output-format|json|--no-session-persistence|--tools||--model|test-model|--system-prompt|"))
    }

    // 3. Non zero exit: status != 0 throws nonZeroExit(status, stderr)
    @Test func nonZeroExit() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = """
        #!/bin/sh
        echo boom >&2
        exit 3
        """
        let scriptPath = try makeStubScript(in: tempDir, content: script)

        let runner = JudgeRunner(binaryPath: scriptPath, model: "test-model", workingDirectory: tempDir)
        let digest = makeDigest()

        do {
            _ = try await runner.run(digest: digest)
            Issue.record("Expected nonZeroExit error")
        } catch let JudgeRunnerError.nonZeroExit(status, stderr) {
            #expect(status == 3)
            #expect(stderr.contains("boom"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // 4. Timeout: returns under 3 seconds with .timeout error
    @Test func timeoutFires() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = """
        #!/bin/sh
        sleep 5
        """
        let scriptPath = try makeStubScript(in: tempDir, content: script)

        let runner = JudgeRunner(binaryPath: scriptPath, model: "test-model", workingDirectory: tempDir, timeout: 0.5)
        let digest = makeDigest()

        let start = ContinuousClock.now
        do {
            _ = try await runner.run(digest: digest)
            Issue.record("Expected timeout error")
        } catch let error as JudgeRunnerError {
            #expect(error == .timeout)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(3))
    }

    // 5. Missing binary throws .binaryMissing
    @Test func missingBinary() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nonExistent = tempDir.appendingPathComponent("non-existent-claude").path
        let runner = JudgeRunner(binaryPath: nonExistent, model: "test-model", workingDirectory: tempDir)
        let digest = makeDigest()

        do {
            _ = try await runner.run(digest: digest)
            Issue.record("Expected binaryMissing error")
        } catch let JudgeRunnerError.binaryMissing(path) {
            #expect(path == nonExistent)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // 6. Bad output throws .badOutput
    @Test func badOutput() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = """
        #!/bin/sh
        echo not-json
        """
        let scriptPath = try makeStubScript(in: tempDir, content: script)

        let runner = JudgeRunner(binaryPath: scriptPath, model: "test-model", workingDirectory: tempDir)
        let digest = makeDigest()

        do {
            _ = try await runner.run(digest: digest)
            Issue.record("Expected badOutput error")
        } catch let JudgeRunnerError.badOutput(stdout) {
            #expect(stdout.contains("not-json"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // 7. MainActor execution succeeds without deadlock
    @Test @MainActor func mainActorExecutionSucceeds() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let script = """
        #!/bin/sh
        cat > "$PWD/stdin.txt"
        printf '%s' '{"type":"result","result":"```json\\n{\\"verdict\\":\\"ok\\",\\"findings\\":[]}\\n```","total_cost_usd":0.0123}'
        """
        let scriptPath = try makeStubScript(in: tempDir, content: script)

        let runner = JudgeRunner(binaryPath: scriptPath, model: "test-model", workingDirectory: tempDir)
        let digest = makeDigest()
        let result = try await runner.run(digest: digest)

        #expect(result.report?.verdict == "ok")
        #expect(result.rawText.hasPrefix("```"))
        #expect(result.costUSD == 0.0123)
        #expect(result.model == "test-model")
    }
}
