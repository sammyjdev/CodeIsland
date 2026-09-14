import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@Suite struct AppModelTests {
    @Test func routeCases() {
        #expect(Route.allCases.map(\.rawValue) == ["live", "history", "analytics", "settings"])
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
}
