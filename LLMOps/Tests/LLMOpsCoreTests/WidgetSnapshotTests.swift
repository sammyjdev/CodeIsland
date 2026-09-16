import Foundation
import Testing
@testable import LLMOpsCore

@Suite("WidgetSnapshotTests")
struct WidgetSnapshotTests {
    @Test("defaultDirectory returns expected container path for given home")
    func defaultDirectoryPath() {
        let home = URL(fileURLWithPath: "/Users/x")
        let dir = WidgetSnapshotStore.defaultDirectory(home: home)
        #expect(dir.path == "/Users/x/Library/Containers/dev.samdev.llmops.widgets/Data/Library/Application Support")
    }

    @Test("write then read in fresh temp directory round-trips snapshot")
    func writeThenReadRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WidgetSnapshotStore(directory: tempDir)

        let writtenAt = Date(timeIntervalSince1970: 1789300000)
        let resetsAt = Date(timeIntervalSince1970: 1789310000)

        let quotas = [
            WidgetQuota(provider: .claude, label: "5h", usedPercent: 42.5, resetsAt: nil),
            WidgetQuota(provider: .codex, label: "primary", usedPercent: 88.0, resetsAt: resetsAt)
        ]
        let today = TodaySummary(sessions: 12, tokens: 45000, costUSD: 1.35)
        let system = SystemSummary(cpuPercent: 18.2, memoryUsedPercent: 62.4, batteryPercent: nil)

        let snapshot = WidgetSnapshot(writtenAt: writtenAt, quotas: quotas, today: today, system: system)

        try store.write(snapshot)
        let loaded = store.read()

        #expect(loaded == snapshot)
    }

    @Test("read on missing or garbage file returns nil")
    func readMissingOrGarbageFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WidgetSnapshotStore(directory: tempDir)
        #expect(store.read() == nil)

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let garbage = Data("{\"garbage\":1}".utf8)
        try garbage.write(to: store.fileURL)

        #expect(store.read() == nil)
    }

    @Test("write creates directory when missing and produces valid JSON with expected keys")
    func writeCreatesDirectoryAndValidJSON() throws {
        let baseTempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: baseTempDir) }
        let nestedDir = baseTempDir.appendingPathComponent("nested/path/to/store")

        let store = WidgetSnapshotStore(directory: nestedDir)

        let snapshot = WidgetSnapshot(
            writtenAt: Date(timeIntervalSince1970: 1789300000),
            quotas: [],
            today: TodaySummary(sessions: 0, tokens: 0, costUSD: 0.0),
            system: SystemSummary(cpuPercent: 0.0, memoryUsedPercent: 0.0, batteryPercent: 100.0)
        )

        try store.write(snapshot)

        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        let data = try Data(contentsOf: store.fileURL)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = jsonObject.map { Set($0.keys) }

        #expect(keys == Set(["writtenAt", "quotas", "today", "system"]))
    }
}
