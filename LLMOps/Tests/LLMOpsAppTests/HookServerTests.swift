import Foundation
import Testing
import Network
import CodeIslandCore
import LLMOpsCore
@testable import LLMOps

@MainActor
final class RecordingSink: HookSink {
    enum Record: Equatable {
        case handle(eventName: String, sessionId: String?, toolName: String?, cwd: String?)
        case permissionRequested(eventName: String, sessionId: String?, toolName: String?, cwd: String?)
        case questionAsked(eventName: String, sessionId: String?, question: String?, cwd: String?)
        case peerDisconnected(sessionId: String)
    }

    var records: [Record] = []
    var pendingPermissionReplies: [@Sendable (Decision) -> Void] = []
    var pendingQuestionReplies: [@Sendable (Decision) -> Void] = []

    func handle(event: HookEvent, cwd: String?) {
        records.append(.handle(
            eventName: event.eventName,
            sessionId: event.sessionId,
            toolName: event.toolName,
            cwd: cwd
        ))
    }

    func permissionRequested(event: HookEvent, cwd: String?, reply: @escaping @Sendable (Decision) -> Void) {
        records.append(.permissionRequested(
            eventName: event.eventName,
            sessionId: event.sessionId,
            toolName: event.toolName,
            cwd: cwd
        ))
        pendingPermissionReplies.append(reply)
    }

    func questionAsked(event: HookEvent, cwd: String?, reply: @escaping @Sendable (Decision) -> Void) {
        records.append(.questionAsked(
            eventName: event.eventName,
            sessionId: event.sessionId,
            question: QuestionPayload.from(event: event)?.question,
            cwd: cwd
        ))
        pendingQuestionReplies.append(reply)
    }

    func peerDisconnected(sessionId: String) {
        records.append(.peerDisconnected(sessionId: sessionId))
    }
}

final class ReplyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var _received = false
    var received: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }
    func markReceived() {
        lock.lock()
        defer { lock.unlock() }
        _received = true
    }
}

struct SocketClient: Sendable {
    let socketPath: String

    func send(data: Data, timeout: TimeInterval = 5.0) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                defer { close(fd) }

                var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                #if os(macOS)
                addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
                #endif
                let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
                guard socketPath.utf8.count < maxLen else {
                    throw POSIXError(.ENAMETOOLONG)
                }
                _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                    socketPath.withCString { cstr in
                        strncpy(ptr, cstr, maxLen - 1)
                    }
                }

                var connected = false
                let connectStart = Date()
                while !connected {
                    let connectRes = withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    if connectRes == 0 {
                        connected = true
                        break
                    }
                    if Date().timeIntervalSince(connectStart) > timeout {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
                    }
                    usleep(10_000)
                }

                var totalWritten = 0
                while totalWritten < data.count {
                    let written = data.withUnsafeBytes { raw in
                        write(fd, raw.baseAddress! + totalWritten, data.count - totalWritten)
                    }
                    if written <= 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    totalWritten += written
                }

                shutdown(fd, SHUT_WR)

                var response = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let bytesRead = read(fd, &buffer, buffer.count)
                    if bytesRead < 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if bytesRead == 0 {
                        break
                    }
                    response.append(buffer, count: bytesRead)
                }
                return response
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw POSIXError(.ETIMEDOUT)
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

@Suite(.serialized)
struct HookServerTests {

    private func withTestSocket(test: (String) async throws -> Void) async throws {
        let socketPath = "/tmp/test-hookserver-\(UUID().uuidString).sock"
        setenv("CODEISLAND_SOCKET_PATH", socketPath, 1)
        defer {
            unsetenv("CODEISLAND_SOCKET_PATH")
            unlink(socketPath)
        }
        try await test(socketPath)
    }

    // 1. start() creates the socket file with mode 0600 (stat st_mode & 0o777 == 0o600);
    // stop() removes it; calling start() twice does not throw or create a second listener.
    @Test @MainActor func socketLifecycleAndPermissions() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let server = HookServer(sink: sink)
            #expect(server.isListening == false)

