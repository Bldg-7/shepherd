import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOSSL
import Crypto
@_spi(Testing) import AgentProxyForwarder
import AgentProxyProtocol

// The forwarder in this process, through its test initializer: every upstream
// is a fake TLS server on 127.0.0.1 with a certificate from the test's own
// authority, and every state folder and socket is under the output folder.
// The recorder is the real executable's `recorder`, or this program's
// `tap-recorder` (which writes every frame it gets to a file, for the test to
// read) or `stall-recorder` (which reads nothing).
//
//   ForwarderTests run <output> <hrdrhrdrhrdr-agent-proxy> <zstd fixture>
//   ForwarderTests tap-recorder <file>
//   ForwarderTests stall-recorder

@main
struct ForwarderTests {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3 && arguments[1] == "tap-recorder" { exit(tapRecorder(arguments[2])) }
        if arguments.count == 2 && arguments[1] == "stall-recorder" { while true { sleep(60) } }
        guard arguments.count == 5, arguments[1] == "run" else {
            FileHandle.standardError.write(Data("usage: ForwarderTests run <output> <proxy> <fixture>\n".utf8))
            exit(64)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        signal(SIGPIPE, SIG_IGN)
        do {
            let suite = try Suite(output: arguments[2], proxy: arguments[3], fixture: arguments[4])
            exit(suite.run())
        } catch {
            print("FAIL setup: \(error)")
            exit(1)
        }
    }

    static func tapRecorder(_ path: String) -> Int32 {
        let file = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard file >= 0 else { return 2 }
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(3, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return 0 }
            var written = 0
            while written < count {
                let result = chunk[written..<count].withUnsafeBytes { write(file, $0.baseAddress, $0.count) }
                if result <= 0 { return 3 }
                written += result
            }
        }
    }
}

final class Gate: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func open() { semaphore.signal() }
    func wait(_ seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
}

final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

struct Proxy {
    let server: AgentProxyServer
    let port: Int
    let socket: String
    let state: String
    let logs: Box<[String]>
    let exits: Box<[Int32]>

    func control() throws -> ControlClient { try ControlClient(path: socket) }
}

struct Route {
    let routeID: String
    let token: String
    let baseURL: String
}

enum Recorder {
    case none, real, tap(String), stall
}

let jwt = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJlLXRlc3Q"
let sseHead = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"

func okJSON(_ body: String, extra: [(String, String)] = []) -> String {
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" + extra.map { "\($0.0): \($0.1)\r\n" }.joined()
        + "Content-Length: \(body.utf8.count)\r\n\r\n" + body
}

func request(_ method: String, _ target: String, _ headers: [(String, String)], body: [UInt8] = [], version: String = "HTTP/1.1") -> [UInt8] {
    var head = "\(method) \(target) \(version)\r\n"
    for (name, value) in headers { head += "\(name): \(value)\r\n" }
    if !body.isEmpty && !headers.contains(where: { ["content-length", "transfer-encoding"].contains($0.0.lowercased()) }) {
        head += "Content-Length: \(body.count)\r\n"
    }
    return bytes(head + "\r\n") + body
}

func chunked(_ pieces: [[UInt8]]) -> [UInt8] {
    pieces.flatMap { bytes(String($0.count, radix: 16) + "\r\n") + $0 + bytes("\r\n") } + bytes("0\r\n\r\n")
}

func claudeHeaders(_ port: Int, auth: String = "sk-ant-oat01-test") -> [(String, String)] {
    [("Host", "127.0.0.1:\(port)"), ("Authorization", "Bearer \(auth)"), ("anthropic-beta", "oauth-2025-04-20"),
     ("anthropic-version", "2023-06-01"), ("Content-Type", "application/json")]
}

func codexHeaders(_ port: Int, token: String = jwt) -> [(String, String)] {
    [("Host", "127.0.0.1:\(port)"), ("Authorization", "Bearer \(token)"), ("Content-Type", "application/json"),
     ("Accept", "text/event-stream")]
}

