import Foundation

public struct PendingPermission: Identifiable, Sendable {
    public enum Kind: Sendable { case permission, question }
    public let id: UUID
    public let sessionId: String
    public let kind: Kind
    public let toolName: String?
    public let description: String?        // HookEvent.toolDescription for permissions; question text for questions
    public let options: [String]?          // question options, nil for permissions
    public let receivedAt: Date

    public init(
        id: UUID = UUID(),
        sessionId: String,
        kind: Kind,
        toolName: String? = nil,
        description: String? = nil,
        options: [String]? = nil,
        receivedAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.kind = kind
        self.toolName = toolName
        self.description = description
        self.options = options
        self.receivedAt = receivedAt
    }
}
