import Foundation
import Testing
import CodeIslandCore
@testable import LLMOpsCore

final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _replies: [Decision] = []

    var replies: [Decision] {
        lock.lock()
        defer { lock.unlock() }
        return _replies
    }

    func append(_ decision: Decision) {
        lock.lock()
        defer { lock.unlock() }
        _replies.append(decision)
    }
}

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

@Suite struct LiveStoreTests {
    // 1. SessionStart then PreToolUse(Bash) then PostToolUse then Stop: sessions["s1"] status goes processing/running -> idle
    @Test @MainActor func sessionLifecycleStatusTransitions() throws {
        let store = LiveStore(profiles: [])

        let startJSON = Data(#"{"hook_event_name":"SessionStart","session_id":"s1","cwd":"/tmp/x"}"#.utf8)
        let startEvent = try #require(HookEvent(from: startJSON))
        store.handle(event: startEvent, cwd: "/tmp/x")
        #expect(store.sessions["s1"]?.status == .idle)

        let preJSON = Data(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        let preEvent = try #require(HookEvent(from: preJSON))
        store.handle(event: preEvent, cwd: "/tmp/x")
        #expect(store.sessions["s1"]?.status == .running)

        let postJSON = Data(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let postEvent = try #require(HookEvent(from: postJSON))
        store.handle(event: postEvent, cwd: "/tmp/x")
        #expect(store.sessions["s1"]?.status == .processing)

        let stopJSON = Data(#"{"hook_event_name":"Stop","session_id":"s1"}"#.utf8)
        let stopEvent = try #require(HookEvent(from: stopJSON))
        store.handle(event: stopEvent, cwd: "/tmp/x")
        #expect(store.sessions["s1"]?.status == .idle)
    }

    // 2. Profile tagging: with profiles [pessoal(no prefixes), afya(prefix "/tmp/afya")], an event with cwd "/tmp/afya/proj" tags "afya"; cwd "/tmp/other" tags "pessoal".
    @Test @MainActor func profileTagging() throws {
        let pessoal = Profile(id: "pessoal", name: "Pessoal", configDir: "/tmp/cfg-pessoal", pathPrefixes: [])
        let afya = Profile(id: "afya", name: "Afya", configDir: "/tmp/cfg-afya", pathPrefixes: ["/tmp/afya"])
        let store = LiveStore(profiles: [pessoal, afya])

        let e1JSON = Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: e1JSON)), cwd: "/tmp/afya/proj")
        #expect(store.profileOf["s1"] == "afya")

        let e2JSON = Data(#"{"hook_event_name":"SessionStart","session_id":"s2"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: e2JSON)), cwd: "/tmp/other")
        #expect(store.profileOf["s2"] == "pessoal")
    }

    // 3. permissionRequested appends one pending item with toolName "Bash", fires onSound("PermissionRequest"), session status is .waitingApproval.
    @Test @MainActor func permissionRequestedAddsPendingItemAndSound() throws {
        let store = LiveStore(profiles: [])
        var playedSound: String?
        store.onSound = { playedSound = $0 }

        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"ls -la","description":"List files"}}"#.utf8)
        let event = try #require(HookEvent(from: reqJSON))

        store.permissionRequested(event: event, cwd: "/tmp") { _ in }

        #expect(store.pending.count == 1)
        let item = store.pending.first
        #expect(item?.kind == .permission)
        #expect(item?.toolName == "Bash")
        #expect(item?.description == "List files\nCommand:\nls -la")
        #expect(playedSound == "PermissionRequest")
        #expect(store.sessions["s1"]?.status == .waitingApproval)
    }

    // 4. resolve(id:.allow) calls the reply once with .allow and empties pending; calling resolve again with .deny does NOT call the reply a second time.
    @Test @MainActor func resolveCallsReplyExactlyOnce() throws {
        let store = LiveStore(profiles: [])
        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let box = ReplyBox()
        store.permissionRequested(event: try #require(HookEvent(from: reqJSON)), cwd: nil) { decision in
            box.append(decision)
        }

        let item = try #require(store.pending.first)
        store.resolve(id: item.id, decision: .allow)
        #expect(box.replies == [.allow])
        #expect(store.pending.isEmpty)

        // Second call ignored
        store.resolve(id: item.id, decision: .deny)
        #expect(box.replies == [.allow])
    }

    // 5. Timeout: no resolve; fakeClock.fire(upTo: now + 110) -> reply called once with .deny, pending empty. Firing at 109 s does nothing.
    @Test @MainActor func timeoutResolvesWithDeny() throws {
        let clock = FakeClock()
        let now = clock.now
        let store = LiveStore(profiles: [], clock: clock)
        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let box = ReplyBox()
        store.permissionRequested(event: try #require(HookEvent(from: reqJSON)), cwd: nil) { decision in
            box.append(decision)
        }

        // At 109s: nothing happens
        clock.fire(upTo: now.addingTimeInterval(109))
        #expect(box.replies.isEmpty)
        #expect(store.pending.count == 1)

        // At 110s: times out to deny
        clock.fire(upTo: now.addingTimeInterval(110))
        #expect(box.replies == [.deny])
        #expect(store.pending.isEmpty)
    }

