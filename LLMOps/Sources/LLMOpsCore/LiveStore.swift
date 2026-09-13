import Foundation
import Observation
import CodeIslandCore

/// Injectable time source so tests do not sleep.
public protocol LiveClock: Sendable {
    var now: Date { get }
    /// Schedules `work` after `delay`; returns a cancel handle.
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void
}

public struct SystemClock: LiveClock {
    public init() {}

    public var now: Date { Date() }

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> () -> Void {
        let item = DispatchWorkItem {
            work()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return {
            item.cancel()
        }
    }
}

@MainActor @Observable
public final class LiveStore: HookSink {
    public static let permissionTimeout: TimeInterval = 110
    public static let endedRetention: TimeInterval = 60
    public static let maxHistory = 50

    public private(set) var sessions: [String: SessionSnapshot]
    public private(set) var pending: [PendingPermission]       // oldest first
    public private(set) var profileOf: [String: String]        // sessionId -> profile id
    public private(set) var endedAt: [String: Date]            // sessionId -> when it ended
    public var onSound: ((String) -> Void)?                   // sound name from SideEffect.playSound, plus "PermissionRequest" on each permission

    private var profiles: [Profile]
    private let clock: LiveClock
    private var pendingReplies: [UUID: @Sendable (Decision) -> Void] = [:]
    private var pendingCancelHandles: [UUID: () -> Void] = [:]
    private var purgeCancelHandles: [String: () -> Void] = [:]

    public init(profiles: [Profile], clock: LiveClock = SystemClock()) {
        self.sessions = [:]
        self.pending = []
        self.profileOf = [:]
        self.endedAt = [:]
        self.profiles = profiles
        self.clock = clock
    }

    public func updateProfiles(_ profiles: [Profile]) {
        self.profiles = profiles
    }

    public func handle(event: HookEvent, cwd: String?) {
        let sessionId = event.sessionId ?? "default"
        let eventName = EventNormalizer.normalize(event.eventName)

        if eventName != "SessionEnd" {
            if endedAt[sessionId] != nil {
                endedAt.removeValue(forKey: sessionId)
                purgeCancelHandles[sessionId]?()
                purgeCancelHandles.removeValue(forKey: sessionId)
            }
        }

        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: Self.maxHistory)

        for effect in effects {
            switch effect {
            case .playSound(let name):
                onSound?(name)
            case .removeSession(let id):
                // If this is SessionEnd, retention/purge handles removal.
                // For any other event emitting removeSession, remove immediately.
                if eventName != "SessionEnd" {
                    sessions.removeValue(forKey: id)
                    profileOf.removeValue(forKey: id)
                    endedAt.removeValue(forKey: id)
                }
            case .tryMonitorSession, .stopMonitor, .enqueueCompletion, .setActiveSession:
                break
            }
        }

        let effectiveCwd = cwd ?? sessions[sessionId]?.cwd
        if let effectiveCwd, profileOf[sessionId] == nil {
            if let profile = ProfileResolver.resolve(cwd: effectiveCwd, profiles: profiles) {
                profileOf[sessionId] = profile.id
            }
        }

        if eventName == "SessionEnd" {
            endedAt[sessionId] = clock.now
            schedulePurge(for: sessionId)
            // Deny any pending items for this ended session
            let sessionPending = pending.filter { $0.sessionId == sessionId }
            for item in sessionPending {
                resolve(id: item.id, decision: .deny)
            }
        }
    }

