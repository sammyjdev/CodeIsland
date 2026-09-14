import AppKit
import Foundation
import Testing
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

final class FakeClock: LiveClock, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var scheduled: [(id: UUID, time: Date, work: @Sendable () -> Void)] = []

    init(now: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self._now = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    func setNow(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        _now = date
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        let fireTime = _now.addingTimeInterval(delay)
        scheduled.append((id: id, time: fireTime, work: work))
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            self.scheduled.removeAll { $0.id == id }
        }
    }

    func fire(upTo targetTime: Date) {
        while true {
            let toRun: (@Sendable () -> Void)? = {
                lock.lock()
                defer { lock.unlock() }
                _now = max(_now, targetTime)
                if let index = scheduled.indices.filter({ scheduled[$0].time <= targetTime }).min(by: { scheduled[$0].time < scheduled[$1].time }) {
                    let item = scheduled.remove(at: index)
                    return item.work
                }
                return nil
            }()

            if let work = toRun {
                work()
            } else {
                break
            }
        }
    }
}

@Suite(.serialized) struct LiveViewModelTests {
    // 1. Two sessions with different lastActivity -> rows ordered newest first;
    // title falls back to "session <8 chars>" when no title metadata exists;
    // project is the cwd basename.
    @Test @MainActor func orderingAndFallbackTitleAndProject() throws {
        let clock = FakeClock()
        let store = LiveStore(profiles: [], clock: clock)

        let s1Start = try #require(HookEvent(from: Data(#"{"hook_event_name":"SessionStart","session_id":"s1-abcdef123456","cwd":"/tmp/projectAlpha"}"#.utf8)))
        store.handle(event: s1Start, cwd: "/tmp/projectAlpha")

        Thread.sleep(forTimeInterval: 0.02)

        let s2Start = try #require(HookEvent(from: Data(#"{"hook_event_name":"SessionStart","session_id":"s2-987654321000","cwd":"/Users/test/dev/projectBeta"}"#.utf8)))
        store.handle(event: s2Start, cwd: "/Users/test/dev/projectBeta")

        let rows = LiveViewModel.rows(from: store, profile: nil)
        #expect(rows.count == 2)
        #expect(rows[0].id == "s2-987654321000")
        #expect(rows[0].title == "session s2-98765")
        #expect(rows[0].project == "projectBeta")

        #expect(rows[1].id == "s1-abcdef123456")
        #expect(rows[1].title == "session s1-abcde")
        #expect(rows[1].project == "projectAlpha")

        // Title metadata uses displayTitle
        let s3Start = try #require(HookEvent(from: Data(#"{"hook_event_name":"SessionStart","session_id":"s3-custom-title","session_title":"Feature Branch"}"#.utf8)))
        store.handle(event: s3Start, cwd: "/tmp/projectGamma")
        let rowsWithTitle = LiveViewModel.rows(from: store, profile: nil)
        let rowS3 = rowsWithTitle.first { $0.id == "s3-custom-title" }
        #expect(rowS3?.title == "Feature Branch")
    }

    // 2. Profile filter: with profiles pessoal/afya (afya prefix "/tmp/afya"),
    // rows(profile: "afya") returns only the session whose cwd is under "/tmp/afya";
    // pending(profile: "afya") returns only that session's pending permission.
    @Test @MainActor func profileFiltering() throws {
        let clock = FakeClock()
        let profiles = [
            Profile(id: "pessoal", name: "Pessoal", configDir: "~/.pessoal", pathPrefixes: ["/tmp/pessoal"]),
            Profile(id: "afya", name: "Afya", configDir: "~/.afya", pathPrefixes: ["/tmp/afya"])
        ]
        let store = LiveStore(profiles: profiles, clock: clock)

        let s1Start = try #require(HookEvent(from: Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8)))
        store.handle(event: s1Start, cwd: "/tmp/pessoal/my-app")

        let s2Start = try #require(HookEvent(from: Data(#"{"hook_event_name":"SessionStart","session_id":"s2"}"#.utf8)))
        store.handle(event: s2Start, cwd: "/tmp/afya/hospital-service")

        let p1Event = try #require(HookEvent(from: Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)))
        store.permissionRequested(event: p1Event, cwd: "/tmp/pessoal/my-app") { _ in }

        let p2Event = try #require(HookEvent(from: Data(#"{"hook_event_name":"PermissionRequest","session_id":"s2","tool_name":"Edit","tool_input":{"file":"a.txt"}}"#.utf8)))
        store.permissionRequested(event: p2Event, cwd: "/tmp/afya/hospital-service") { _ in }

        let afyaRows = LiveViewModel.rows(from: store, profile: "afya")
        #expect(afyaRows.count == 1)
        #expect(afyaRows.first?.id == "s2")
        #expect(afyaRows.first?.profile == "afya")

        let afyaPending = LiveViewModel.pending(from: store, profile: "afya")
        #expect(afyaPending.count == 1)
        #expect(afyaPending.first?.sessionId == "s2")

        let allRows = LiveViewModel.rows(from: store, profile: nil)
        #expect(allRows.count == 2)

        let allPending = LiveViewModel.pending(from: store, profile: nil)
        #expect(allPending.count == 2)
    }

