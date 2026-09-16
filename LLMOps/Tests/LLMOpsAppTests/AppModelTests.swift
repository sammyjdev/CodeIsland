import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@Suite struct AppModelTests {
    @Test func routeCases() {
        #expect(Route.allCases.map(\.rawValue) == ["live", "history", "analytics", "analysis", "system", "quotas", "settings"])
    }

    @Test func analysisRoute() {
        #expect(Route.allCases.map(\.rawValue) == ["live", "history", "analytics", "analysis", "system", "quotas", "settings"])
    }

    @Test @MainActor func quotaProvidersList() {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        #expect(model.quotaProviders().map(\.id) == [.claude, .codex, .antigravity, .zai, .openrouter])
    }

    @Test @MainActor func initialDefaults() {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        #expect(model.profiles == ProfileDefaults.defaults())
        #expect(model.selectedProfile == nil)
        #expect(model.route == .live)
    }

    @Test @MainActor func saveProfilesAndFilterSessions() {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        let customProfiles = [
            Profile(id: "custom", name: "Custom", configDir: "~/.custom", pathPrefixes: ["~/custom"])
        ]
        model.saveProfiles(customProfiles)

        let secondStore = ProfileStore(userDefaults: userDefaults)
        #expect(secondStore.load() == customProfiles)
        #expect(model.profiles == customProfiles)

        #if DEBUG
        let s1 = Session(
            id: "s1",
            profile: "custom",
            filePath: "/dummy/s1.jsonl",
            startedAt: Date(),
            lastActivity: Date()
        )
        let s2 = Session(
            id: "s2",
            profile: "other",
            filePath: "/dummy/s2.jsonl",
            startedAt: Date(),
            lastActivity: Date()
        )
        model.setSessionsForTesting([s1, s2])

        #expect(model.visibleSessions == [s1, s2])

        model.selectedProfile = "custom"
        #expect(model.visibleSessions == [s1])

        model.selectedProfile = "other"
        #expect(model.visibleSessions == [s2])

        model.selectedProfile = nil
        #expect(model.visibleSessions == [s1, s2])
        #endif
    }

    @Test @MainActor func periodicRescanIdempotenceAndStop() {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        #expect(!model.isRescanning)

        model.startPeriodicRescan(every: 30)
        model.startPeriodicRescan(every: 30)
        #expect(model.isRescanning)

        model.stopPeriodicRescan()
        #expect(!model.isRescanning)
    }

    @Test @MainActor func rescanInFlightIsNoOp() async throws {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
            func increment() {
                lock.lock()
                defer { lock.unlock() }
                count += 1
            }
            var value: Int {
                lock.lock()
                defer { lock.unlock() }
                return count
            }
        }

        let counter = Counter()
        let s1 = Session(
            id: "s1",
            profile: "pessoal",
            filePath: "/dummy/s1.jsonl",
            startedAt: Date(),
            lastActivity: Date()
        )

        let model = AppModel(userDefaults: userDefaults, scanner: { _, _ in
            counter.increment()
            Thread.sleep(forTimeInterval: 0.2)
            return [s1]
        })

        #expect(model.isScanning == false)
        model.rescan()
        #expect(model.isScanning == true)

        model.rescan()
        #expect(model.isScanning == true)

        for _ in 0..<50 {
            if !model.isScanning { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(model.isScanning == false)
        #expect(counter.value == 1)
        #expect(model.sessions == [s1])
    }

    // 9. With two sessions in different profiles injected via setSessionsForTesting, selectedProfile set to one of them, profileSessions returns only that profile's session.
    @Test @MainActor func profileSessionsFiltersOnlyByProfile() {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        #if DEBUG
        let s1 = Session(
            id: "s1",
            profile: "p1",
            filePath: "/dummy/s1.jsonl",
            startedAt: Date(),
            lastActivity: Date()
        )
        let s2 = Session(
            id: "s2",
            profile: "p2",
            filePath: "/dummy/s2.jsonl",
            startedAt: Date(),
            lastActivity: Date()
        )
        model.setSessionsForTesting([s1, s2])

        model.selectedProfile = "p1"
        #expect(model.profileSessions == [s1])
        #endif
    }

    // 10. With filter.project set, visibleSessions returns only the matching session while profileSessions still returns both.
    @Test @MainActor func visibleSessionsAppliesFilterOverProfileSessions() {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        #if DEBUG
        let s1 = Session(
            id: "s1",
            profile: "p1",
            filePath: "/dummy/s1.jsonl",
            project: "alpha",
            startedAt: Date(),
            lastActivity: Date()
        )
        let s2 = Session(
            id: "s2",
            profile: "p1",
            filePath: "/dummy/s2.jsonl",
            project: "beta",
            startedAt: Date(),
            lastActivity: Date()
        )
        model.setSessionsForTesting([s1, s2])

        model.filter.project = "alpha"
        #expect(model.visibleSessions == [s1])
        #expect(model.profileSessions == [s1, s2])
        #endif
    }

    // Required N1: presentRequestActivatesOnlyOnFront
    @Test @MainActor func presentRequestActivatesOnlyOnFront() throws {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let model = AppModel(userDefaults: userDefaults)
        defer { model.stopPeriodicRescan() }
        var count = 0
        model.activator = { count += 1 }

        model.settings.requestPresentation = .front
        model.presentRequest()
        #expect(count == 1)

        model.settings.requestPresentation = .notch
        model.presentRequest()
        #expect(count == 1)

        model.settings.requestPresentation = .none
        model.presentRequest()
        #expect(count == 1)
    }

    @Test @MainActor func widgetSnapshotWrittenOnExplicitCall() throws {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WidgetSnapshotStore(directory: tempDir)
        let model = AppModel(userDefaults: userDefaults, widgetStore: store)
        defer { model.stopPeriodicRescan() }

        let now = Date()
        var usage = ClaudeUsageTotals()
        usage.inputTokens = 50
        usage.outputTokens = 20
        let turn = Turn(id: "t1", startedAt: now, model: "claude-sonnet-5", usage: usage)
        let session = Session(
            id: "s1",
            profile: "p1",
            filePath: "/tmp/s1.jsonl",
            startedAt: now,
            lastActivity: now,
            turns: [turn],
            usage: usage
        )
        model.setSessionsForTesting([session])

        model.writeWidgetSnapshot(now: now)

        let readSnapshot = store.read()
        #expect(readSnapshot != nil)
        #expect(readSnapshot?.today.sessions == 1)
        if let writtenAt = readSnapshot?.writtenAt {
            #expect(abs(writtenAt.timeIntervalSince(now)) < 1.0)
        }
    }

    @Test @MainActor func recordSystemSampleWritesSnapshot() throws {
        let suite = "AppModelTests-" + UUID().uuidString
        guard let userDefaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create UserDefaults suite")
            return
        }
        defer { userDefaults.removePersistentDomain(forName: suite) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = WidgetSnapshotStore(directory: tempDir)
        let model = AppModel(userDefaults: userDefaults, widgetStore: store)
        defer { model.stopPeriodicRescan() }

        let sample = SystemSample(
            at: Date(),
            cpuPercent: 77.5,
            memory: MemorySample(total: 1000, used: 500, wired: 100, compressed: 100, free: 500),
            topByCPU: [],
            topByMemory: [],
            battery: nil
        )

        let t0 = Date()
        model.recordSystemSample(sample, now: t0)

        let readSnapshot = store.read()
        #expect(readSnapshot != nil)
        #expect(readSnapshot?.system.cpuPercent == 77.5)

        // Throttled: a second sample within 30 s does not rewrite; after 30 s it does.
        let later = SystemSample(
            at: Date(),
            cpuPercent: 12.0,
            memory: sample.memory,
            topByCPU: [],
            topByMemory: [],
            battery: nil
        )
        model.recordSystemSample(later, now: t0.addingTimeInterval(5))
        #expect(store.read()?.system.cpuPercent == 77.5)
        model.recordSystemSample(later, now: t0.addingTimeInterval(31))
        #expect(store.read()?.system.cpuPercent == 12.0)
    }
}
