import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@Suite("AnalysisStateTests")
struct AnalysisStateTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-state-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixtureSessions() -> [Session] {
        let s1 = Session(
            id: "s1",
            profile: "test",
            filePath: "/dummy/s1.jsonl",
            startedAt: Date(),
            lastActivity: Date()
        )
        let s2 = Session(
            id: "s2",
            profile: "test",
            filePath: "/dummy/s2.jsonl",
            startedAt: Date(),
            lastActivity: Date()
        )
        return [s1, s2]
    }

    // 1. run with a judge returning JudgeRunResult over two fixture sessions sets
    // latest?.report?.verdict == "fine", latest?.sessionCount == 2, latest?.model == "m",
    // latest?.costUSD == 0.01, error == nil, isRunning == false, and store.loadLatest() == latest.
    @Test @MainActor func runSuccessSetsLatestAndSaves() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AnalysisStore(directory: tempDir)
        let state = AnalysisState()
        let sessions = makeFixtureSessions()

        let expectedReport = JudgeReport(verdict: "fine", findings: [])
        let judgeResult = JudgeRunResult(
            report: expectedReport,
            rawText: "{}",
            costUSD: 0.01,
            model: "m"
        )

        await state.run(
            sessions: sessions,
            profile: "test",
            periodDays: 7,
            model: "m",
            store: store,
            judge: { _ in judgeResult }
        )

        #expect(state.latest?.report?.verdict == "fine")
        #expect(state.latest?.sessionCount == 2)
        #expect(state.latest?.model == "m")
        #expect(state.latest?.costUSD == 0.01)
        #expect(state.error == nil)
        #expect(state.isRunning == false)
        #expect(store.loadLatest() == state.latest)
    }

    // 2. The judge closure receives a digest with sessionCount == 2 and periodDays == 7 (capture it).
    @Test @MainActor func judgeClosureReceivesDigest() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AnalysisStore(directory: tempDir)
        let state = AnalysisState()
        let sessions = makeFixtureSessions()

        final class Captured: @unchecked Sendable {
            var digest: AnalysisDigest?
        }
        let captured = Captured()

        await state.run(
            sessions: sessions,
            profile: "test",
            periodDays: 7,
            model: "m",
            store: store,
            judge: { digest in
                captured.digest = digest
                return JudgeRunResult(report: nil, rawText: "{}", costUSD: nil, model: "m")
            }
        )

        #expect(captured.digest?.sessionCount == 2)
        #expect(captured.digest?.periodDays == 7)
    }

    // 3. run with a judge throwing JudgeRunnerError.timeout after a previous successful run:
    // error == "judge timed out after 120s", latest unchanged, isRunning == false.
    @Test @MainActor func runErrorPreservesLatestAndSetsError() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AnalysisStore(directory: tempDir)
        let state = AnalysisState()
        let sessions = makeFixtureSessions()

        let initialResult = JudgeRunResult(
            report: JudgeReport(verdict: "ok", findings: []),
            rawText: "{}",
            costUSD: 0.02,
            model: "initial"
        )

        await state.run(
            sessions: sessions,
            profile: "test",
            periodDays: 7,
            model: "initial",
            store: store,
            judge: { _ in initialResult }
        )

        let initialLatest = state.latest
        #expect(initialLatest != nil)

        await state.run(
            sessions: sessions,
            profile: "test",
            periodDays: 7,
            model: "m",
            store: store,
            judge: { _ in throw JudgeRunnerError.timeout }
        )

        #expect(state.error == "judge timed out after 120s")
        #expect(state.latest == initialLatest)
        #expect(state.isRunning == false)
    }

    // 4. message(for:binaryPath:) for .binaryMissing("/x/claude") contains /x/claude and settings;
    // for .nonZeroExit(3, "boom") contains 3 and boom.
    @Test @MainActor func errorMessageMapping() {
        let msgMissing = AnalysisState.message(for: JudgeRunnerError.binaryMissing("/x/claude"), binaryPath: "/x/claude")
        #expect(msgMissing.contains("/x/claude"))
        #expect(msgMissing.contains("settings"))

        let msgExit = AnalysisState.message(for: JudgeRunnerError.nonZeroExit(3, "boom"), binaryPath: "claude")
        #expect(msgExit.contains("3"))
        #expect(msgExit.contains("boom"))

        let msgTimeout = AnalysisState.message(for: JudgeRunnerError.timeout, binaryPath: "claude")
        #expect(msgTimeout == "judge timed out after 120s")

        let msgBadOutput = AnalysisState.message(for: JudgeRunnerError.badOutput("invalid json"), binaryPath: "claude")
        #expect(msgBadOutput == "judge returned unexpected output: invalid json")
    }

    // 5. load(store:) on an empty temp directory leaves latest nil; after store.save(run) it loads that run.
    @Test @MainActor func loadFromStore() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AnalysisStore(directory: tempDir)
        let state = AnalysisState()

        state.load(store: store)
        #expect(state.latest == nil)

        let date = Date(timeIntervalSince1970: 1773700000)
        let run = AnalysisRun(
            generatedAt: date,
            profile: "test",
            periodDays: 7,
            sessionCount: 3,
            model: "claude",
            costUSD: 0.05,
            report: nil,
            rawText: "raw"
        )
        try store.save(run)

        state.load(store: store)
        #expect(state.latest == run)
    }
}