    // 3. A PermissionRequest makes rows report status == .waitingApproval and
    // pending has one item with kind == .permission.
    @Test @MainActor func permissionRequestStatusAndKind() throws {
        let clock = FakeClock()
        let store = LiveStore(profiles: [], clock: clock)

        let s1Start = try #require(HookEvent(from: Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8)))
        store.handle(event: s1Start, cwd: "/tmp/proj")

        let p1Event = try #require(HookEvent(from: Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"make build"}}"#.utf8)))
        store.permissionRequested(event: p1Event, cwd: "/tmp/proj") { _ in }

        let rows = LiveViewModel.rows(from: store, profile: nil)
        #expect(rows.first?.status == .waitingApproval)

        let pending = LiveViewModel.pending(from: store, profile: nil)
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .permission)
    }

    // 4. elapsedText: 12 s -> "12s"; 243 s -> "4m 03s"; 4320 s -> "1h 12m".
    @Test func elapsedTextFormatting() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(LiveViewModel.elapsedText(from: now.addingTimeInterval(-12), to: now) == "12s")
        #expect(LiveViewModel.elapsedText(from: now.addingTimeInterval(-243), to: now) == "4m 03s")
        #expect(LiveViewModel.elapsedText(from: now.addingTimeInterval(-4320), to: now) == "1h 12m")
    }

    // 5. AppModel (fresh UserDefaults suite): startServer(socketPath:) twice creates a single
    // server and isServerListening == true (passes unique temp path without touching env);
    // stopServer() removes the socket file; live.onSound is non-nil after init.
    @Test @MainActor func appModelServerLifecycleAndSoundWiring() async throws {
        let suite = "LiveAppModelTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let tempSocket = "/tmp/llmops-test-\(UUID().uuidString).sock"
        defer {
            unlink(tempSocket)
        }

        let model = AppModel(userDefaults: defaults)
        #expect(model.live.onSound != nil)
        #expect(model.server == nil)
        #expect(model.isServerListening == false)

        model.startServer(socketPath: tempSocket)
        let server1 = model.server
        #expect(server1 != nil)
        #expect(model.isServerListening == true)

        model.startServer(socketPath: tempSocket)
        #expect(model.server === server1)

        var found = false
        for _ in 0..<50 {
            if FileManager.default.fileExists(atPath: tempSocket) {
                found = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(found)

        model.stopServer()
        #expect(model.server == nil)
        #expect(model.isServerListening == false)
        #expect(!FileManager.default.fileExists(atPath: tempSocket))
    }

    // 6. Settings to server: after settings.autoApproveTools = ["Read"] and
    // applySettingsToServer(), model.server?.config.autoApproveTools == ["Read"].
    @Test @MainActor func settingsToServerConfig() async throws {
        let suite = "LiveAppModelTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let tempSocket = "/tmp/llmops-test-\(UUID().uuidString).sock"
        defer {
            unlink(tempSocket)
        }

        let model = AppModel(userDefaults: defaults)
        model.startServer(socketPath: tempSocket)
        defer { model.stopServer() }

        #expect(model.server?.config.autoApproveTools == [])

        model.settings.autoApproveTools = ["Read"]
        model.applySettingsToServer()

        #expect(model.server?.config.autoApproveTools == ["Read"])
    }

    // 7. StatusDot color for waiting states is magentaBright; cyan is kept only on the hero element.
    @Test func statusDotWaitingColorsAreMagentaBright() {
        #expect(StatusDot.color(for: .waitingApproval) == Theme.Colors.magentaBright)
        #expect(StatusDot.color(for: .waitingQuestion) == Theme.Colors.magentaBright)
    }
}
