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
    private(set) var isScanning: Bool = false
    private let scanner: @Sendable ([Profile], inout TranscriptScanner.ScanCache) -> [Session]

    var isRescanning: Bool {
        periodicTimer != nil
    }

    let settings: LLMOpsSettings
    let sounds: SoundManager
    private(set) var server: HookServer?
    var isServerListening: Bool { server?.isListening ?? false }

    init(
        userDefaults: UserDefaults = .standard,
        scanner: @escaping @Sendable ([Profile], inout TranscriptScanner.ScanCache) -> [Session] = { TranscriptScanner.scan(profiles: $0, cache: &$1) }
    ) {
        let store = ProfileStore(userDefaults: userDefaults)
        let loaded = store.load()
        let settings = LLMOpsSettings(userDefaults: userDefaults)
        let sounds = SoundManager(settings: settings)
        self.profileStore = store
        self.profiles = loaded
        self.settings = settings
        self.sounds = sounds
        self.scanner = scanner
        let liveStore = LiveStore(profiles: loaded)
        liveStore.onSound = { [sounds] name in
            sounds.handleEvent(name)
        }
        self.live = liveStore
        // Task 7.3: a finished session is in the transcript now; pick it up
        // without waiting for the 30s tick. rescan() ignores in-flight scans.
        live.onSessionEnd = { [weak self] _ in
            self?.rescan()
        }
    }

    // No deinit: AppModel lives for the whole app lifetime, and a nonisolated
    // deinit cannot touch main-actor state under strict concurrency anyway.
    // Tests that create throwaway models call stopPeriodicRescan() explicitly.

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let profilesToScan = self.profiles
        let cacheToUse = self.scanCache
        let scanFn = self.scanner
        currentScanTask = Task {
            defer { self.isScanning = false }
            let (scannedSessions, updatedCache) = await Task.detached {
                var localCache = cacheToUse
                let results = scanFn(profilesToScan, &localCache)
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

    private func serverConfig(from settings: LLMOpsSettings) -> HookServerConfig {
        HookServerConfig(
            autoApproveTools: Set(settings.autoApproveTools),
            excludedCwdSubstrings: settings.excludedCwdSubstrings
        )
    }

    /// `socketPath` nil means the default `SocketPath.path`; tests pass a temp path.
    func startServer(socketPath: String? = nil) {
        guard server == nil else { return }
        let s = HookServer(
            sink: live,
            config: serverConfig(from: settings),
            socketPath: socketPath ?? SocketPath.path
        )
        s.start()
        self.server = s
    }

    func stopServer() {
        server?.stop()
        server = nil
    }

    func applySettingsToServer() {
        server?.config = serverConfig(from: settings)
    }

    #if DEBUG
    func setSessionsForTesting(_ sessions: [Session]) {
        self.sessions = sessions
    }
    #endif
}
