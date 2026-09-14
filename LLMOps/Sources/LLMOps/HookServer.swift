import Foundation
import Network
import os.log
import CodeIslandCore
import LLMOpsCore

public struct HookServerConfig: Sendable {
    /// Tool names auto-approved without asking the sink (PermissionRequest for
    /// these replies allow immediately). Default: [] (ask for everything).
    public var autoApproveTools: Set<String>
    /// If the event's cwd contains any of these substrings, the event is
    /// dropped (PermissionRequest replies allow so the hook never blocks).
    public var excludedCwdSubstrings: [String]

    public init(autoApproveTools: Set<String> = [], excludedCwdSubstrings: [String] = []) {
        self.autoApproveTools = autoApproveTools
        self.excludedCwdSubstrings = excludedCwdSubstrings
    }
}

@MainActor
public final class HookServer {
    public static var socketPath: String { SocketPath.path }
    public private(set) var isListening: Bool = false
    public var config: HookServerConfig
    public let socketPath: String

    private let sink: any HookSink
    private var listener: NWListener?
    private let log = Logger(subsystem: "dev.samdev.llmops", category: "HookServer")

    public init(sink: any HookSink, config: HookServerConfig = HookServerConfig(), socketPath: String = SocketPath.path) {
        self.sink = sink
        self.config = config
        self.socketPath = socketPath
    }

    public func start() {
        guard !isListening else { return }

        unlink(socketPath)

        let previousUmask = umask(0o077)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        do {
            listener = try NWListener(using: params)
        } catch {
            umask(previousUmask)
            log.error("Failed to create NWListener: \(error.localizedDescription)")
            return
        }

        umask(previousUmask)
        chmod(socketPath, 0o600)

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleConnection(connection)
            }
        }

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .ready:
                    chmod(self.socketPath, 0o600)
                    self.log.info("HookServer listening on \(self.socketPath)")
                case .failed(let error):
                    self.isListening = false
                    self.log.error("HookServer failed: \(error.localizedDescription)")
                default:
                    break
                }
            }
        }

        listener?.start(queue: .main)
        isListening = true
    }

    public func stop() {
        guard isListening || listener != nil else {
            unlink(socketPath)
            return
        }
        isListening = false
        listener?.cancel()
        listener = nil
        unlink(socketPath)
    }

    private final class ConnectionContext {
        var isHeld: Bool = false
        var responded: Bool = false
        var disconnectedNotified: Bool = false
        var sessionId: String?
    }

    private var connectionContexts: [ObjectIdentifier: ConnectionContext] = [:]

    private func handleConnection(_ connection: NWConnection) {
        let context = ConnectionContext()
        let connId = ObjectIdentifier(connection)
        connectionContexts[connId] = context

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self = self else { return }
                switch state {
                case .cancelled, .failed:
                    if context.isHeld && !context.responded && !context.disconnectedNotified {
                        context.disconnectedNotified = true
                        if let sessionId = context.sessionId {
                            self.sink.peerDisconnected(sessionId: sessionId)
                        }
                    }
                    self.connectionContexts.removeValue(forKey: connId)
                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
        receiveAll(connection: connection, accumulated: Data())
    }

    private static let maxPayloadSize = 1_048_576 // 1 MiB

    /// Recursively receive all data until EOF, then process
    private func receiveAll(connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            Task { @MainActor in
                guard let self = self else { return }

                // On error with no data, just drop the connection
                if error != nil && accumulated.isEmpty && content == nil {
                    connection.cancel()
                    return
                }

                var data = accumulated
                if let content { data.append(content) }

                // Safety: reject oversized payloads with a deny reply
                if data.count > Self.maxPayloadSize {
                    self.log.warning("Payload too large (\(data.count) bytes), dropping connection")
                    self.sendResponse(connection: connection, data: Decision.deny.replyJSON)
                    return
                }

                if isComplete || error != nil {
                    self.processRequest(data: data, connection: connection)
                } else {
                    self.receiveAll(connection: connection, accumulated: data)
                }
            }
        }
    }

    private func isExcludedCwd(_ cwd: String) -> Bool {
        guard !cwd.isEmpty else { return false }
        for pattern in config.excludedCwdSubstrings {
            let trimmed = pattern.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && cwd.contains(trimmed) {
                return true
            }
        }
        return false
    }

    private func processRequest(data: Data, connection: NWConnection) {
        guard let event = HookEvent(from: data) else {
            sendResponse(connection: connection, data: Data("{}".utf8))
            return
        }

        let cwd = event.rawJSON["cwd"] as? String

        if let cwd = cwd, isExcludedCwd(cwd) {
            let normalized = EventNormalizer.normalize(event.eventName)
            if normalized == "PermissionRequest" {
                sendResponse(connection: connection, data: Decision.allow.replyJSON)
            } else {
                sendResponse(connection: connection, data: Data("{}".utf8))
            }
            return
        }

        if event.toolName == "AskUserQuestion" {
            if let context = connectionContexts[ObjectIdentifier(connection)] {
                context.isHeld = true
                context.sessionId = event.sessionId
            }
            sink.questionAsked(event: event, cwd: cwd) { [weak self, connection] decision in
                Task { @MainActor in
                    self?.sendResponse(connection: connection, data: decision.replyJSON)
                }
            }
            return
        }

        let normalized = EventNormalizer.normalize(event.eventName)
        switch normalized {
        case "PermissionRequest":
            if let toolName = event.toolName, config.autoApproveTools.contains(toolName) {
                sendResponse(connection: connection, data: Decision.allow.replyJSON)
                sink.handle(event: event, cwd: cwd)
            } else {
                if let context = connectionContexts[ObjectIdentifier(connection)] {
                    context.isHeld = true
                    context.sessionId = event.sessionId
                }
                // Strong capture on purpose: nothing else retains the connection
                // while the user decides (up to 110s), and sendResponse cancels it.
                sink.permissionRequested(event: event, cwd: cwd) { [weak self, connection] decision in
                    Task { @MainActor in
                        self?.sendResponse(connection: connection, data: decision.replyJSON)
                    }
                }
            }
        case "Notification" where QuestionPayload.from(event: event) != nil:
            if let context = connectionContexts[ObjectIdentifier(connection)] {
                context.isHeld = true
                context.sessionId = event.sessionId
            }
            sink.questionAsked(event: event, cwd: cwd) { [weak self, connection] decision in
                Task { @MainActor in
                    self?.sendResponse(connection: connection, data: decision.replyJSON)
                }
            }
        case "SessionEnd":
            sink.handle(event: event, cwd: cwd)
            sendResponse(connection: connection, data: Data("{}".utf8))
            if let sessionId = event.sessionId {
                sink.peerDisconnected(sessionId: sessionId)
            }
        default:
            sink.handle(event: event, cwd: cwd)
            sendResponse(connection: connection, data: Data("{}".utf8))
        }
    }

    private func sendResponse(connection: NWConnection, data: Data) {
        if let context = connectionContexts[ObjectIdentifier(connection)] {
            context.responded = true
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error = error {
                self?.log.error("Failed to send response: \(error.localizedDescription)")
            }
            connection.cancel()
        })
    }
}