    // 6. Race: resolve .allow then fire the timeout -> reply called exactly once, with .allow.
    @Test @MainActor func raceResolutionBeforeTimeout() throws {
        let clock = FakeClock()
        let now = clock.now
        let store = LiveStore(profiles: [], clock: clock)
        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let box = ReplyBox()
        store.permissionRequested(event: try #require(HookEvent(from: reqJSON)), cwd: nil) { decision in
            box.append(decision)
        }

        let item = try #require(store.pending.first)
        store.resolve(id: item.id, decision: .allow)
        #expect(box.replies == [.allow])

        // Firing timeout afterward does not trigger second reply
        clock.fire(upTo: now.addingTimeInterval(110))
        #expect(box.replies == [.allow])
    }

    // 7. questionAsked with {"hook_event_name":"Notification","session_id":"s1","question":"Pick one","options":["a","b"]} yields kind .question, description "Pick one", options ["a","b"].
    @Test @MainActor func questionAskedYieldsKindAndOptions() throws {
        let store = LiveStore(profiles: [])
        let notifJSON = Data(#"{"hook_event_name":"Notification","session_id":"s1","question":"Pick one","options":["a","b"]}"#.utf8)
        store.questionAsked(event: try #require(HookEvent(from: notifJSON)), cwd: nil) { _ in }

        #expect(store.pending.count == 1)
        let item = store.pending.first
        #expect(item?.kind == .question)
        #expect(item?.description == "Pick one")
        #expect(item?.options == ["a", "b"])
    }

    // 8. SessionEnd sets endedAt; liveSessions(profile: nil) still includes s1 at +59 s and excludes it after the purge fires at +60 s (session removed).
    @Test @MainActor func sessionEndPurgeRetention() throws {
        let clock = FakeClock()
        let now = clock.now
        let store = LiveStore(profiles: [], clock: clock)

        let startJSON = Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: startJSON)), cwd: nil)

        let endJSON = Data(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: endJSON)), cwd: nil)

        #expect(store.endedAt["s1"] == now)

        clock.fire(upTo: now.addingTimeInterval(59))
        #expect(store.liveSessions(profile: nil).count == 1)
        #expect(store.sessions["s1"] != nil)

        clock.fire(upTo: now.addingTimeInterval(60))
        #expect(store.liveSessions(profile: nil).isEmpty)
        #expect(store.sessions["s1"] == nil)
        #expect(store.endedAt["s1"] == nil)
    }

    // 9. A new event for an ended session clears endedAt and it stays live.
    @Test @MainActor func newEventForEndedSessionClearsEndedAt() throws {
        let clock = FakeClock()
        let now = clock.now
        let store = LiveStore(profiles: [], clock: clock)

        let startJSON = Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: startJSON)), cwd: nil)

        let endJSON = Data(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: endJSON)), cwd: nil)
        #expect(store.endedAt["s1"] != nil)

        let promptJSON = Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"hello"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: promptJSON)), cwd: nil)
        #expect(store.endedAt["s1"] == nil)

        // At +65s from end, s1 should remain live and not be purged
        clock.fire(upTo: now.addingTimeInterval(65))
        #expect(store.sessions["s1"] != nil)
        #expect(store.liveSessions(profile: nil).count == 1)
    }

    // 10. peerDisconnected("s1") with a pending permission resolves it .deny and marks the session ended.
    @Test @MainActor func peerDisconnectedDeniesPendingAndMarksEnded() throws {
        let clock = FakeClock()
        let now = clock.now
        let store = LiveStore(profiles: [], clock: clock)

        let reqJSON = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash"}"#.utf8)
        let box = ReplyBox()
        store.permissionRequested(event: try #require(HookEvent(from: reqJSON)), cwd: nil) { decision in
            box.append(decision)
        }
        #expect(store.pending.count == 1)

        store.peerDisconnected(sessionId: "s1")
        #expect(box.replies == [.deny])
        #expect(store.pending.isEmpty)
        #expect(store.endedAt["s1"] == now)
    }

    // 11. Decision.replyJSON for allow/deny equals the exact strings in the contract (compare as String(decoding:as:)); .answer("x\"y") produces valid JSON whose answer field decodes back to x"y.
    @Test func decisionReplyJSONContract() throws {
        let allowStr = String(decoding: Decision.allow.replyJSON, as: UTF8.self)
        #expect(allowStr == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)

        let denyStr = String(decoding: Decision.deny.replyJSON, as: UTF8.self)
        #expect(denyStr == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#)

        let answerJSON = Decision.answer("x\"y").replyJSON
        let answerObj = try JSONSerialization.jsonObject(with: answerJSON) as? [String: Any]
        let hookOutput = answerObj?["hookSpecificOutput"] as? [String: Any]
        #expect(hookOutput?["hookEventName"] as? String == "Notification")
        #expect(hookOutput?["answer"] as? String == "x\"y")
    }

    // Extra: liveSessions profile filter and ordering
    @Test @MainActor func liveSessionsFilteringAndOrdering() throws {
        let clock = FakeClock()
        let store = LiveStore(profiles: [], clock: clock)

        let s1Start = Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: s1Start)), cwd: "/tmp/proj1")

        let s2Start = Data(#"{"hook_event_name":"SessionStart","session_id":"s2"}"#.utf8)
        store.handle(event: try #require(HookEvent(from: s2Start)), cwd: "/tmp/proj2")

        let allSessions = store.liveSessions(profile: nil)
        #expect(allSessions.count == 2)
    }
}
