import Foundation
import Darwin

/// `LocalHerdrTransport.subscribe` against a stand-in for herdr.sock: a Unix
/// socket served by this process, scripted per test. Nothing reaches a real
/// herdr. The socket is made in the directory given as the first argument,
/// under a relative path, since an absolute one there would be too long
/// for a Unix socket address.
@main struct LocalSubscribeTests {
    static func check(_ value: Bool, _ name: String) {
        precondition(value, name)
        print("PASS: " + name)
    }

    nonisolated static let acknowledgement = #"{"id":"req_0","result":{"type":"subscription_started"}}"#

    static func main() async throws {
        guard CommandLine.arguments.count > 1, FileManager.default.changeCurrentDirectoryPath(CommandLine.arguments[1]) else {
            fatalError("usage: LocalSubscribeTests <directory for the socket>")
        }
        let server = FakeHerdrSocket(path: "s.sock")
        defer { server.shutDown() }

        try await chunkBoundaries(server)
        try await errorAfterAcknowledgement(server)
        await refusedBeforeAcknowledgement(server)
        await closedBeforeAcknowledgement(server)
        try await cancellingTheReaderClosesTheConnection(server)
        try await closeClosesTheConnection(server)
        try await linesAreTakenOffAsTheyArrive(server)
    }

    static func transport() -> LocalHerdrTransport {
        LocalHerdrTransport(socketPath: "s.sock")
    }

    static func collect(_ subscription: HerdrSubscriptionLines) async -> (lines: [String], error: (any Error)?) {
        var lines: [String] = []
        do {
            for try await line in subscription.lines {
                lines.append(String(decoding: line, as: UTF8.self))
            }
            return (lines, nil)
        } catch {
            return (lines, error)
        }
    }

    /// The acknowledgement split in two, several lines in one piece, a line
    /// split across pieces, and herdr closing the connection at the end.
    static func chunkBoundaries(_ server: FakeHerdrSocket) async throws {
        let served = server.serve { peer in
            let request = peer.readLine() ?? ""
            peer.note(request)
            for piece in [#"{"id":"req_0","res"#,
                          #"ult":{"type":"subscription_started"}}"# + "\n" + #"{"event":"pane_updated","data":{}}"# + "\n" + #"{"event":"pane.agent_status_changed","data":{}}"# + "\n" + #"{"event":"layout_"#,
                          #"updated","data":{}}"# + "\n"] {
                _ = peer.write(piece)
                usleep(30_000)
            }
        }
        let subscription = try await transport().subscribe(params: HerdrChangeSubscription(statusOf: ["w1:p1"]).params)
        let (lines, error) = await collect(subscription)
        await served.wait()
        let request = try JSONDecoder().decode(JSONValue.self, from: Data((served.notes.first ?? "").utf8))
        check(request["method"]?.stringValue == "events.subscribe", "local: events.subscribe sent on a connection of its own")
        check(request["params"]?["subscriptions"]?.arrayValue?.count == 18, "local: the subscription's params as given")
        check(lines.map { HerdrStreamLine(Data($0.utf8)) } == [.change("pane_updated"), .change("pane.agent_status_changed"), .change("layout_updated")],
              "local: lines across piece boundaries, several in one piece")
        check(error == nil, "local: herdr closing the connection ends the lines without an error")
    }

