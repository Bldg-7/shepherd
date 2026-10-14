import Foundation

/// Records what the client asks of herdr, and answers with `failure` when
/// one is set. Nothing leaves the process.
actor SeenTransport: HerdrTransport {
    var requests: [(method: String, params: JSONValue)] = []
    var commands: [[String]] = []
    var failure: (any Error)?
    func failing(with error: (any Error)?) { failure = error }
    func connect() async throws {}
    func disconnect() async {}
    func send(method: String, params: JSONValue) async throws -> JSONValue {
        requests.append((method, params))
        if let failure { throw failure }
        return .object(["type": .string("ok")])
    }
    func runHerdr(_ arguments: [String]) async throws -> Data {
        commands.append(arguments)
        if let failure { throw failure }
        return Data("{\"result\":{\"type\":\"ok\"}}".utf8)
    }
    func runScript(_ script: String) async throws -> Data { throw HostScriptError(status: 127, message: "not a script test") }
    func events() -> AsyncStream<JSONValue> { AsyncStream { $0.finish() } }
}

@main struct SeenRequestClientTests {
    static func check(_ value: Bool, _ name: String) { precondition(value, name); print("PASS: " + name) }
    static func pane(on machine: HerdrMachine?) -> AgentSummary {
        AgentSummary(json: .object(["pane_id": .string("w1:p1"), "terminal_id": .string("term-owned"), "tab_id": .string("w1:t1"),
                                    "agent": .string("claude"), "agent_status": .string("done")]), on: machine)!
    }
    static func send(_ request: SeenRequest, with client: HerdrClient) async -> (any Error)? {
        do { try await client.focusTab(request.tabID, on: request.herdrMachine); return nil } catch { return error }
    }

    static func main() async throws {
        let transport = SeenTransport(), client = HerdrClient(transport: transport)
        let host = SeenMarking.request(forPane: pane(on: nil), windowIsKey: true)!
        check(await send(host, with: client) == nil, "host: tab.focus answered")
        var requests = await transport.requests
        check(requests.count == 1 && requests[0].method == "tab.focus", "host: one tab.focus over the socket API")
        if case .object(let params) = requests[0].params {
            check(params.count == 1 && params["tab_id"]?.stringValue == "w1:t1", "host: tab.focus names the tab and nothing else")
        } else {
            check(false, "host: tab.focus params are an object")
        }
        check(await transport.commands.isEmpty, "host: no herdr CLI run")

        let remote = HerdrMachine(id: "owned-remote", label: "Owned", target: "owned-invalid", session: "default", enabled: true)
        let machine = SeenMarking.request(forPane: pane(on: remote), windowIsKey: true)!
        check(await send(machine, with: client) == nil, "herdr machine: tab focus answered")
        check(await transport.commands == [["--machine", "owned-remote", "tab", "focus", "w1:t1"]], "herdr machine: exactly herdr --machine <id> tab focus <tab_id>")
        check(await transport.requests.count == 1, "herdr machine: nothing over the host's socket API")

        await transport.failing(with: HerdrErrorPayload(code: "tab_not_found", message: "tab not found"))
        let refused = await send(host, with: client)
        check((refused as? HerdrErrorPayload)?.code == "tab_not_found", "host: herdr's refusal is thrown as it is")
        requests = await transport.requests
        check(requests.count == 2 && requests[1].method == "tab.focus", "host: a refused tab.focus is sent once, not retried")

        await transport.failing(with: HerdrCommandError(status: 1, message: "error: machine 'owned-remote' (session default): ssh: connect to host owned-invalid: Connection refused"))
        let unreachable = await send(machine, with: client)
        check((unreachable as? HerdrCommandError)?.status == 1, "herdr machine: the CLI's failure is thrown as it is")
        check(await transport.commands.count == 2, "herdr machine: a failed tab focus is run once, not retried")
    }
}
