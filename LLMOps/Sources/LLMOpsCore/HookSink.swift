import Foundation
import CodeIslandCore

public enum Decision: Equatable, Sendable {
    case allow
    case deny
    case answer(String)   // for AskUserQuestion style prompts

    /// JSON the hook expects on stdout. EXACT strings:
    /// allow  -> {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
    /// deny   -> {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}
    /// answer -> {"hookSpecificOutput":{"hookEventName":"Notification","answer":"<text JSON-escaped>"}}
    public var replyJSON: Data {
        switch self {
        case .allow:
            return Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#.utf8)
        case .deny:
            return Data(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#.utf8)
        case .answer(let text):
            let escaped: Data
            if let enc = try? JSONEncoder().encode(text) {
                escaped = enc
            } else {
                escaped = Data(#""""#.utf8)
            }
            return Data(#"{"hookSpecificOutput":{"hookEventName":"Notification","answer":"#.utf8 + escaped + #"}}"#.utf8)
        }
    }
}

/// What the socket server calls. Implemented by LiveStore.
@MainActor
public protocol HookSink: AnyObject {
    func handle(event: HookEvent, cwd: String?)
    /// `reply` must be called exactly once, on any thread.
    func permissionRequested(event: HookEvent, cwd: String?, reply: @escaping @Sendable (Decision) -> Void)
    func questionAsked(event: HookEvent, cwd: String?, reply: @escaping @Sendable (Decision) -> Void)
    func peerDisconnected(sessionId: String)
}
