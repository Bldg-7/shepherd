import Foundation
import Darwin
import NIOCore
import NIOPosix

@MainActor private final class Counter { var value = 0 }

@main @MainActor struct PiBridgeIntegrationTests {
    static func main() async throws {
        let node = CommandLine.arguments[1], fixture = CommandLine.arguments[2], resources = CommandLine.arguments[3]
        let root = URL(fileURLWithPath: "/private/tmp/shp-pi-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try PiProcessIdentity.capture(pid: -1); preconditionFailure("invalid PID accepted") }
        catch PiBridgeFailure.identity {}
        // Own the only possible CDP destination. MCP initialization/tool discovery
        // must not contact it, and never has a route to production/network sites.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let browserConnections = Counter()
        let browser = try await ServerBootstrap(group: group).childChannelInitializer { channel in
            Task { @MainActor in browserConnections.value += 1 }
            return channel.close()
        }.bind(host: "127.0.0.1", port: 0).get()
        let port = browser.localAddress!.port!
        var acquisitions = 0, revocations = 0, nativeCloses = 0
        let host = PiHostBridge(admit: { launch, proof in
            launch.owner.machineID == "owned-machine" && launch.owner.terminalID == "owned-terminal" && proof.cwd == PiProcessIdentity.canonical(launch.cwd)
        }, acquire: { launch, identity, attempt in
            acquisitions += 1
            let dir = URL(fileURLWithPath: launch.bootstrap).deletingLastPathComponent()
            let descriptor = dir.appendingPathComponent(attempt + ".json")
            let content: [String:Any] = ["piBridge":["bootstrap":launch.bootstrap,"attemptID":attempt],
                "browserDescriptor":dir.appendingPathComponent("browser.json").path]
            try write(content, descriptor)
            var valid = true
            return PiBridgeNativeLease(descriptor: descriptor.path, revoke: {
                if valid { revocations += 1; valid = false }
                return true
            }, close: { nativeCloses += 1 }, isQuiescent: { true })
        })
        let listener = PiBridgeListener(), socket = root.appendingPathComponent("ctl.sock").path
        try await listener.start(path: socket, host: host)
        for mode in ["normal", "shadow", "exec"] {
            let dir = root.appendingPathComponent(mode)
            let sessions = dir.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            let output = dir.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
            let id = UUID().uuidString.lowercased(), sessionID = UUID().uuidString.lowercased()
            let bootstrap = dir.appendingPathComponent("bootstrap.json"), config = dir.appendingPathComponent("config.json")
            let go = dir.appendingPathComponent("go"), result = dir.appendingPathComponent("result.json")
            let token = dir.appendingPathComponent("fake-cdp-token")
            precondition(FileManager.default.createFile(atPath: token.path, contents: Data(Data(repeating:65,count:32).base64EncodedString().utf8), attributes: [.posixPermissions:0o600]))
            try write(["pane":["machineID":"owned-machine","session":"default","paneID":"w1:p1","terminalID":"owned-terminal"],
                "endpoint":["origin":"thisMac","url":"ws://127.0.0.1:\(port)/v1/herdr/default/pane/w1:p1","tokenFile":token.path],
                "outputFolder":output.path,"outputMaxSize":1048576,"allowedOrigins":[],"blockedOrigins":[]], dir.appendingPathComponent("browser.json"))
            let identity: [String:Any] = ["pid":0,"cwd":dir.path,"sessionID":sessionID,
                "sessionFile":sessions.appendingPathComponent("fixture_"+sessionID+".jsonl").path,"leafID":"branch-one"]
            try write(["bootstrap":bootstrap.path,"resources":resources,"go":go.path,"result":result.path,"cwd":dir.path,
                       "home":dir.path,"identity":identity,"sessions":sessions.path,"mode":mode],config)
            let launch = PiBridgeLaunch(id:id,owner:.init(machineID:"owned-machine",herdrMachineID:nil,session:"default",paneID:"w1:p1",terminalID:"owned-terminal"),
                node:node,entry:fixture,arguments:[config.path],cwd:dir.path,sessionID:sessionID,sessionDirectory:sessions.path,
                helper:resources+"/pi-control.mjs",wrapper:resources+"/pi-mcp-run.mjs",bootstrap:bootstrap.path,permitsPiTitleRewrite:mode == "exec")
            try host.provision(launch,socketPath:socket)
            let process = Process(); process.executableURL=URL(fileURLWithPath:node); process.arguments=[fixture,config.path]
            process.currentDirectoryURL=dir
            process.environment=["HOME":dir.path,"PATH":URL(fileURLWithPath:node).deletingLastPathComponent().path+":/usr/bin:/bin","LANG":"en_US.UTF-8"]
            let log = dir.appendingPathComponent("client.log")
            precondition(FileManager.default.createFile(atPath:log.path,contents:Data(),attributes:[.posixPermissions:0o600]))
            let handle=try FileHandle(forWritingTo:log);process.standardOutput=handle;process.standardError=handle
            try process.run()
            // Parent owns this exact newly-created process. Never inspect another
            // app/window or infer ownership from a process name.
            try host.bindProcess(launchID:id,pid:process.processIdentifier)
            let proof=try PiProcessIdentity.capture(pid:process.processIdentifier)
            precondition(proof.isCurrent() && proof.matches(node:node,entry:fixture,tail:[config.path],cwd:dir.path))
            precondition(!proof.matches(node:node,entry:fixture,tail:["wrong"],cwd:dir.path))
            precondition(FileManager.default.createFile(atPath:go.path,contents:Data(),attributes:[.posixPermissions:0o600]))
            let deadline=ContinuousClock().now.advanced(by:.seconds(35))
            while process.isRunning && ContinuousClock().now<deadline { try await Task.sleep(for:.milliseconds(25)) }
            guard !process.isRunning else { preconditionFailure("owned Node fixture deadline; retained log at \(log.path)") }
            try handle.close()
            guard process.terminationStatus==0 else {
                let text=try String(contentsOf:log,encoding:.utf8);print(text);preconditionFailure("owned Node fixture failed")
            }
            let summary=try JSONSerialization.jsonObject(with:Data(contentsOf:result)) as! [String:Any]
            precondition(summary["passed"] as? Bool == true)
            precondition(!proof.isCurrent(), "exited root cannot remain authorized")
            host.retire(launchID:id)
        }
        if CommandLine.arguments.count > 4 {
            try await actualPi(node: node, entry: CommandLine.arguments[4], resources: resources, root: root,
                               socket: socket, port: port, host: host)
        }
        let stopped=await listener.stop(host:host)
        precondition(stopped && !host.hasWork && !FileManager.default.fileExists(atPath:socket))
        let expected = CommandLine.arguments.count > 4 ? 4 : 3
        precondition(acquisitions==expected && revocations==expected && nativeCloses==expected)
        precondition(browserConnections.value==0, "MCP discovery must not touch the browser")
        try await browser.close().get()
        try await group.shutdownGracefully()
        print("PASS actual Unix peer PID, canonical node/entry/argv/cwd/start binding, unauthorized child denial, synchronous helper revoke, real pinned MCP initialize/tools, branch rebind, changed-session denial, shadowing failure, MCP exit acknowledgement; CEF/vendor NOTRUN (Pi TUI is a separate optional gate)")
    }
    static func actualPi(node: String, entry: String, resources: String, root: URL, socket: String, port: Int, host: PiHostBridge) async throws {
        let dir=root.appendingPathComponent("actual-pi")
        let sessions=dir.appendingPathComponent("sessions"), output=dir.appendingPathComponent("output")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for folder in [sessions,output] { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]) }
        let id=UUID().uuidString.lowercased(), sessionID=UUID().uuidString.lowercased()
        let bootstrap=dir.appendingPathComponent("bootstrap.json"), config=dir.appendingPathComponent("driver.json")
        let pidFile=dir.appendingPathComponent("pid.json"), stopFile=dir.appendingPathComponent("stop"), result=dir.appendingPathComponent("result.json")
        let token=dir.appendingPathComponent("fake-token")
        precondition(FileManager.default.createFile(atPath:token.path,contents:Data(Data(repeating:65,count:32).base64EncodedString().utf8),attributes:[.posixPermissions:0o600]))
        try write(["pane":["machineID":"owned-machine","session":"default","paneID":"w1:p1","terminalID":"owned-terminal"],
            "endpoint":["origin":"thisMac","url":"ws://127.0.0.1:\(port)/v1/herdr/default/pane/w1:p1","tokenFile":token.path],
            "outputFolder":output.path,"outputMaxSize":1048576,"allowedOrigins":[],"blockedOrigins":[]],dir.appendingPathComponent("browser.json"))
        let observer=URL(fileURLWithPath:CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent("PiBridgeObserver.ts").path
        let arguments=["--offline","--tui-mode","regular","--no-extensions","--extension","builtin:mcp", "--extension","builtin:codemode",
                       "--extension",resources+"/pi-entry.ts","--extension",observer,"--session-dir",sessions.path,"--session-id",sessionID,"--provider","openai","--model","gpt-4.1"]
        let manifest=dir.appendingPathComponent("launch.json")
        try write(["version":1,"cli":entry,"bootstrap":bootstrap.path,"cwd":dir.path,"arguments":arguments],manifest)
        let bootEntry=resources+"/pi-launch.mjs", bootArguments=[manifest.path]+arguments
        let launch=PiBridgeLaunch(id:id,owner:.init(machineID:"owned-machine",herdrMachineID:nil,session:"default",paneID:"w1:p1",terminalID:"owned-terminal"),
            node:node,entry:bootEntry,arguments:bootArguments,cwd:dir.path,sessionID:sessionID,sessionDirectory:sessions.path,
            helper:resources+"/pi-control.mjs",wrapper:resources+"/pi-mcp-run.mjs",bootstrap:bootstrap.path,permitsPiTitleRewrite:true)
        try host.provision(launch,socketPath:socket)
        try write(["node":node,"entry":bootEntry,"arguments":bootArguments,"cwd":dir.path,"home":dir.path,"sessions":sessions.path,
                   "bootstrap":bootstrap.path,"pidFile":pidFile.path,"stopFile":stopFile.path,"result":result.path,"log":dir.appendingPathComponent("tui.log").path],config)
        let driver=Process();driver.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        let source=URL(fileURLWithPath:CommandLine.arguments[2]).deletingLastPathComponent().appendingPathComponent("OwnedPiBridgePTY.py")
        driver.arguments=[source.path,config.path]
        let driverLog=dir.appendingPathComponent("driver.log")
        precondition(FileManager.default.createFile(atPath:driverLog.path,contents:Data(),attributes:[.posixPermissions:0o600]))
        let log=try FileHandle(forWritingTo:driverLog);driver.standardOutput=log;driver.standardError=log
        let beforeBoot=host.requestCount
        try driver.run()
        let deadline=ContinuousClock().now.advanced(by:.seconds(35))
        while !FileManager.default.fileExists(atPath:pidFile.path) && driver.isRunning && ContinuousClock().now<deadline { try await Task.sleep(for:.milliseconds(25)) }
        let pidJSON=try JSONSerialization.jsonObject(with:Data(contentsOf:pidFile)) as! [String:Any]
        let pid=(pidJSON["pid"] as! NSNumber).int32Value
        while host.requestCount == beforeBoot && driver.isRunning && ContinuousClock().now<deadline { try await Task.sleep(for:.milliseconds(25)) }
        precondition(host.lastFailure == .notBound, "startup must wait before importing Pi")
        let proof=try PiProcessIdentity.capture(pid:pid)
        precondition(proof.parentPID==driver.processIdentifier)
        precondition(proof.matches(node:node,entry:bootEntry,tail:bootArguments,cwd:dir.path))
        try host.bindProcess(launchID:id,pid:pid)
        func extensionReady() -> Bool {
            guard let text=try? String(contentsOf:dir.appendingPathComponent("trace.jsonl"),encoding:.utf8) else { return false }
            return text.split(separator:"\n").contains { line in
                guard let data=String(line).data(using:.utf8), let object=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
                      let value=object["value"] as? [String:Any], value["state"] as? String == "ready",
                      let tools=object["tools"] as? [String] else { return false }
                return tools.contains("mcp__shepherd_browser__browser_snapshot")
            }
        }
        while !(host.isMcpReady(launchID:id) && extensionReady()) && driver.isRunning && ContinuousClock().now<deadline { try await Task.sleep(for:.milliseconds(50)) }
        let ready=host.isMcpReady(launchID:id) && extensionReady()
        if !ready {
            if let current=try? PiProcessIdentity.capture(pid:pid) {
                print("Owned Pi proof comparison: pid/start/executable/cwd/argv: \(current.pid == proof.pid), \(current.startSeconds == proof.startSeconds && current.startMicroseconds == proof.startMicroseconds), \(current.executable == proof.executable), \(current.cwd == proof.cwd), \(current.arguments == proof.arguments)")
                print("Owned fixture argv after startup: \(current.arguments)")
            }
            fflush(stdout)
        }
        // Empty editor only: no prompt is ever sent. This exact verified Pi owns
        // the private PTY whose driver consumes the stop marker.
        precondition(FileManager.default.createFile(atPath:stopFile.path,contents:Data(),attributes:[.posixPermissions:0o600]))
        let exitDeadline=ContinuousClock().now.advanced(by:.seconds(15))
        while driver.isRunning && ContinuousClock().now<exitDeadline { try await Task.sleep(for:.milliseconds(25)) }
        try log.close()
        if !ready || driver.isRunning || driver.terminationStatus != 0 {
            if let text=try? String(contentsOf:dir.appendingPathComponent("tui.log"),encoding:.utf8) { print(String(text.suffix(12000))) }
            if let text=try? String(contentsOf:dir.appendingPathComponent("trace.jsonl"),encoding:.utf8) { print(text) }
            print("Native bridge requests: \(host.requestCount); last code: \(host.lastFailure?.rawValue ?? "none")")
            fflush(stdout)
            preconditionFailure("actual owned Pi bridge failed; root \(dir.path)")
        }
        let summary=try JSONSerialization.jsonObject(with:Data(contentsOf:result)) as! [String:Any]
        precondition(summary["forced"] as? Bool == false && summary["ctrlDSent"] as? Bool == true)
        precondition(!proof.isCurrent())
        host.retire(launchID:id)
        print("PASS actual Pi 1.1.0 private TUI extension -> native Unix bridge -> bundled MCP metadata; natural Ctrl-D exit, zero model prompts")
    }

    static func write(_ value: [String:Any], _ file: URL) throws {
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        guard FileManager.default.createFile(atPath:file.path,contents:data,attributes:[.posixPermissions:0o600]) else { throw PiBridgeFailure.unavailable }
    }
}