    public func permissionRequested(event: HookEvent, cwd: String?, reply: @escaping @Sendable (Decision) -> Void) {
        handle(event: event, cwd: cwd)
        let sessionId = event.sessionId ?? "default"
        sessions[sessionId]?.status = .waitingApproval
        if sessions[sessionId]?.currentTool == nil {
            sessions[sessionId]?.currentTool = event.toolName
        }
        if sessions[sessionId]?.toolDescription == nil {
            sessions[sessionId]?.toolDescription = event.toolDescription
        }

        let id = UUID()
        let item = PendingPermission(
            id: id,
            sessionId: sessionId,
            kind: .permission,
            toolName: event.toolName,
            description: event.toolDescription,
            options: nil,
            receivedAt: clock.now
        )
        pending.append(item)
        pendingReplies[id] = reply
        onSound?("PermissionRequest")

        let cancel = clock.schedule(after: Self.permissionTimeout) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.resolve(id: id, decision: .deny)
                }
            } else {
                Task { @MainActor in
                    self?.resolve(id: id, decision: .deny)
                }
            }
        }
        pendingCancelHandles[id] = cancel
    }

    public func questionAsked(event: HookEvent, cwd: String?, reply: @escaping @Sendable (Decision) -> Void) {
        handle(event: event, cwd: cwd)
        let sessionId = event.sessionId ?? "default"
        let payload = QuestionPayload.from(event: event)

        let id = UUID()
        let item = PendingPermission(
            id: id,
            sessionId: sessionId,
            kind: .question,
            toolName: event.toolName,
            description: payload?.question,
            options: payload?.options,
            receivedAt: clock.now
        )
        pending.append(item)
        pendingReplies[id] = reply

        let cancel = clock.schedule(after: Self.permissionTimeout) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.resolve(id: id, decision: .deny)
                }
            } else {
                Task { @MainActor in
                    self?.resolve(id: id, decision: .deny)
                }
            }
        }
        pendingCancelHandles[id] = cancel
    }

    public func peerDisconnected(sessionId: String) {
        endedAt[sessionId] = clock.now
        schedulePurge(for: sessionId)

        let sessionPending = pending.filter { $0.sessionId == sessionId }
        for item in sessionPending {
            resolve(id: item.id, decision: .deny)
        }
    }

    public func resolve(id: UUID, decision: Decision) {
        guard let reply = pendingReplies.removeValue(forKey: id) else {
            return
        }
        pendingCancelHandles[id]?()
        pendingCancelHandles.removeValue(forKey: id)
        pending.removeAll { $0.id == id }
        reply(decision)
    }

    /// Ids of the sessions `liveSessions(profile:)` would return, same order.
    /// SessionSnapshot carries no id, so views that need one start here.
    public func liveSessionIds(profile: String?) -> [String] {
        let currentNow = clock.now
        var result: [(id: String, lastActivity: Date)] = []

        for (sessionId, session) in sessions {
            if let ended = endedAt[sessionId] {
                if currentNow.timeIntervalSince(ended) >= Self.endedRetention {
                    continue
                }
            }
            if let profile {
                guard profileOf[sessionId] == profile else {
                    continue
                }
            }
            result.append((sessionId, session.lastActivity))
        }

        return result.sorted { $0.lastActivity > $1.lastActivity }.map(\.id)
    }

    public func liveSessions(profile: String?) -> [SessionSnapshot] {
        liveSessionIds(profile: profile).compactMap { sessions[$0] }
    }

    private func schedulePurge(for sessionId: String) {
        purgeCancelHandles[sessionId]?()
        let cancel = clock.schedule(after: Self.endedRetention) { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.endedAt[sessionId] != nil {
                        self.sessions.removeValue(forKey: sessionId)
                        self.profileOf.removeValue(forKey: sessionId)
                        self.endedAt.removeValue(forKey: sessionId)
                        self.purgeCancelHandles.removeValue(forKey: sessionId)
                    }
                }
            } else {
                Task { @MainActor in
                    guard let self else { return }
                    if self.endedAt[sessionId] != nil {
                        self.sessions.removeValue(forKey: sessionId)
                        self.profileOf.removeValue(forKey: sessionId)
                        self.endedAt.removeValue(forKey: sessionId)
                        self.purgeCancelHandles.removeValue(forKey: sessionId)
                    }
                }
            }
        }
        purgeCancelHandles[sessionId] = cancel
    }
}
