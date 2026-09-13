import Foundation
import CodeIslandCore
import LLMOpsCore

struct LiveRow: Identifiable, Equatable {
    let id: String                 // sessionId
    let title: String              // SessionSnapshot.displayTitle(sessionId:) or "session <first 8 chars>"
    let project: String            // last path component of cwd, or "unknown"
    let profile: String?           // profile id
    let status: AgentStatus
    let currentTool: String?
    let toolDescription: String?
    let lastUserPrompt: String?
    let startedAt: Date
    let lastActivity: Date
    let subagentCount: Int         // snapshot.subagents.count
    let isEnded: Bool              // store.endedAt[sessionId] != nil
}

enum LiveViewModel {
    /// Rows for `store.liveSessions(profile:)`, mapped 1:1, order preserved (lastActivity desc).
    @MainActor
    static func rows(from store: LiveStore, profile: String?) -> [LiveRow] {
        var rows: [LiveRow] = []

        for sessionId in store.liveSessionIds(profile: profile) {
            guard let snapshot = store.sessions[sessionId] else { continue }

            let title: String
            if snapshot.sessionLabel != nil {
                title = snapshot.displayTitle(sessionId: sessionId)
            } else {
                title = "session \(sessionId.prefix(8))"
            }

            let project: String
            if let cwd = snapshot.cwd {
                let name = (cwd as NSString).lastPathComponent
                project = (name.isEmpty || name == "/") ? "unknown" : name
            } else {
                project = "unknown"
            }

            let rowProfile = store.profileOf[sessionId]
            let isEnded = store.endedAt[sessionId] != nil

            rows.append(LiveRow(
                id: sessionId,
                title: title,
                project: project,
                profile: rowProfile,
                status: snapshot.status,
                currentTool: snapshot.currentTool,
                toolDescription: snapshot.toolDescription,
                lastUserPrompt: snapshot.lastUserPrompt,
                startedAt: snapshot.startTime,
                lastActivity: snapshot.lastActivity,
                subagentCount: snapshot.subagents.count,
                isEnded: isEnded
            ))
        }

        return rows
    }

    /// Pending items for the selected profile (nil = all), oldest first; an item
    /// belongs to a profile through `store.profileOf[item.sessionId]`.
    @MainActor
    static func pending(from store: LiveStore, profile: String?) -> [PendingPermission] {
        if let profile {
            return store.pending.filter { store.profileOf[$0.sessionId] == profile }
        }
        return store.pending
    }

    /// "12s", "4m 03s", "1h 12m" style elapsed text; pure.
    static func elapsedText(from start: Date, to now: Date) -> String {
        let totalSeconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        } else if minutes > 0 {
            return String(format: "%dm %02ds", minutes, seconds)
        } else {
            return "\(seconds)s"
        }
    }
}
