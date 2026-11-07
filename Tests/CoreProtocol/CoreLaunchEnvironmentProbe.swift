import Foundation

#if os(macOS)
private nonisolated struct ProbeStatus: Decodable, Sendable { let core: CoreHello.Identity; let pid: UInt32; let live: Int }
private nonisolated struct ProbeTerminal: Decodable, Sendable {
    let address: String
    let pid: UInt32?
    let restart_env: [String:String]?
}
private nonisolated struct ProbeStopped: Decodable, Sendable { let stopped: Bool }
private nonisolated enum ProbeFailure: Error { case assertion(String) }

/// Synthetic value only: investigates whether standard env would expose a
/// future route capability. No provider, credential or real route is used.
@main @MainActor private struct CoreLaunchEnvironmentProbe {
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeFailure.assertion(message) }
    }
    static func main() async throws {
        guard CommandLine.arguments.count == 5, CommandLine.arguments[4] == "0.1.17" else { throw ProbeFailure.assertion("official 0.1.17 required") }
        let executable = URL(fileURLWithPath:CommandLine.arguments[1]), home = URL(fileURLWithPath:CommandLine.arguments[2]), report = URL(fileURLWithPath:CommandLine.arguments[3])
        for part in ["","state","config","runtime"] { try FileManager.default.createDirectory(at:home.appending(path:part),withIntermediateDirectories:true) }
        let environment = ["PATH":"/usr/bin:/bin","HOME":home.path,"XDG_STATE_HOME":home.appending(path:"state").path,"XDG_CONFIG_HOME":home.appending(path:"config").path,"XDG_RUNTIME_DIR":home.appending(path:"runtime").path,"HC_SESSION":"owned","HC_SOCKET":home.appending(path:"c.sock").path,"SSH_CONNECTION":"owned-fixture-no-launchd","LANG":"en_US.UTF-8","DO_NOT_TRACK":"1"]
        let transport = try CoreProcessTransport(configuration:.init(executable:executable,environment:environment,directory:home))
        let rpc = try CoreRPCConnection(transport:transport,requiredMethods:["terminal.run","terminal.get","terminal.kill","server.status","server.stop"])
        let hello = try await rpc.connect()
        let status: ProbeStatus = try await rpc.call("server.status").result()
        try require(hello.version == "0.1.17" && status.core.id == hello.core.id && status.live == 0 && status.pid > 1,"fresh owned official core required")
        func save(_ extra: [String:Any]) throws {
            var values:[String:Any] = ["corePID":status.pid,"coreID":hello.core.id,"version":hello.version,"ownedPIDs":[status.pid]]
            values.merge(extra) { _,new in new }
            try JSONSerialization.data(withJSONObject:values,options:.sortedKeys).write(to:report,options:.atomic)
        }
        try save([:])
        let key = "SHPHRD_SYNTHETIC_ENV_PROBE", canary = "fixture-only-" + UUID().uuidString
        let parameters = try JSONSerialization.data(withJSONObject:["argv":["/bin/sleep","60"],"cwd":home.path,"no_parent":true,"env":[key:canary]])
        let run: ProbeTerminal = try await rpc.call("terminal.run",parameters:parameters).result()
        try require(CoreTerminalID.isCanonical(run.address),"known canonical receipt required")
        let pids = [status.pid] + (run.pid.map { [$0] } ?? [])
        try save(["ownedPIDs":pids,"terminalID":run.address])
        let getParams = try JSONSerialization.data(withJSONObject:["terminal":run.address])
        let fetched: ProbeTerminal = try await rpc.call("terminal.get",parameters:getParams).result()
        try require(fetched.address == run.address,"exact known terminal GET required")
        let state = home.appending(path:"state/herdr-core/owned/terminals.json")
        let bytes = try Data(contentsOf:state)
        let onDisk = bytes.range(of:Data(canary.utf8)) != nil
        let inRun = run.restart_env?[key] == canary, inGet = fetched.restart_env?[key] == canary
        let _: ProbeTerminal = try await rpc.call("terminal.kill",parameters:getParams).result()
        let stopped: ProbeStopped = try await rpc.call("server.stop").result()
        try require(stopped.stopped,"owned stop acknowledged")
        try await rpc.close()
        let closed = await transport.snapshot()
        try require(closed.closed && closed.reaped,"connect child retired")
        try save(["passed":true,"ownedPIDs":pids,"terminalID":run.address,"stopAcknowledged":true,"connectChildrenReaped":true,"syntheticCanaryOnDisk":onDisk,"syntheticCanaryInRunReply":inRun,"syntheticCanaryInGetReply":inGet,"environmentPersistenceSafe":!onDisk && !inRun && !inGet,"launchCaptureQualified":false,"actualProvider":"NOTRUN","userCredentialsUsed":false])
        print("PROBE complete: synthetic environment persistence inspected; not launch/capture qualification")
    }
}
#endif
