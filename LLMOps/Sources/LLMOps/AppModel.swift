import Foundation
import Observation
import CodeIslandCore
import LLMOpsCore

enum Route: String, CaseIterable, Identifiable {
    case live
    case history
    case analytics
    case settings

    var id: String { rawValue }
}

@MainActor @Observable
final class AppModel {
    let profileStore: ProfileStore
    private(set) var profiles: [Profile]
    var selectedProfile: String?
    var route: Route = .live
    let live: LiveStore
    private(set) var sessions: [Session] = []
    private(set) var lastScanAt: Date?
    private var scanCache = TranscriptScanner.ScanCache()

    private var periodicTimer: Timer?
    private var currentScanTask: Task<Void, Never>?

    var isRescanning: Bool {
        periodicTimer != nil
    }

    init(userDefaults: UserDefaults = .standard) {
        let store = ProfileStore(userDefaults: userDefaults)
        let loaded = store.load()
        self.profileStore = store
        self.profiles = loaded
        self.live = LiveStore(profiles: loaded)
    }

    // No deinit: AppModel lives for the whole app lifetime, and a nonisolated
    // deinit cannot touch main-actor state under strict concurrency anyway.
    // Tests that create throwaway models call stopPeriodicRescan() explicitly.

    func rescan() {
        currentScanTask?.cancel()
        let profilesToScan = self.profiles
        let cacheToUse = self.scanCache
        currentScanTask = Task {
            let (scannedSessions, updatedCache) = await Task.detached {
                var localCache = cacheToUse
                let results = TranscriptScanner.scan(profiles: profilesToScan, cache: &localCache)
                return (results, localCache)
            }.value

            guard !Task.isCancelled else { return }
            self.sessions = scannedSessions
            self.scanCache = updatedCache
            self.lastScanAt = Date()
        }
    }

    func startPeriodicRescan(every seconds: TimeInterval = 30) {
        guard periodicTimer == nil else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rescan()
            }
        }
    }

    func stopPeriodicRescan() {
        periodicTimer?.invalidate()
        periodicTimer = nil
    }

    func saveProfiles(_ newProfiles: [Profile]) {
        profileStore.save(newProfiles)
        self.profiles = newProfiles
        live.updateProfiles(newProfiles)
    }

    var visibleSessions: [Session] {
        if let selectedProfile {
            return sessions.filter { $0.profile == selectedProfile }
        }
        return sessions
    }

    var visibleLive: [SessionSnapshot] {
        live.liveSessions(profile: selectedProfile)
    }

    #if DEBUG
    func setSessionsForTesting(_ sessions: [Session]) {
        self.sessions = sessions
    }
    #endif
}