func sha256(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

final class Suite {
    let out: String
    let proxyBinary: String
    let harness: String
    let fixture: [UInt8]
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let ca: TestCA
    let anthropicIdentity: TestIdentity
    let chatgptIdentity: TestIdentity
    var servers: [AgentProxyServer] = []
    var fakes: [FakeUpstream] = []
    var needles: [String] = []
    var current = ""

    init(output: String, proxy: String, fixture: String) throws {
        out = output; proxyBinary = proxy
        harness = Bundle.main.executablePath!
        self.fixture = fileBytes(fixture)
        try check(self.fixture.count > 1000, "zstd fixture")
        ca = try TestCA(name: "agent proxy test root")
        anthropicIdentity = try ca.issue(host: "api.anthropic.com")
        chatgptIdentity = try ca.issue(host: "chatgpt.com")
    }

    func run() -> Int32 {
        let cases: [(String, () throws -> Void)] = [
            ("control-socket", controlSocket),
            ("forward-claude-body-and-headers", forwardClaude),
            ("forward-codex-zstd-chunked", forwardCodex),
            ("head-request", headRequest),
            ("sse-immediacy", sseImmediacy),
            ("client-disconnect-closes-upstream", clientDisconnect),
            ("upstream-disconnect-cuts-response", upstreamDisconnect),
            ("websocket-426", websocket),
            ("rejections", rejections),
            ("oauth-shape", oauthShape),
            ("tls-and-connect-failures", tlsFailures),
            ("pool-reuse-and-idle", pool),
            ("tee-frames", teeFrames),
            ("tee-limit-and-stalled-recorder", teeLimits),
            ("unknown-token-forwarded-without-copy", unknownToken),
            ("recorder-killed-mid-stream", recorderKilled),
            ("restart-when-idle", restartWhenIdle),
            ("non-retention", nonRetention)
        ]
        var results: [[String: Any]] = []
        for (name, test) in cases {
            current = name
            let started = Date()
            var passed = false
            var message = ""
            do {
                try test()
                passed = true
            } catch {
                message = "\(error)"
            }
            cleanUp()
            let seconds = (Date().timeIntervalSince(started) * 1000).rounded() / 1000
            print(passed ? "PASS \(name) (\(seconds)s)" : "FAIL \(name): \(message)")
            results.append(["name": name, "passed": passed, "seconds": seconds])
        }
        try? group.syncShutdownGracefully()
        let failed = results.filter { $0["passed"] as? Bool != true }.count
        let summary: [String: Any] = ["cases": results, "passed": results.count - failed, "failed": failed]
        try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: out + "/results.json"))
        let needleFile = out + "/needles.json"
        FileManager.default.createFile(atPath: needleFile, contents: try? JSONSerialization.data(withJSONObject: needles),
                                       attributes: [.posixPermissions: 0o600])
        print("\(results.count - failed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    func cleanUp() {
        for server in servers { server.shutdown() }
        servers.removeAll()
        for fake in fakes { fake.stop() }
        fakes.removeAll()
    }

    // MARK: Fixtures

    func fake(_ identity: TestIdentity?, _ script: @escaping FakeUpstream.Script) throws -> FakeUpstream {
        let fake = try FakeUpstream(group: group, identity: identity, script: script)
        fakes.append(fake)
        return fake
    }

    func proxy(_ name: String, anthropic: SocketAddress? = nil, chatgpt: SocketAddress? = nil, recorder: Recorder = .none,
               connectTimeout: TimeAmount = .seconds(10), idleTimeout: TimeAmount = .seconds(30)) throws -> Proxy {
        let folder = out + "/c/" + name
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logs = Box<[String]>([])
        let exits = Box<[Int32]>([])
        let command: [String]? = switch recorder {
        case .none: nil
        case .real: [proxyBinary, "recorder"]
        case .tap(let file): [harness, "tap-recorder", file]
        case .stall: [harness, "stall-recorder"]
        }
        let label = current
        let configuration = AgentProxyServer.Configuration(
            stateDirectory: folder + "/state", controlSocketPath: folder + "/ap.sock", recorderCommand: command, build: "test-build",
            log: { line in
                logs.update { $0.append(line) }
                FileHandle.standardError.write(Data("[\(label)] \(line)\n".utf8))
            },
            onExitRequest: { code in exits.update { $0.append(code) } })
        var upstreams: [AgentProxyUpstream: SocketAddress] = [:]
        upstreams[.anthropic] = anthropic
        upstreams[.chatgpt] = chatgpt
        let server = AgentProxyServer(configuration: configuration, testUpstreams: upstreams, trustRoots: [ca.root],
                                      connectTimeout: connectTimeout, idleTimeout: idleTimeout)
        servers.append(server)
        let port = try server.start()
        return Proxy(server: server, port: port, socket: folder + "/ap.sock", state: folder + "/state", logs: logs, exits: exits)
    }

    func route(_ control: ControlClient, _ kind: String, pane: String = "w1:p1") throws -> Route {
        let result = try control.result("routes.create", ["kind": kind, "session": "default", "paneID": pane,
                                                          "terminalID": "term-" + pane, "cliVersion": "9.9.9"])
        guard let baseURL = result["baseURL"] as? String, let routeID = result["routeID"] as? String,
              let token = baseURL.split(separator: "/").last.map(String.init) else { throw TestFailure(description: "routes.create answer") }
        return Route(routeID: routeID, token: token, baseURL: baseURL)
    }

    func send(_ port: Int, _ data: [UInt8], head: Bool = false, timeout: Double = 10) throws -> RawResponse {
        let client = try RawClient(port: port)
        try client.send(data)
        return try client.response(timeout: timeout, head: head)
    }

    func routes(_ control: ControlClient) throws -> [[String: Any]] {
        (try control.result("routes.list")["routes"] as? [[String: Any]]) ?? []
    }

    func frames(_ path: String) throws -> [AgentProxyTeeFrame.Frame] {
        var decoder = AgentProxyTeeFrame.Decoder()
        decoder.append(fileBytes(path))
        var frames: [AgentProxyTeeFrame.Frame] = []
        while let frame = try decoder.next() { frames.append(frame) }
        return frames
    }

    func waitForFrames(_ path: String, ends: Int, timeout: Double = 5) throws -> [AgentProxyTeeFrame.Frame] {
        var found: [AgentProxyTeeFrame.Frame] = []
        _ = waitUntil(timeout) {
            found = (try? frames(path)) ?? []
            return found.filter { $0.kind == .end }.count >= ends
        }
        return found
    }

    // MARK: Cases

    func controlSocket() throws {
        let held = Gate()
        let upstream = try fake(anthropicIdentity) { _, connection in
            connection.send(sseHead)
            connection.sendChunk("event: message_start\ndata: {}\n\n")
            _ = held.wait(10)
            connection.send("0\r\n\r\n")
        }
        let proxy = try self.proxy("ctl", anthropic: upstream.address, recorder: .real)
        try check(mode(proxy.socket) == 0o600, "ap.sock is 0600, not \(String(mode(proxy.socket), radix: 8))")
        try check(mode(proxy.state) == 0o700, "state folder is 0700")
        try check(mode(proxy.state + "/state.json") == 0o600, "state.json is 0600")
        let saved = try JSONSerialization.jsonObject(with: Data(fileBytes(proxy.state + "/state.json"))) as? [String: Any]
        try check(saved?["port"] as? Int == proxy.port && AgentProxyPaths.portRange.contains(proxy.port), "state.json keeps the port")

        let control = try proxy.control()
        let status = try control.result("proxy.status")
        try check(status["protocolVersion"] as? Int == 1 && status["port"] as? Int == proxy.port && status["state"] as? String == "running"
                  && status["routeCount"] as? Int == 0 && status["inFlight"] as? Int == 0 && status["build"] as? String == "test-build",
                  "status fields")
        let recorder = status["recorder"] as? [String: Any]
        try check(recorder?["state"] as? String == "running" && (recorder?["pid"] as? Int ?? 0) > 0, "recorder running")

        // Two requests in one write, answered in order.
        control.sendRaw("{\"id\":\"a\",\"method\":\"proxy.status\"}\n{\"id\":\"b\",\"method\":\"routes.list\",\"params\":{}}\n")
        let first = try control.readLine(), second = try control.readLine()
        try check(first["id"] as? String == "a" && second["id"] as? String == "b" && second["result"] != nil, "two lines, two answers")
        control.sendRaw("not json\n")
        try check((try control.readLine()["error"] as? [String: Any])?["code"] as? String == "parse_error", "parse_error")
        try check((try control.call("proxy.nope")["error"] as? [String: Any])?["code"] as? String == "unknown_method", "unknown_method")
        let badKind = try control.call("routes.create", ["kind": "vim", "session": "", "paneID": "", "terminalID": "", "cliVersion": ""])
        try check((badKind["error"] as? [String: Any])?["code"] as? String == "invalid_params", "unknown kind is invalid_params")
        try check((try control.call("routes.create", ["kind": "claude"])["error"] as? [String: Any])?["code"] as? String == "invalid_params",
                  "missing fields are invalid_params")
        let longField = String(repeating: "x", count: 300)
        try check((try control.call("routes.create", ["kind": "claude", "session": longField, "paneID": "p", "terminalID": "t", "cliVersion": "1"])["error"]
                   as? [String: Any])?["code"] as? String == "invalid_params", "long field is invalid_params")

        let claude = try route(control, "claude")
        let codex = try route(control, "codex", pane: "w1:p2")
        try check(claude.baseURL == "http://127.0.0.1:\(proxy.port)/p/\(claude.token)", "baseURL shape")
        try check(claude.token.count == 32 && claude.token.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "token is 32 lowercase hex")
        let listed = try routes(control)
        try check(listed.count == 2, "two routes listed")
        let listedClaude = listed.first { $0["routeID"] as? String == claude.routeID }
        try check(listedClaude?["kind"] as? String == "claude" && listedClaude?["paneID"] as? String == "w1:p1"
                  && listedClaude?["terminalID"] as? String == "term-w1:p1" && listedClaude?["session"] as? String == "default"
                  && listedClaude?["cliVersion"] as? String == "9.9.9" && listedClaude?["oauthRejected"] as? Bool == false
                  && listedClaude?["inFlight"] as? Int == 0 && (listedClaude?["createdAt"] as? String)?.hasSuffix("Z") == true,
                  "route fields")
        try check(Set(listedClaude?.keys.map { $0 } ?? []) == ["routeID", "kind", "session", "paneID", "terminalID", "cliVersion", "createdAt", "oauthRejected", "inFlight"],
                  "a listed route has no token or hash")
        try check(try control.result("proxy.status")["routeCount"] as? Int == 2, "routeCount 2")

        // In flight while a response is held open.
        let client = try RawClient(port: proxy.port)
        try client.send(request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(proxy.port), body: bytes("{}")))
        try check(client.waitFor("message_start"), "stream started")
        try check(try control.result("proxy.status")["inFlight"] as? Int == 1, "inFlight 1 while streaming")
        try check(try routes(control).first { $0["routeID"] as? String == claude.routeID }?["inFlight"] as? Int == 1, "route inFlight 1")
        held.open()
        try check(client.waitFor("0\r\n\r\n"), "stream ended")
        try check(waitUntil(2) { (try? control.result("proxy.status")["inFlight"] as? Int) == 0 }, "inFlight back to 0")
        try check(try control.result("proxy.status")["counters"].flatMap { ($0 as? [String: Any])?["exchanges"] as? Int } == 1, "one exchange counted")

        try check(try control.result("routes.remove", ["routeID": codex.routeID])["removed"] as? Bool == true, "removed")
        try check(try control.result("routes.remove", ["routeID": codex.routeID])["removed"] as? Bool == false, "removed once only")
        try check(try control.result("proxy.status")["routeCount"] as? Int == 1, "routeCount 1")

        let stored = fileBytes(proxy.state + "/routes.json")
        try check(mode(proxy.state + "/routes.json") == 0o600, "routes.json is 0600")
        try check(contains(stored, bytes(sha256(claude.token))) && !contains(stored, bytes(sha256(codex.token))), "routes.json has the remaining route's hash")
        try check(!contains(stored, bytes(claude.token)) && !contains(stored, bytes(codex.token)), "routes.json has no token")

        // A line longer than the limit closes the connection.
        let long = try ControlClient(path: proxy.socket)
        long.sendRaw(String(repeating: "x", count: AgentProxyControl.maximumLineBytes + 10))
        try check((try? long.readLine()) == nil, "an over-long line closes the connection")
        try check(try control.result("proxy.status")["state"] as? String == "running", "still answering")
    }

    func forwardClaude() throws {
        var body = [UInt8]()
        var generator = SystemRandomNumberGenerator()
        for index in 0..<300_000 { body.append(index < 256 ? UInt8(index) : UInt8.random(in: 0...255, using: &generator)) }
        let responseBody = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let responseHead = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nrequest-id: req_123\r\nX-Resp-Case: Value\r\n"
            + "Connection: keep-alive\r\nKeep-Alive: timeout=60\r\nanthropic-ratelimit-unified-status: allowed\r\nContent-Length: \(responseBody.count)\r\n\r\n"
        let upstream = try fake(anthropicIdentity) { request, connection in
            if request.requestLine.hasPrefix("GET") { connection.send(okJSON("{\"data\":[]}")) }
            else { connection.send(bytes(responseHead) + responseBody) }
        }
        let proxy = try self.proxy("claude", anthropic: upstream.address)
        let control = try proxy.control()
        let claude = try route(control, "claude")
        let headers: [(String, String)] = [
            ("Host", "127.0.0.1:\(proxy.port)"), ("Authorization", "Bearer sk-ant-oat01-abc"),
            ("anthropic-beta", "oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"), ("anthropic-version", "2023-06-01"),
            ("X-Mixed-Case", "KeepMe"), ("Connection", "keep-alive, X-Hop-Custom"), ("X-Hop-Custom", "drop-me"),
            ("Keep-Alive", "timeout=5"), ("Proxy-Connection", "keep-alive"), ("TE", "trailers"), ("Trailer", "X-Trailer"),
            ("Proxy-Authorization", "Basic Zm9vOmJhcg=="), ("x-3rdr-pi-session", "s1"), ("X-3RDR-Other", "y"),
            ("x-claude-code-session-id", "sess-1"), ("User-Agent", "claude-cli/2.1.306 (external, cli)"),
            ("Content-Type", "application/json"), ("dup-header", "a"), ("dup-header", "b"), ("Content-Length", String(body.count))
        ]
        let client = try RawClient(port: proxy.port)
        try client.send(request("POST", "/p/\(claude.token)/v1/messages?beta=true", headers, body: body))
        let response = try client.response()
        try check(waitUntil(2) { upstream.requests.count == 1 }, "upstream got the request")
        let received = upstream.requests[0]
        try check(received.requestLine == "POST /v1/messages?beta=true HTTP/1.1", "request line without the token prefix")
        let expected: [(String, String)] = [
            ("Host", "api.anthropic.com"), ("Authorization", "Bearer sk-ant-oat01-abc"),
            ("anthropic-beta", "oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"), ("anthropic-version", "2023-06-01"),
            ("X-Mixed-Case", "KeepMe"), ("x-claude-code-session-id", "sess-1"), ("User-Agent", "claude-cli/2.1.306 (external, cli)"),
            ("Content-Type", "application/json"), ("dup-header", "a"), ("dup-header", "b"), ("Content-Length", String(body.count))
        ]
        try check(received.headers.map { $0.0 + ": " + $0.1 } == expected.map { $0.0 + ": " + $0.1 },
                  "upstream headers: hop-by-hop and x-3rdr-* gone, Host replaced in place, nothing added, case and order kept; got \(received.headers.map(\.0))")
        try check(received.body == body, "request body byte for byte")
        try check(response.status == 200 && response.body == responseBody && response.complete, "response body byte for byte")
        let expectedResponse: [(String, String)] = [
            ("Content-Type", "application/octet-stream"), ("request-id", "req_123"), ("X-Resp-Case", "Value"),
            ("anthropic-ratelimit-unified-status", "allowed"), ("Content-Length", String(responseBody.count))
        ]
        try check(response.headers.map { $0.0 + ": " + $0.1 } == expectedResponse.map { $0.0 + ": " + $0.1 },
                  "response headers kept less hop-by-hop; got \(response.headers.map(\.0))")

        // The same agent connection again, a request whose sign-in isn't
        // looked at (not a model request), over the same upstream connection.
        try client.send(request("GET", "/p/\(claude.token)/v1/models", [("Host", "127.0.0.1:\(proxy.port)"), ("x-api-key", "sk-ant-api-xyz")]))
        let second = try client.response()
        try check(second.status == 200 && second.body == bytes("{\"data\":[]}"), "second request on the same connection")
        try check(upstream.requests.count == 2 && upstream.requests[1].requestLine == "GET /v1/models HTTP/1.1", "second request forwarded")
        try check(upstream.requests[1].headers.map { $0.0 + ": " + $0.1 } == ["Host: api.anthropic.com", "x-api-key: sk-ant-api-xyz"], "GET headers")
        try check(upstream.accepted == 1 && upstream.handshakes == 1, "one upstream connection, reused")
    }

    func forwardCodex() throws {
        let events = ["event: response.created\ndata: {\"type\":\"response.created\"}\n\n",
                      "event: response.output_text.delta\ndata: {\"delta\":\"Hi\"}\n\n",
                      "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n"]
        let upstream = try fake(chatgptIdentity) { _, connection in
            connection.send(sseHead)
            for event in events { connection.sendChunk(event) }
            connection.send("0\r\n\r\n")
        }
        let proxy = try self.proxy("codex", chatgpt: upstream.address)
        let codex = try route(try proxy.control(), "codex")
        let headers: [(String, String)] = [
            ("Host", "127.0.0.1:\(proxy.port)"), ("Authorization", "Bearer \(jwt)"), ("ChatGPT-Account-ID", "acct-1"),
            ("session_id", "sess-codex"), ("x-openai-subagent", "review"), ("originator", "codex_cli_rs"),
            ("Content-Type", "application/json"), ("Content-Encoding", "zstd"), ("Accept", "text/event-stream"),
            ("Transfer-Encoding", "chunked")
        ]
        let pieces = [Array(fixture[0..<1]), Array(fixture[1..<8]), Array(fixture[8..<4104]), Array(fixture[4104...])]
        let response = try send(proxy.port, request("POST", "/p/\(codex.token)/backend-api/codex/responses", headers) + chunked(pieces))
        try check(waitUntil(2) { upstream.requests.count == 1 }, "upstream got the request")
        let received = upstream.requests[0]
        try check(received.requestLine == "POST /backend-api/codex/responses HTTP/1.1", "request line")
        try check(received.chunked && received.body == fixture, "zstd body byte for byte, still chunked")
        var expected = headers
        expected[0] = ("Host", "chatgpt.com")
        try check(received.headers.map { $0.0 + ": " + $0.1 } == expected.map { $0.0 + ": " + $0.1 }, "codex headers kept")
        try check(response.status == 200 && response.complete && response.body == bytes(events.joined()), "SSE body complete")
        try check(response.header("content-type") == ["text/event-stream"] && response.header("transfer-encoding") == ["chunked"], "SSE headers")
    }

    func headRequest() throws {
        let upstream = try fake(anthropicIdentity) { request, connection in
            if request.requestLine.hasPrefix("HEAD") {
                connection.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 1234\r\n\r\n")
            } else {
                connection.send(okJSON("{\"ok\":true}"))
            }
        }
        let proxy = try self.proxy("head", anthropic: upstream.address)
        let claude = try route(try proxy.control(), "claude")
        let client = try RawClient(port: proxy.port)
        try client.send(request("HEAD", "/p/\(claude.token)/v1/models", [("Host", "127.0.0.1:\(proxy.port)")]))
        let head = try client.response(head: true)
        try check(head.status == 200 && head.header("content-length") == ["1234"], "HEAD answered with its length and no body")
        try client.send(request("GET", "/p/\(claude.token)/v1/models", [("Host", "127.0.0.1:\(proxy.port)")]))
        let next = try client.response()
        try check(next.status == 200 && next.body == bytes("{\"ok\":true}"), "the connection is still in step after HEAD")
        try check(upstream.accepted == 1, "one upstream connection")
    }

    func sseImmediacy() throws {
        let gates = (0..<3).map { _ in Gate() }
        let stalled = Box(false)
        let events = ["event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
                      "event: ping\ndata: {\"type\": \"ping\"}\n\n",
                      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hi\"}}\n\n"]
        let upstream = try fake(anthropicIdentity) { _, connection in
            connection.send(sseHead)
            for (index, event) in events.enumerated() {
                connection.sendChunk(event)
                // The next event goes only once the agent has this one.
                if !gates[index].wait(5) { stalled.value = true; connection.close(); return }
            }
            connection.send("0\r\n\r\n")
        }
        let proxy = try self.proxy("sse", anthropic: upstream.address)
        let claude = try route(try proxy.control(), "claude")
        let client = try RawClient(port: proxy.port)
        try client.send(request("POST", "/p/\(claude.token)/v1/messages?beta=true", claudeHeaders(proxy.port), body: bytes("{\"stream\":true}")))
        for (index, marker) in ["message_start", "\"ping\"", "content_block_delta"].enumerated() {
            try check(client.waitFor(marker, timeout: 4), "event \(index + 1) reached the agent before the next was sent")
            gates[index].open()
        }
        try check(client.waitFor("0\r\n\r\n", timeout: 4), "the stream's end")
        try check(!stalled.value, "the upstream never waited in vain")
    }

    func clientDisconnect() throws {
        let upstream = try fake(anthropicIdentity) { _, connection in
            connection.send(sseHead)
            connection.sendChunk("event: message_start\ndata: {}\n\n")
            _ = waitUntil(10) { connection.closedAt != nil }
        }
        let proxy = try self.proxy("client-gone", anthropic: upstream.address)
        let control = try proxy.control()
        let claude = try route(control, "claude")
        let client = try RawClient(port: proxy.port)
        try client.send(request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(proxy.port), body: bytes("{}")))
        try check(client.waitFor("message_start"), "stream started")
        let closedByAgent = Date()
        client.shutdown()
        try check(waitUntil(1.0) { upstream.connections.first?.closedAt != nil }, "upstream connection closed within a second")
        let elapsed = upstream.connections[0].closedAt!.timeIntervalSince(closedByAgent)
        try check(elapsed <= 1.0, "closed after \(elapsed)s")
        try check(waitUntil(2) { (try? control.result("proxy.status")["inFlight"] as? Int) == 0 }, "nothing left in flight")
    }

    func upstreamDisconnect() throws {
        let upstream = try fake(anthropicIdentity) { request, connection in
            if request.requestLine.contains("count_tokens") {
                connection.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n0123456789")
            } else {
                connection.send(sseHead)
                connection.sendChunk("event: message_start\ndata: {}\n\n")
            }
            usleep(100_000)
            connection.close()
        }
        let proxy = try self.proxy("upstream-gone", anthropic: upstream.address)
        let control = try proxy.control()
        let claude = try route(control, "claude")
        let client = try RawClient(port: proxy.port)
        try client.send(request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(proxy.port), body: bytes("{}")))
        let cut = try client.response(timeout: 5)
        try check(cut.status == 200 && !cut.complete && contains(cut.body, bytes("message_start")), "chunked response cut off without its last chunk")
        try check(client.waitForEOF(timeout: 2) && !contains(client.pending, bytes("0\r\n\r\n")), "connection closed, no terminator")

        let short = try RawClient(port: proxy.port)
        try short.send(request("POST", "/p/\(claude.token)/v1/messages/count_tokens", claudeHeaders(proxy.port), body: bytes("{}")))
        let partial = try short.response(timeout: 5)
        try check(partial.status == 200 && !partial.complete && partial.body == bytes("0123456789"), "Content-Length response cut short")
        let counters = try control.result("proxy.status")["counters"] as? [String: Any]
        try check((counters?["upstreamFailures"] as? Int ?? 0) >= 2, "upstream failures counted")
    }

    func websocket() throws {
        let upstream = try fake(chatgptIdentity) { _, connection in connection.send(okJSON("{}")) }
        let proxy = try self.proxy("ws", chatgpt: upstream.address)
        let codex = try route(try proxy.control(), "codex")
        let response = try send(proxy.port, request("GET", "/p/\(codex.token)/backend-api/codex/responses",
                                                    codexHeaders(proxy.port) + [("Connection", "Upgrade"), ("Upgrade", "websocket"),
                                                                                ("Sec-WebSocket-Version", "13"),
                                                                                ("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")]))
        try check(response.status == 426, "426, not \(response.status)")
        usleep(200_000)
        try check(upstream.accepted == 0, "no upstream connection")
    }

    func rejections() throws {
        let anthropic = try fake(anthropicIdentity) { _, connection in connection.send(okJSON("{}")) }
        let chatgpt = try fake(chatgptIdentity) { _, connection in connection.send(okJSON("{}")) }
        let proxy = try self.proxy("reject", anthropic: anthropic.address, chatgpt: chatgpt.address)
        let control = try proxy.control()
        let claude = try route(control, "claude"), codex = try route(control, "codex")
        let port = proxy.port
        let valid = claudeHeaders(port)
        let path = "/p/\(claude.token)/v1/messages"
        func swapHost(_ value: String?) -> [(String, String)] {
            var headers = valid.filter { $0.0 != "Host" }
            if let value { headers.insert(("Host", value), at: 0) }
            return headers
        }
        let cases: [(String, [UInt8], Int)] = [
            ("Host localhost", request("POST", path, swapHost("localhost:\(port)"), body: bytes("{}")), 403),
            ("Host without port", request("POST", path, swapHost("127.0.0.1"), body: bytes("{}")), 403),
            ("Host other port", request("POST", path, swapHost("127.0.0.1:\(port + 1)"), body: bytes("{}")), 403),
            ("two Hosts", request("POST", path, valid + [("Host", "127.0.0.1:\(port)")], body: bytes("{}")), 403),
            ("no Host", request("POST", path, swapHost(nil), body: bytes("{}")), 403),
            ("Origin", request("POST", path, valid + [("Origin", "http://example.invalid")], body: bytes("{}")), 403),
            ("Sec-Fetch-Site", request("POST", path, valid + [("Sec-Fetch-Site", "cross-site")], body: bytes("{}")), 403),
            ("Sec-Fetch-Mode", request("GET", "/p/\(claude.token)/api/hello", [valid[0], ("Sec-Fetch-Mode", "no-cors")]), 403),
            ("PUT", request("PUT", path, valid, body: bytes("{}")), 405),
            ("DELETE", request("DELETE", path, valid), 405),
            ("OPTIONS", request("OPTIONS", path, valid), 405),
            ("PATCH", request("PATCH", path, valid, body: bytes("{}")), 405),
            ("no /p/", request("POST", "/v1/messages", valid, body: bytes("{}")), 404),
            ("token only", request("GET", "/p/\(claude.token)", valid), 404),
            ("short token", request("POST", "/p/abc123/v1/messages", valid, body: bytes("{}")), 404),
            ("uppercase token", request("POST", "/p/\(claude.token.uppercased())/v1/messages", valid, body: bytes("{}")), 404),
            ("other API version", request("POST", "/p/\(claude.token)/v2/messages", valid, body: bytes("{}")), 404),
            ("other api path", request("GET", "/p/\(claude.token)/api/oauth/profile", valid), 404),
            ("bare /v1/", request("GET", "/p/\(claude.token)/v1/", valid), 404),
            ("dot segments", request("GET", "/p/\(claude.token)/v1/../api/hello", valid), 404),
            ("encoded dots", request("GET", "/p/\(claude.token)/v1/%2e%2e/api/hello", valid), 404),
            ("empty segment", request("POST", "/p/\(claude.token)//v1/messages", valid, body: bytes("{}")), 404),
            ("claude route to chatgpt", request("POST", "/p/\(claude.token)/backend-api/codex/responses", codexHeaders(port), body: bytes("{}")), 404),
            ("codex route to anthropic", request("POST", "/p/\(codex.token)/v1/messages", valid, body: bytes("{}")), 404),
            ("absolute form", request("POST", "http://api.anthropic.com/v1/messages", valid, body: bytes("{}")), 404),
            ("HTTP/1.0", request("POST", path, valid, body: bytes("{}"), version: "HTTP/1.0"), 505),
            ("Transfer-Encoding gzip", request("POST", path, valid + [("Transfer-Encoding", "gzip")], body: bytes("{}")), 400)
        ]
        for (name, data, status) in cases {
            let response = try send(port, data, timeout: 5)
            try check(response.status == status, "\(name): \(status) expected, got \(response.status)")
        }
        usleep(200_000)
        try check(anthropic.accepted == 0 && chatgpt.accepted == 0, "no upstream connection for any of them")
        let rejected = (try control.result("proxy.status")["counters"] as? [String: Any])?["rejected"] as? Int
        try check(rejected == cases.count, "every one counted as rejected")
    }

    func oauthShape() throws {
        let anthropic = try fake(anthropicIdentity) { _, connection in connection.send(okJSON("{\"ok\":1}")) }
        let chatgpt = try fake(chatgptIdentity) { _, connection in connection.send(okJSON("{\"ok\":1}")) }
        let proxy = try self.proxy("oauth", anthropic: anthropic.address, chatgpt: chatgpt.address)
        let control = try proxy.control()
        let claude = try route(control, "claude"), codex = try route(control, "codex", pane: "w1:p2")
        let pi = try route(control, "pi", pane: "w1:p3"), clean = try route(control, "claude", pane: "w1:p4")
        let port = proxy.port
        let anthropicCases: [(String, Route, String, [(String, String)])] = [
            ("x-api-key beside OAuth", claude, "/v1/messages", claudeHeaders(port) + [("x-api-key", "sk-ant-api03-k")]),
            ("no oauth- capability", claude, "/v1/messages?beta=true",
             claudeHeaders(port).map { $0.0 == "anthropic-beta" ? ($0.0, "fine-grained-tool-streaming-2025-05-14") : $0 }),
            ("API key only", claude, "/v1/messages", [("Host", "127.0.0.1:\(port)"), ("x-api-key", "sk-ant-api03-k"),
                                                     ("anthropic-version", "2023-06-01")]),
            ("count_tokens with API key", claude, "/v1/messages/count_tokens", [("Host", "127.0.0.1:\(port)"), ("x-api-key", "k")]),
            ("Pi with an API key", pi, "/v1/messages", [("Host", "127.0.0.1:\(port)"), ("x-api-key", "sk-ant-api03-k")])
        ]
        for (name, route, path, headers) in anthropicCases {
            let response = try send(port, request("POST", "/p/\(route.token)\(path)", headers, body: bytes("{}")))
            let object = try JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any]
            let error = object?["error"] as? [String: Any]
            try check(response.status == 403 && response.header("content-type") == ["application/json"]
                      && object?["type"] as? String == "error" && error?["type"] as? String == "permission_error"
                      && (error?["message"] as? String)?.contains("new tab") == true, "\(name): Anthropic-format 403")
        }
        for (name, authorization) in [("API key bearer", "Bearer sk-proj-abcdef"), ("Basic", "Basic Zm9vOmJhcg=="),
                                      ("two-part token", "Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0")] {
            let headers = codexHeaders(port).map { $0.0 == "Authorization" ? ($0.0, authorization) : $0 }
            let response = try send(port, request("POST", "/p/\(codex.token)/backend-api/codex/responses", headers, body: bytes("{}")))
            let error = (try JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any])?["error"] as? [String: Any]
            try check(response.status == 403 && error?["type"] as? String == "permission_error" && error?["message"] is String
                      && error?.keys.contains("code") == true, "\(name): OpenAI-format 403")
        }
        usleep(200_000)
        try check(anthropic.accepted == 0 && chatgpt.accepted == 0, "no upstream connection for any of them")
        let listed = try routes(control)
        func rejected(_ route: Route) -> Bool? { listed.first { $0["routeID"] as? String == route.routeID }?["oauthRejected"] as? Bool }
        try check(rejected(claude) == true && rejected(codex) == true && rejected(pi) == true && rejected(clean) == false, "routes marked")
        let stored = fileBytes(proxy.state + "/routes.json")
        try check(contains(stored, bytes("\"oauthRejected\":true")), "the mark is kept in routes.json")

        // Not model requests, and a subscription request: forwarded.
        let hello = try send(port, request("GET", "/p/\(claude.token)/api/hello", [("Host", "127.0.0.1:\(port)")]))
        try check(hello.status == 200, "/api/hello forwarded without a sign-in check")
        let fine = try send(port, request("POST", "/p/\(clean.token)/v1/messages", claudeHeaders(port), body: bytes("{}")))
        try check(fine.status == 200 && anthropic.requests.count == 2, "a subscription request goes through")
        let codexFine = try send(port, request("POST", "/p/\(codex.token)/backend-api/codex/responses", codexHeaders(port), body: bytes("{}")))
        try check(codexFine.status == 200 && chatgpt.requests.count == 1, "a ChatGPT sign-in goes through")
        let piCodex = try send(port, request("POST", "/p/\(pi.token)/backend-api/codex/responses", codexHeaders(port), body: bytes("{}")))
        try check(piCodex.status == 200 && chatgpt.requests.count == 2, "a Pi route may use chatgpt.com")
    }

    func tlsFailures() throws {
        let stranger = try TestCA(name: "not trusted")
        let untrusted = try fake(try stranger.issue(host: "api.anthropic.com")) { _, connection in connection.send(okJSON("{}")) }
        let wrongHost = try fake(try ca.issue(host: "wrong.example")) { _, connection in connection.send(okJSON("{}")) }
        let silent = try fake(nil) { _, _ in }
        let closedPort: Int = {
            let probe = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_port = 0; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) } }
            close(probe)
            return Int(UInt16(bigEndian: address.sin_port))
        }()
        let attempts: [(String, SocketAddress, FakeUpstream?, Double)] = [
            ("untrusted certificate", untrusted.address, untrusted, 5),
            ("certificate for another host", wrongHost.address, wrongHost, 5),
            ("connection refused", try SocketAddress(ipAddress: "127.0.0.1", port: closedPort), nil, 3),
            ("no TLS answer", silent.address, nil, 3)
        ]
        for (index, (name, address, upstream, limit)) in attempts.enumerated() {
            let proxy = try self.proxy("tls\(index)", anthropic: address, connectTimeout: .seconds(1))
            let claude = try route(try proxy.control(), "claude")
            let started = Date()
            let response = try send(proxy.port, request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(proxy.port), body: bytes("{\"x\":1}")))
            let elapsed = Date().timeIntervalSince(started)
            let error = (try? JSONSerialization.jsonObject(with: Data(response.body)) as? [String: Any])?["error"] as? [String: Any]
            try check(response.status == 502 && error?["type"] as? String == "api_error", "\(name): 502, got \(response.status)")
            try check(elapsed < limit, "\(name): answered in \(elapsed)s")
            if let upstream {
                try check(upstream.accepted >= 1 && upstream.receivedBytes == 0 && upstream.requests.isEmpty,
                          "\(name): the connection was made but nothing was sent over it")
            }
        }
        try check(silent.accepted >= 1, "the silent server was reached")
    }

    func pool() throws {
        let upstream = try fake(anthropicIdentity) { request, connection in
            if request.requestLine.contains("close-me") {
                connection.send(okJSON("{}", extra: [("Connection", "close")]))
                usleep(50_000)
                connection.close()
            } else {
                connection.send(okJSON("{}"))
            }
        }
        let proxy = try self.proxy("pool", anthropic: upstream.address, idleTimeout: .seconds(1))
        let claude = try route(try proxy.control(), "claude")
        let post = { (path: String) in request("POST", "/p/\(claude.token)\(path)", claudeHeaders(proxy.port), body: bytes("{}")) }
        try check(try send(proxy.port, post("/v1/messages")).status == 200, "first")
        try check(try send(proxy.port, post("/v1/messages")).status == 200, "second, from another agent connection")
        try check(upstream.accepted == 1, "the idle upstream connection was reused")
        try check(waitUntil(2.5) { upstream.connections.first?.closedAt != nil }, "an idle connection is closed after the idle time")
        try check(try send(proxy.port, post("/v1/messages")).status == 200, "third")
        try check(upstream.accepted == 2, "a new connection after the idle one closed")
        try check(try send(proxy.port, post("/v1/messages/close-me")).status == 200, "an answer that closes")
        try check(try send(proxy.port, post("/v1/messages")).status == 200, "after it")
        try check(upstream.accepted == 3, "a connection the upstream closes is not reused")
    }

    func teeFrames() throws {
        let tap = out + "/c/tee.tap"
        let events = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n"
        let upstream = try fake(anthropicIdentity) { _, connection in
            connection.send(sseHead)
            connection.sendChunk(events)
            connection.send("0\r\n\r\n")
        }
        let proxy = try self.proxy("tee", anthropic: upstream.address, recorder: .tap(tap))
        let claude = try route(try proxy.control(), "claude")
        let body = bytes("{\"model\":\"claude\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}],\"stream\":true}")
        let headers = claudeHeaders(proxy.port) + [("x-claude-code-session-id", "sess-tee"), ("X-Claude-Code-Agent-Id", "agent-1"),
                                                   ("Cookie", "c=1"), ("ChatGPT-Account-ID", "a"), ("x-3rdr-pi-class", "main"),
                                                   ("session_id", "s"), ("User-Agent", "claude-cli"),
                                                   ("x-claude-code-request-class", "main"), ("thread-id", "native-thread"),
                                                   ("session-id", "cache-affinity"), ("x-codex-parent-thread-id", "parent-thread")]
        try check(waitUntil(3) { (try? proxy.control().result("proxy.status")["recorder"] as? [String: Any])?["state"] as? String == "running" }, "recorder up")
        let response = try send(proxy.port, request("POST", "/p/\(claude.token)/v1/messages?beta=true", headers, body: body))
        try check(response.status == 200 && response.complete, "exchange")
        let frames = try waitForFrames(tap, ends: 1)
        try check(frames.map(\.kind) == [.open, .requestBody, .requestEnd, .responseHead, .responseBody, .end],
                  "frame kinds in order: \(frames.map(\.kind.rawValue))")
        try check(Set(frames.map(\.exchange)).count == 1, "one exchange number")
        let open = try JSONDecoder().decode(AgentProxyTeeFrame.Open.self, from: Data(frames[0].payload))
        try check(open.routeID == claude.routeID && open.upstream == "anthropic" && open.method == "POST" && open.path == "/v1/messages",
                  "open: route, upstream, method, path without token or query")
        try check(open.routeIdentity == AgentProxyRouteCreate(kind: .claude, session: "default", paneID: "w1:p1",
                                                             terminalID: "term-w1:p1", cliVersion: "9.9.9"),
                  "open carries only explicit route identity needed by the recorder")
        var encodedOpen = try JSONSerialization.jsonObject(with: Data(frames[0].payload)) as! [String: Any]
        let identity = encodedOpen["routeIdentity"] as? [String: Any]
        try check(Set(identity?.keys.map { $0 } ?? []) == ["kind", "session", "paneID", "terminalID", "cliVersion"],
                  "route identity has no token, tokenHash or base URL fields")
        encodedOpen.removeValue(forKey: "routeIdentity")
        let legacy = try JSONDecoder().decode(AgentProxyTeeFrame.Open.self, from: JSONSerialization.data(withJSONObject: encodedOpen))
        try check(legacy.routeIdentity == nil && legacy.routeID == open.routeID, "legacy frame does not fabricate route identity")
        for name in ["x-claude-code-signature", "x-claude-code-tunnel-credential-epoch", "x-claude-code-future-token", "x-3rdr-pi-secret", "x-codex-turn-metadata"] {
            try check(!AgentProxyTeeFrame.allowedRequestHeader(name), "unreviewed/sensitive header not copied: \(name)")
        }
        try check(open.headers == [["content-type", "application/json"], ["x-claude-code-session-id", "sess-tee"],
                                   ["x-claude-code-agent-id", "agent-1"], ["x-3rdr-pi-class", "main"], ["session_id", "s"],
                                   ["x-claude-code-request-class", "main"], ["thread-id", "native-thread"],
                                   ["session-id", "cache-affinity"], ["x-codex-parent-thread-id", "parent-thread"]],
                  "open: only the classifying headers, got \(open.headers.map { $0.first ?? "" })")
        try check(frames[1].payload == body && frames[2].payload.isEmpty, "request body copied")
        let head = try JSONDecoder().decode(AgentProxyTeeFrame.ResponseHead.self, from: Data(frames[3].payload))
        try check(head.status == 200 && head.headers == [["content-type", "text/event-stream"]], "response head")
        try check(frames[4].payload == bytes(events), "response body copied")
        let end = try JSONDecoder().decode(AgentProxyTeeFrame.End.self, from: Data(frames[5].payload))
        try check(end.outcome == .complete, "end complete")
    }

    func teeLimits() throws {
        let big = 65 << 20
        let block = [UInt8](repeating: 0x61, count: 1 << 20)
        let tap = out + "/c/limit.tap"
        let upstream = try fake(anthropicIdentity) { request, connection in
            let size = request.requestLine.contains("models") ? big : request.requestLine.contains("small") ? 1 << 16 : 16 << 20
            connection.send("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: \(size)\r\n\r\n")
            if size < block.count { connection.send(Array(block[0..<size])); return }
            for index in 0..<(size >> 20) {
                connection.send(block)
                // Paced so the tap keeps up and only the limit cuts the
                // copy, not a full socket.
                if size == big && index < 63 { _ = waitUntil(10) { fileBytesCount(tap) >= (index + 1) << 20 } }
            }
        }
        // Over the limit: the response goes through whole, the copy stops.
        let proxy = try self.proxy("limit", anthropic: upstream.address, recorder: .tap(tap))
        let claude = try route(try proxy.control(), "claude")
        try check(waitUntil(3) { (try? proxy.control().result("proxy.status")["recorder"] as? [String: Any])?["state"] as? String == "running" }, "recorder up")
        let response = try send(proxy.port, request("GET", "/p/\(claude.token)/v1/models", [("Host", "127.0.0.1:\(proxy.port)")]), timeout: 60)
        try check(response.status == 200 && response.complete && response.body.count == big, "the whole 65 MiB response reached the agent")
        let frames = try waitForFrames(tap, ends: 1, timeout: 20)
        let copied = frames.filter { $0.kind == .responseBody }.reduce(0) { $0 + $1.payload.count }
        let end = try frames.last.map { try JSONDecoder().decode(AgentProxyTeeFrame.End.self, from: Data($0.payload)) }
        try check(frames.last?.kind == .end && end?.outcome == .dropped && copied <= AgentProxyTeeFrame.exchangeLimitBytes
                  && copied > AgentProxyTeeFrame.exchangeLimitBytes - (1 << 20), "copy cut at the limit (\(copied) bytes) and ended as dropped")
        let small = try send(proxy.port, request("POST", "/p/\(claude.token)/v1/messages?small", claudeHeaders(proxy.port), body: bytes("{}")), timeout: 30)
        try check(small.status == 200 && small.body.count == 1 << 16, "next exchange")
        let after = try waitForFrames(tap, ends: 2, timeout: 20)
        let lastEnd = try after.last.map { try JSONDecoder().decode(AgentProxyTeeFrame.End.self, from: Data($0.payload)) }
        try check(lastEnd?.outcome == .complete, "the next exchange is copied whole")

        // A recorder that reads nothing: forwarding never waits for it.
        let stalled = try self.proxy("stall", anthropic: upstream.address, recorder: .stall)
        let stalledRoute = try route(try stalled.control(), "claude")
        try check(waitUntil(3) { (try? stalled.control().result("proxy.status")["recorder"] as? [String: Any])?["state"] as? String == "running" }, "recorder up")
        let started = Date()
        let through = try send(stalled.port, request("POST", "/p/\(stalledRoute.token)/v1/messages", claudeHeaders(stalled.port), body: bytes("{}")), timeout: 30)
        try check(through.status == 200 && through.complete && through.body.count == 16 << 20, "16 MiB through with the recorder stuck")
        try check(Date().timeIntervalSince(started) < 20, "not held up")
        let counters = try stalled.control().result("proxy.status")["counters"] as? [String: Any]
        try check((counters?["recorderDropped"] as? Int ?? 0) >= 1, "the exchange's copy was dropped")
    }

    func unknownToken() throws {
        let tap = out + "/c/unknown.tap"
        let upstream = try fake(anthropicIdentity) { _, connection in connection.send(okJSON("{\"ok\":1}")) }
        let proxy = try self.proxy("unknown", anthropic: upstream.address, recorder: .tap(tap))
        let control = try proxy.control()
        let claude = try route(control, "claude")
        try check(waitUntil(3) { (try? control.result("proxy.status")["recorder"] as? [String: Any])?["state"] as? String == "running" }, "recorder up")
        let unknown = String(repeating: "0123456789abcdef", count: 2)
        let forwarded = try send(proxy.port, request("POST", "/p/\(unknown)/v1/messages", claudeHeaders(proxy.port), body: bytes("{}")))
        try check(forwarded.status == 200 && upstream.requests.count == 1, "an unknown token's request is forwarded")
        let codexPath = try send(proxy.port, request("POST", "/p/\(unknown)/backend-api/codex/responses", codexHeaders(proxy.port), body: bytes("{}")))
        try check(codexPath.status == 502, "an unknown token may use either upstream (none here for chatgpt: 502)")
        let known = try send(proxy.port, request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(proxy.port), body: bytes("{}")))
        try check(known.status == 200, "known route")
        let frames = try waitForFrames(tap, ends: 1)
        let opens = try frames.filter { $0.kind == .open }.map { try JSONDecoder().decode(AgentProxyTeeFrame.Open.self, from: Data($0.payload)) }
        try check(opens.count == 1 && opens[0].routeID == claude.routeID, "only the known route's exchange was copied")
        try check(!contains(fileBytes(tap), bytes(unknown)), "the unknown token is nowhere in the copy")
    }

    func recorderKilled() throws {
        let gate = Gate()
        let upstream = try fake(anthropicIdentity) { request, connection in
            connection.send(sseHead)
            connection.sendChunk("event: message_start\ndata: {}\n\n")
            if request.requestLine.contains("beta=hold") { _ = gate.wait(10) }
            for index in 0..<5 { connection.sendChunk("event: content_block_delta\ndata: {\"i\":\(index)}\n\n") }
            connection.send("0\r\n\r\n")
        }
        let proxy = try self.proxy("kill", anthropic: upstream.address, recorder: .real)
        let control = try proxy.control()
        let claude = try route(control, "claude")
        func recorderStatus() -> [String: Any]? { (try? control.result("proxy.status"))?["recorder"] as? [String: Any] }
        try check(waitUntil(3) { recorderStatus()?["state"] as? String == "running" }, "recorder up")
        let first = recorderStatus()?["pid"] as? Int ?? 0
        try check(first > 0, "recorder pid")
        let client = try RawClient(port: proxy.port)
        try client.send(request("POST", "/p/\(claude.token)/v1/messages?beta=hold", claudeHeaders(proxy.port), body: bytes("{}")))
        try check(client.waitFor("message_start"), "stream started")
        try check(kill(pid_t(first), SIGKILL) == 0, "recorder killed")
        try check(waitUntil(5) {
            let status = recorderStatus()
            return status?["state"] as? String == "running" && (status?["pid"] as? Int ?? first) != first && (status?["restarts"] as? Int ?? 0) >= 1
        }, "a new recorder was started")
        gate.open()
        try check(client.waitFor("0\r\n\r\n"), "the stream went on to its end")
        try check(contains(client.pending, bytes("{\"i\":4}")), "every event arrived")
        let next = try send(proxy.port, request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(proxy.port), body: bytes("{}")))
        try check(next.status == 200 && next.complete, "the next exchange too")
        try check(kill(pid_t(first), 0) != 0, "the killed recorder was reaped")
    }

    func restartWhenIdle() throws {
        let gate = Gate()
        let upstream = try fake(anthropicIdentity) { _, connection in
            connection.send(sseHead)
            connection.sendChunk("event: message_start\ndata: {}\n\n")
            _ = gate.wait(10)
            connection.send("0\r\n\r\n")
        }
        let proxy = try self.proxy("restart", anthropic: upstream.address)
        let control = try proxy.control()
        let claude = try route(control, "claude")
        let client = try RawClient(port: proxy.port)
        try client.send(request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(proxy.port), body: bytes("{}")))
        try check(client.waitFor("message_start"), "stream started")
        let answer = try control.result("proxy.restartWhenIdle")
        try check(answer["accepted"] as? Bool == true && answer["inFlight"] as? Int == 1, "accepted with one in flight")
        try check(try control.result("proxy.status")["state"] as? String == "draining", "draining")
        usleep(400_000)
        try check(proxy.exits.value.isEmpty, "no exit while a request is in flight")
        // Still forwarding while draining.
        gate.open()
        try check(client.waitFor("0\r\n\r\n"), "the stream ended")
        try check(waitUntil(1) { proxy.exits.value == [0] }, "exit asked for once idle")

        let idle = try self.proxy("restart-idle")
        let idleControl = try idle.control()
        try check(try idleControl.result("proxy.restartWhenIdle")["inFlight"] as? Int == 0, "nothing in flight")
        try check(waitUntil(1) { idle.exits.value == [0] }, "exit asked for at once")
    }

    func nonRetention() throws {
        func marker(_ name: String) -> String {
            var generator = SystemRandomNumberGenerator()
            return "MARK" + name + String(UInt64.random(in: 0...UInt64.max, using: &generator), radix: 36)
        }
        let authorization = marker("auth"), apiKey = marker("key"), cookie = marker("cookie"), account = marker("acct"), jwtMark = marker("jwt")
        let prefixSecret = marker("sensitive-prefix"), metadataSecret = marker("unfiltered-metadata")
        let tap = out + "/c/secrets.tap"
        let anthropic = try fake(anthropicIdentity) { request, connection in
            if request.requestLine.hasPrefix("GET") { connection.send(okJSON("{}")); return }
            connection.send(sseHead)
            connection.sendChunk("event: message_start\ndata: {}\n\n")
            connection.send("0\r\n\r\n")
        }
        let chatgpt = try fake(chatgptIdentity) { _, connection in
            connection.send(sseHead)
            connection.sendChunk("event: response.completed\ndata: {}\n\n")
            connection.send("0\r\n\r\n")
        }
        let proxy = try self.proxy("secrets", anthropic: anthropic.address, chatgpt: chatgpt.address, recorder: .tap(tap))
        let control = try proxy.control()
        try check(waitUntil(3) { (try? control.result("proxy.status")["recorder"] as? [String: Any])?["state"] as? String == "running" }, "recorder up")
        let claude = try route(control, "claude"), codex = try route(control, "codex", pane: "w1:p2")
        let createAnswers = control.answers.count
        needles = [authorization, apiKey, cookie, account, jwtMark, prefixSecret, metadataSecret, claude.token, codex.token]
        let port = proxy.port

        let claudeSecret = claudeHeaders(port, auth: "sk-ant-oat01-" + authorization) + [
            ("Cookie", "session=" + cookie), ("x-claude-code-session-id", "sess"),
            ("x-claude-code-signature", prefixSecret), ("x-claude-code-tunnel-credential-epoch", prefixSecret),
            ("x-claude-code-future-token", prefixSecret), ("x-3rdr-pi-secret", prefixSecret)]
        try check(try send(port, request("POST", "/p/\(claude.token)/v1/messages?beta=true", claudeSecret, body: bytes("{\"stream\":true}"))).status == 200, "claude")
        try check(try send(port, request("GET", "/p/\(claude.token)/v1/models", [("Host", "127.0.0.1:\(port)"), ("x-api-key", apiKey), ("Cookie", cookie)])).status == 200, "models")
        try check(try send(port, request("POST", "/p/\(claude.token)/v1/messages", claudeHeaders(port) + [("x-api-key", apiKey)], body: bytes("{}"))).status == 403, "API key turned away")
        let codexSecret = codexHeaders(port, token: "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0." + jwtMark) + [
            ("ChatGPT-Account-ID", account), ("Cookie", cookie), ("session_id", "s"),
            ("x-codex-turn-metadata", "{\"request_kind\":\"turn\",\"extra\":\"\(metadataSecret)\"}")]
        try check(try send(port, request("POST", "/p/\(codex.token)/backend-api/codex/responses", codexSecret, body: bytes("{}"))).status == 200, "codex")
        let wrongHost = claudeSecret.map { $0.0 == "Host" ? ($0.0, "localhost:\(port)") : $0 } + [("x-api-key", apiKey), ("ChatGPT-Account-ID", account)]
        try check(try send(port, request("POST", "/p/\(claude.token)/v1/messages", wrongHost, body: bytes("{}"))).status == 403, "wrong Host")
        try check(waitUntil(5) { ((try? frames(tap)) ?? []).filter { $0.kind == .end }.count >= 3 }, "three exchanges copied")
        // The upstreams did get them: they are forwarded, not kept.
        try check(anthropic.requests.contains { $0.header("authorization").first?.contains(authorization) == true }, "forwarded upstream")
        try check(anthropic.requests.contains { $0.header("x-claude-code-signature") == [prefixSecret] }, "capture filtering does not strip provider headers upstream")
        try check(chatgpt.requests.contains { $0.header("x-codex-turn-metadata").first?.contains(metadataSecret) == true }, "raw Codex metadata still reaches provider, not recorder")
        _ = try control.result("routes.list")
        _ = try control.result("proxy.status")

        var places: [(String, [UInt8])] = []
        for file in listFiles(proxy.state) { places.append((file, fileBytes(file))) }
        places.append(("tap", fileBytes(tap)))
        places.append(("forwarder log", bytes(proxy.logs.value.joined(separator: "\n"))))
        for (index, answer) in control.answers.enumerated() where !(index >= createAnswers - 2 && index < createAnswers) {
            places.append(("ap.sock answer \(index)", answer))
        }
        for (place, data) in places {
            for needle in needles { try check(!contains(data, bytes(needle)), "a secret found in \(place)") }
        }
        let stored = fileBytes(proxy.state + "/routes.json")
        try check(contains(stored, bytes(sha256(claude.token))) && contains(stored, bytes(sha256(codex.token))), "routes.json keeps the hashes")
        try check(fileBytes(tap).count > 0 && listFiles(proxy.state).count == 2, "state folder has state.json and routes.json only")
    }
}
