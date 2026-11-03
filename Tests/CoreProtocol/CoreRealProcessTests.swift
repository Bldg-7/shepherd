import Foundation

#if os(macOS)
nonisolated struct OwnedCoreStatus: Decodable, Sendable {
    let core: CoreHello.Identity
    let version: String
    let pid: UInt32
    let live: Int
}
nonisolated struct OwnedCoreList: Decodable, Sendable { let terminals: [String]; let hidden_finished: Int }
nonisolated struct OwnedDocumentValue: Decodable, Sendable { let text: String; let sequence: UInt64 }
nonisolated struct OwnedDocument: Decodable, Sendable { let version: UInt64; let value: OwnedDocumentValue? }
nonisolated struct OwnedDocumentVersion: Decodable, Sendable { let version: UInt64 }
nonisolated struct OwnedStop: Decodable, Sendable { let stopped: Bool }
nonisolated enum RealCoreFailure: Error { case assertion(String) }

@main @MainActor
private struct CoreRealProcessTests {
    static func require(_ value: Bool, _ name: String) throws {
        guard value else { throw RealCoreFailure.assertion(name) }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 5, ["0.1.16", "0.1.17"].contains(CommandLine.arguments[4]) else {
            throw RealCoreFailure.assertion("missing pinned core version")
        }
        let expectedVersion = CommandLine.arguments[4]
        let executable = URL(fileURLWithPath: CommandLine.arguments[1])
        let home = URL(fileURLWithPath: CommandLine.arguments[2])
        let report = URL(fileURLWithPath: CommandLine.arguments[3])
        for part in ["", "state", "config", "runtime"] {
            try FileManager.default.createDirectory(at: home.appending(path: part), withIntermediateDirectories: true)
        }
        let env = ["PATH": "/usr/bin:/bin", "HOME": home.path, "XDG_STATE_HOME": home.appending(path: "state").path,
                   "XDG_CONFIG_HOME": home.appending(path: "config").path, "XDG_RUNTIME_DIR": home.appending(path: "runtime").path,
                   "SSH_CONNECTION": "owned-fixture-no-launchd", // Avoid machine-wide launchd; not a lifecycle test.
                   "HC_SESSION": "owned", "HC_SOCKET": home.appending(path: "c.sock").path, "LANG": "en_US.UTF-8", "DO_NOT_TRACK": "1"]
        let configuration = CoreProcessTransport.Configuration(executable: executable, environment: env, directory: home)
        let transport = try CoreProcessTransport(configuration: configuration)
        let connection = try CoreRPCConnection(transport: transport, requiredMethods: ["terminal.list", "server.status", "doc.get", "doc.set", "server.stop"])
        let hello = try await connection.connect()
        try require(hello.version == expectedVersion, "unexpected core version")
        let status: OwnedCoreStatus = try await connection.call("server.status").result()
        try require(status.core.id == hello.core.id && status.live == 0 && status.pid > 1, "core must be fresh and empty")
        // Record only owned identity for cleanup on a later assertion failure.
        try JSONSerialization.data(withJSONObject: ["corePID": status.pid, "coreID": hello.core.id, "version": hello.version])
            .write(to: report, options: .atomic)
        let initial: OwnedDocument = try await connection.call("doc.get", parameters: Data("{\"name\":\"3rdr-connection-test\"}".utf8)).result()
        try require(initial.version == 0 && initial.value == nil, "test document was not fresh")
        let set = Data("{\"name\":\"3rdr-connection-test\",\"version\":0,\"value\":{\"text\":\"fixture-only\",\"sequence\":9007199254740993}}".utf8)
        let written: OwnedDocumentVersion = try await connection.call("doc.set", parameters: set).result()
        try require(written.version == 1, "initial CAS version")
        async let listReply = connection.call("terminal.list")
        async let documentReply = connection.call("doc.get", parameters: Data("{\"name\":\"3rdr-connection-test\"}".utf8))
        let pair = try await (listReply, documentReply)
        let list: OwnedCoreList = try pair.0.result()
        let document: OwnedDocument = try pair.1.result()
        try require(list.terminals.isEmpty, "unexpected terminals")
        try require(document.version == 1 && document.value?.text == "fixture-only" && document.value?.sequence == 9_007_199_254_740_993, "typed UInt64 document round trip")
        let conflict = try await connection.call("doc.set", parameters: set)
        try require(conflict.error?.kind == "conflict", "CAS conflict was not preserved")
        try await connection.close()
        let first = await transport.snapshot()
        try require(first.closed && first.reaped, "first connect child cleanup")
        // Closing the viewer/connection must not stop its core or lose data.
        let secondTransport = try CoreProcessTransport(configuration: configuration)
        let second = try CoreRPCConnection(transport: secondTransport)
        let secondHello = try await second.connect()
        let after: OwnedCoreStatus = try await second.call("server.status").result()
        try require(second.epoch != connection.epoch && secondHello.core.id == hello.core.id && after.pid == status.pid, "new connection must not restart core")
        let persisted: OwnedDocument = try await second.call("doc.get", parameters: Data("{\"name\":\"3rdr-connection-test\"}".utf8)).result()
        try require(persisted.version == 1 && persisted.value?.sequence == document.value?.sequence, "document lost across detach")
        // This is only the explicitly isolated core above, never the user's.
        let stopped: OwnedStop = try await second.call("server.stop").result()
        try require(stopped.stopped, "owned core stop not acknowledged")
        try await second.close()
        let final = await secondTransport.snapshot()
        try require(final.closed && final.reaped, "second connect child cleanup")
        try JSONSerialization.data(withJSONObject: ["passed": true, "corePID": status.pid, "coreID": hello.core.id,
                                                    "version": hello.version, "stopAcknowledged": true, "connectChildrenReaped": true])
            .write(to: report, options: .atomic)
        print("PASS real herdr-core \(expectedVersion): hello/status/list/CAS/UInt64/reconnect/stop; isolated state only")
    }
}
#endif
