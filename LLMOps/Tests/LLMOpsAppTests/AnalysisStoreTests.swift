import Foundation
import Testing
import LLMOpsCore
@testable import LLMOps

@Suite("AnalysisStoreTests")
struct AnalysisStoreTests {
    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // 8. save then loadLatest round trips an AnalysisRun with a report
    @Test func saveAndLoadRoundTrip() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AnalysisStore(directory: tempDir)
        let finding = JudgeFinding(severity: "high", title: "Cache issue", evidence: "0% read", suggestion: "Enable cache")
        let report = JudgeReport(verdict: "Needs improvement", findings: [finding])
        let date = Date(timeIntervalSince1970: 1773700000)

        let run = AnalysisRun(
            generatedAt: date,
            profile: "test-profile",
            periodDays: 7,
            sessionCount: 15,
            model: "claude-3-7-sonnet",
            costUSD: 1.25,
            report: report,
            rawText: "sample raw text"
        )

        try store.save(run)
        let loaded = store.loadLatest()
        #expect(loaded == run)
    }

    // 9. Two saves one hour apart: loadLatest returns newer regardless of save order
    @Test func loadLatestReturnsNewer() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AnalysisStore(directory: tempDir)
        let date1 = Date(timeIntervalSince1970: 1773700000)
        let date2 = Date(timeIntervalSince1970: 1773703600) // 1 hour later

        let older = AnalysisRun(
            generatedAt: date1,
            profile: "test",
            periodDays: 7,
            sessionCount: 5,
            model: "sonnet",
            costUSD: 0.5,
            report: nil,
            rawText: "older"
        )

        let newer = AnalysisRun(
            generatedAt: date2,
            profile: "test",
            periodDays: 7,
            sessionCount: 10,
            model: "sonnet",
            costUSD: 1.0,
            report: nil,
            rawText: "newer"
        )

        // Save newer first, then older
        try store.save(newer)
        try store.save(older)

        #expect(store.loadLatest() == newer)
    }

    // 10. Missing directory returns nil; garbage file is skipped
    @Test func missingDirectoryAndGarbageFileHandled() throws {
        let missingDir = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        let missingStore = AnalysisStore(directory: missingDir)
        #expect(missingStore.loadLatest() == nil)

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = AnalysisStore(directory: tempDir)
        let garbageURL = tempDir.appendingPathComponent("corrupted.json")
        try "this is not valid json".write(to: garbageURL, atomically: true, encoding: .utf8)
        #expect(store.loadLatest() == nil)

        let validRun = AnalysisRun(
            generatedAt: Date(timeIntervalSince1970: 1773700000),
            profile: nil,
            periodDays: 14,
            sessionCount: 3,
            model: "haiku",
            costUSD: 0.05,
            report: nil,
            rawText: "valid"
        )
        try store.save(validRun)
        #expect(store.loadLatest() == validRun)
    }
}