    static func errorAfterAcknowledgement(_ server: FakeHerdrSocket) async throws {
        let served = server.serve { peer in
            _ = peer.readLine()
            _ = peer.write(acknowledgement + "\n" + #"{"event":"tab_renamed","data":{}}"# + "\n")
            usleep(30_000)
            _ = peer.write(#"{"id":"req_0","error":{"code":"events_lost","message":"event subscription fell behind retained history; resubscribe and resync with session.snapshot"}}"# + "\n")
        }
        let subscription = try await transport().subscribe(params: HerdrChangeSubscription(statusOf: []).params)
        let (lines, error) = await collect(subscription)
        await served.wait()
        check(lines.count == 2 && HerdrStreamLine(Data(lines[0].utf8)) == .change("tab_renamed"), "local: an event, then")
        if case .failure(let code, _) = HerdrStreamLine(Data(lines[1].utf8)) {
            check(code == "events_lost" && error == nil, "local: an error line after the acknowledgement, then the end")
        } else {
            check(false, "local: an error line after the acknowledgement, then the end")
        }
    }

    static func refusedBeforeAcknowledgement(_ server: FakeHerdrSocket) async {
        let served = server.serve { peer in
            _ = peer.readLine()
            _ = peer.write(#"{"id":"req_0:sub:17:probe","error":{"code":"pane_not_found","message":"pane w1:p9 not found"}}"# + "\n")
        }
        do {
            _ = try await transport().subscribe(params: HerdrChangeSubscription(statusOf: ["w1:p9"]).params)
            check(false, "local: pane_not_found in place of the acknowledgement is thrown")
        } catch {
            check((error as? HerdrErrorPayload)?.code == "pane_not_found", "local: pane_not_found in place of the acknowledgement is thrown")
        }
        await served.wait()
    }

    static func closedBeforeAcknowledgement(_ server: FakeHerdrSocket) async {
        let served = server.serve { peer in
            _ = peer.readLine()
        }
        do {
            _ = try await transport().subscribe(params: HerdrChangeSubscription(statusOf: []).params)
            check(false, "local: a connection closed before the acknowledgement")
        } catch HerdrSubscriptionError.noAcknowledgement {
            check(true, "local: a connection closed before the acknowledgement")
        } catch {
            check(false, "local: a connection closed before the acknowledgement (\(error))")
        }
        await served.wait()
    }

    /// The reader's task cancelled: herdr sees the connection close, which
    /// is how it learns the subscriber has gone. Also checked while it is
    /// open: the socket isn't inherited by processes started meanwhile.
    static func cancellingTheReaderClosesTheConnection(_ server: FakeHerdrSocket) async throws {
        let served = server.serve { peer in
            _ = peer.readLine()
            _ = peer.write(acknowledgement + "\n" + #"{"event":"pane_created","data":{}}"# + "\n")
            peer.note(peer.waitForEndOfFile(seconds: 3) ? "eof" : "no eof")
        }
        let subscription = try await transport().subscribe(params: HerdrChangeSubscription(statusOf: []).params)
        let clientSockets = openSocketsConnected(to: "s.sock")
        check(clientSockets.count == 1, "local: the subscription holds one connection open")
        check(clientSockets.allSatisfy { fcntl($0, F_GETFD) & FD_CLOEXEC != 0 }, "local: its socket is FD_CLOEXEC")
        let firstLine = Inbox()
        let reader = Task {
            for try await line in subscription.lines {
                firstLine.put(String(decoding: line, as: UTF8.self))
            }
        }
        await waitUntil { firstLine.value != nil }
        check(firstLine.value.map { HerdrStreamLine(Data($0.utf8)) } == .change("pane_created"), "local: the reader gets the event")
        reader.cancel()
        await served.wait()
        check(served.notes == ["eof"], "local: cancelling the reader closes the connection")
        await waitUntil { openSocketsConnected(to: "s.sock").isEmpty }
        check(openSocketsConnected(to: "s.sock").isEmpty, "local: and lets go of its socket")
    }

    static func closeClosesTheConnection(_ server: FakeHerdrSocket) async throws {
        let served = server.serve { peer in
            _ = peer.readLine()
            _ = peer.write(acknowledgement + "\n")
            peer.note(peer.waitForEndOfFile(seconds: 3) ? "eof" : "no eof")
        }
        let subscription = try await transport().subscribe(params: HerdrChangeSubscription(statusOf: []).params)
        subscription.close()
        await served.wait()
        check(served.notes == ["eof"], "local: close() closes the connection")
        let (lines, error) = await collect(subscription)
        check(lines.isEmpty && error == nil, "local: and ends the lines")
    }

    /// herdr drops a subscriber it can't write to for 5 s. Lines are read
    /// off the socket as they come, so a reader that is busy elsewhere —
    /// here, not reading at all for a second — doesn't hold herdr up: 2 MB,
    /// far more than the socket's buffers hold, are all written while
    /// nothing is being read.
    static func linesAreTakenOffAsTheyArrive(_ server: FakeHerdrSocket) async throws {
        let count = 4000
        let padding = String(repeating: "x", count: 480)
        let served = server.serve { peer in
            _ = peer.readLine()
            peer.setSendTimeout(seconds: 3)
            var ok = peer.write(acknowledgement + "\n")
            for index in 0..<count where ok {
                ok = peer.write(#"{"event":"pane_updated","data":{"n":\#(index),"p":"\#(padding)"}}"# + "\n")
            }
            peer.note(ok ? "written" : "write failed")
            peer.note(String(Date().timeIntervalSince1970))
        }
        let subscription = try await transport().subscribe(params: HerdrChangeSubscription(statusOf: []).params)
        try await Task.sleep(for: .seconds(1))
        let readingFrom = Date().timeIntervalSince1970
        var received = 0
        for try await line in subscription.lines {
            if case .change = HerdrStreamLine(line) { received += 1 }
            if received == count { break }
        }
        await served.wait()
        let writtenAt = Double(served.notes.last ?? "") ?? .infinity
        check(served.notes.first == "written" && writtenAt < readingFrom, "local: 2 MB written before the reader read any of it")
        check(received == count, "local: and every line of it read afterwards, in full")
        subscription.close()
    }

    /// The descriptors of this process's sockets whose peer is bound to
    /// `path` — the client ends of connections to the stand-in.
    static func openSocketsConnected(to path: String) -> [Int32] {
        (0..<Int32(getdtablesize())).filter { fd in
            var status = stat()
            guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK else { return false }
            var address = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
            }
            guard result == 0, address.sun_family == sa_family_t(AF_UNIX) else { return false }
            let peer = withUnsafeBytes(of: address.sun_path) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return peer == path
        }
    }

    static func waitUntil(seconds: Double = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

nonisolated final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    var value: String? { lock.withLock { stored } }
    func put(_ text: String) { lock.withLock { if stored == nil { stored = text } } }
}

/// A Unix socket listening at `path`, whose connections are served one at a
/// time by a script on a thread of its own.
nonisolated final class FakeHerdrSocket: @unchecked Sendable {
    let path: String
    private let listener: Int32

    init(path: String) {
        self.path = path
        unlink(path)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(listener >= 0)
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in path.utf8.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(bound == 0 && listen(listener, 8) == 0, "bind/listen \(path)")
    }

    func shutDown() {
        close(listener)
        unlink(path)
    }

    /// Accepts the next connection and runs `script` on it; the connection
    /// is closed when the script returns.
    func serve(_ script: @escaping @Sendable (Peer) -> Void) -> Served {
        let served = Served()
        let listener = listener
        Thread.detachNewThread {
            let fd = accept(listener, nil, nil)
            precondition(fd >= 0)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let peer = Peer(fd: fd, served: served)
            script(peer)
            close(fd)
            served.finish()
        }
        return served
    }
}

nonisolated final class Served: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var recorded: [String] = []

    var notes: [String] { lock.withLock { recorded } }
    var isDone: Bool { lock.withLock { done } }
    func note(_ text: String) { lock.withLock { recorded.append(text) } }
    func finish() { lock.withLock { done = true } }

    func wait(seconds: Double = 10) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !isDone && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        precondition(isDone, "the stand-in's script didn't finish")
    }
}

/// The stand-in's end of one connection, used with blocking calls.
nonisolated final class Peer: @unchecked Sendable {
    let fd: Int32
    private let served: Served
    private var pending: [UInt8] = []

    init(fd: Int32, served: Served) {
        self.fd = fd
        self.served = served
    }

    func note(_ text: String) { served.note(text) }

    func readLine() -> String? {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                pending.removeSubrange(...newline)
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = recv(fd, &chunk, chunk.count, 0)
            guard count > 0 else { return nil }
            pending += chunk[..<count]
        }
    }

    func write(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }

    func setSendTimeout(seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Whether the other end closes the connection within `seconds`.
    func waitForEndOfFile(seconds: Int) -> Bool {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &chunk, chunk.count, 0)
            if count == 0 { return true }
            if count < 0 { return errno == ECONNRESET }
        }
    }
}