            server.start()
            #expect(server.isListening == true)

            // The socket is bound and chmod'ed asynchronously once the listener is
            // ready, so wait for both the file and the final mode, not just the file.
            var st = stat()
            for _ in 0..<100 {
                if stat(socketPath, &st) == 0, (st.st_mode & 0o777) == 0o600 { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(stat(socketPath, &st) == 0)
            #expect((st.st_mode & 0o777) == 0o600)

            // Calling start() twice does not throw or create a second listener
            server.start()
            #expect(server.isListening == true)

            server.stop()
            #expect(server.isListening == false)
            #expect(stat(socketPath, &st) != 0)

            // Calling stop() twice is idempotent
            server.stop()
            #expect(server.isListening == false)
        }
    }

    // 2. SessionStart payload -> reply is {}, sink recorded handle once with sessionId "s1" and cwd "/tmp/p".
    @Test @MainActor func sessionStartPayload() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let server = HookServer(sink: sink)
            server.start()
            defer { server.stop() }

            let sessionStartData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "SessionStart",
                "session_id": "s1",
                "cwd": "/tmp/p"
            ])
            let reply = try await SocketClient(socketPath: socketPath).send(data: sessionStartData)
            #expect(reply == Data("{}".utf8))

            #expect(sink.records.count == 1)
            #expect(sink.records.first == .handle(eventName: "SessionStart", sessionId: "s1", toolName: nil, cwd: "/tmp/p"))
        }
    }

    // 3. PermissionRequest for Bash -> sink recorded permissionRequested;
    // the client has NOT received a reply yet after 200 ms; test fires the stored reply with .allow -> client receives exactly Decision.allow.replyJSON.
    @Test @MainActor func permissionRequestPendingReply() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let server = HookServer(sink: sink)
            server.start()
            defer { server.stop() }

            let bashData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PermissionRequest",
                "session_id": "s1",
                "tool_name": "Bash",
                "cwd": "/tmp/p"
            ])

            let client = SocketClient(socketPath: socketPath)
            let tracker = ReplyTracker()
            let clientTask = Task {
                let res = try await client.send(data: bashData)
                tracker.markReceived()
                return res
            }

            let start = Date()
            while sink.records.isEmpty && Date().timeIntervalSince(start) < 2.0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(sink.records.count == 1)
            #expect(sink.records.first == .permissionRequested(eventName: "PermissionRequest", sessionId: "s1", toolName: "Bash", cwd: "/tmp/p"))

            // Client has NOT received a reply yet after 200 ms
            try await Task.sleep(nanoseconds: 200_000_000)
            #expect(tracker.received == false)

            #expect(!sink.pendingPermissionReplies.isEmpty)
            sink.pendingPermissionReplies[0](.allow)

            let response = try await clientTask.value
            #expect(tracker.received == true)
            #expect(response == Decision.allow.replyJSON)
        }
    }

    // 4. PermissionRequest for a tool in autoApproveTools -> immediate allow reply, sink recorded handle (not permissionRequested).
    @Test @MainActor func permissionRequestAutoApprove() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let config = HookServerConfig(autoApproveTools: ["Bash"])
            let server = HookServer(sink: sink, config: config)
            server.start()
            defer { server.stop() }

            let bashData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PermissionRequest",
                "session_id": "s1",
                "tool_name": "Bash",
                "cwd": "/tmp/p"
            ])
            let reply = try await SocketClient(socketPath: socketPath).send(data: bashData)
            #expect(reply == Decision.allow.replyJSON)

            #expect(sink.records.count == 1)
            #expect(sink.records.first == .handle(eventName: "PermissionRequest", sessionId: "s1", toolName: "Bash", cwd: "/tmp/p"))
            #expect(sink.pendingPermissionReplies.isEmpty)
        }
    }

    // 5. Excluded cwd substring -> PermissionRequest gets allow, SessionStart gets {}, sink recorded nothing.
    @Test @MainActor func excludedCwdSubstrings() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let config = HookServerConfig(excludedCwdSubstrings: ["/excluded"])
            let server = HookServer(sink: sink, config: config)
            server.start()
            defer { server.stop() }

            let permData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "PermissionRequest",
                "session_id": "s1",
                "tool_name": "Bash",
                "cwd": "/excluded/dir"
            ])
            let permReply = try await SocketClient(socketPath: socketPath).send(data: permData)
            #expect(permReply == Decision.allow.replyJSON)

            let sessionData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "SessionStart",
                "session_id": "s1",
                "cwd": "/excluded/dir"
            ])
            let sessionReply = try await SocketClient(socketPath: socketPath).send(data: sessionData)
            #expect(sessionReply == Data("{}".utf8))

            #expect(sink.records.isEmpty)
        }
    }

    // 6. Notification with question and options -> sink recorded questionAsked with the payload; reply .answer("b") reaches the client as Decision.answer("b").replyJSON.
    @Test @MainActor func notificationQuestionAsked() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let server = HookServer(sink: sink)
            server.start()
            defer { server.stop() }

            let questionData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "Notification",
                "session_id": "s1",
                "question": "Which option?",
                "options": ["a", "b", "c"],
                "cwd": "/tmp/p"
            ])

            let client = SocketClient(socketPath: socketPath)
            let clientTask = Task {
                try await client.send(data: questionData)
            }

            let start = Date()
            while sink.records.isEmpty && Date().timeIntervalSince(start) < 2.0 {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(sink.records.count == 1)
            #expect(sink.records.first == .questionAsked(eventName: "Notification", sessionId: "s1", question: "Which option?", cwd: "/tmp/p"))

            #expect(!sink.pendingQuestionReplies.isEmpty)
            sink.pendingQuestionReplies[0](.answer("b"))

            let response = try await clientTask.value
            #expect(response == Decision.answer("b").replyJSON)
        }
    }

    // 7. SessionEnd -> reply {} and sink recorded handle then peerDisconnected("s1").
    @Test @MainActor func sessionEndHandledThenPeerDisconnected() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let server = HookServer(sink: sink)
            server.start()
            defer { server.stop() }

            let sessionEndData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "SessionEnd",
                "session_id": "s1",
                "cwd": "/tmp/p"
            ])
            let reply = try await SocketClient(socketPath: socketPath).send(data: sessionEndData)
            #expect(reply == Data("{}".utf8))

            #expect(sink.records.count == 2)
            if sink.records.count == 2 {
                #expect(sink.records[0] == .handle(eventName: "SessionEnd", sessionId: "s1", toolName: nil, cwd: "/tmp/p"))
                #expect(sink.records[1] == .peerDisconnected(sessionId: "s1"))
            }
        }
    }

    // 8. Garbage bytes -> reply {} and the server keeps serving the next valid request.
    @Test @MainActor func garbageBytesReturnsEmptyObjectAndContinues() async throws {
        try await withTestSocket { socketPath in
            let sink = RecordingSink()
            let server = HookServer(sink: sink)
            server.start()
            defer { server.stop() }

            let garbage = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22])
            let reply1 = try await SocketClient(socketPath: socketPath).send(data: garbage)
            #expect(reply1 == Data("{}".utf8))

            let validData = try JSONSerialization.data(withJSONObject: [
                "hook_event_name": "SessionStart",
                "session_id": "s2",
                "cwd": "/tmp/p2"
            ])
            let reply2 = try await SocketClient(socketPath: socketPath).send(data: validData)
            #expect(reply2 == Data("{}".utf8))

            #expect(sink.records.count == 1)
            #expect(sink.records.first == .handle(eventName: "SessionStart", sessionId: "s2", toolName: nil, cwd: "/tmp/p2"))
        }
    }
}
