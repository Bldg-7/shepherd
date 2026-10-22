import Foundation
import Darwin
import AgentProxyForwarder
import AgentProxyProtocol

// hrdrhrdrhrdr-agent-proxy                 the forwarder (what launchd runs)
//   [--state-dir DIR] [--control-socket PATH]
// hrdrhrdrhrdr-agent-proxy recorder        the recorder the forwarder starts,
//                                           with its socketpair as descriptor 3
//
// --state-dir and --control-socket are for tests and development runs, so
// they never touch the user's folder; without them the paths are the ones in
// AgentProxyPaths under the user's home.

setvbuf(stderr, nil, _IOLBF, 0)
umask(0o077)
signal(SIGPIPE, SIG_IGN)

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(AgentProxyPaths.executableName): \(message)\n".utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "recorder" {
    guard arguments.count == 1 else { fail("recorder takes no arguments", code: 64) }
    exit(AgentProxyRecorder.run())
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
var stateDirectory = AgentProxyPaths.stateDirectory(home: home)
var controlSocket = AgentProxyPaths.controlSocket(home: home)
while !arguments.isEmpty {
    let name = arguments.removeFirst()
    guard ["--state-dir", "--control-socket"].contains(name), !arguments.isEmpty else {
        fail("usage: \(AgentProxyPaths.executableName) [--state-dir DIR] [--control-socket PATH] | recorder", code: 64)
    }
    let value = arguments.removeFirst()
    guard value.hasPrefix("/") else { fail("\(name) takes an absolute path", code: 64) }
    if name == "--state-dir" { stateDirectory = value } else { controlSocket = value }
}

guard let executable = Bundle.main.executablePath else { fail("cannot find its own executable") }
let build = AgentProxyServer.build(ofExecutableAt: executable)

@Sendable func log(_ line: String) {
    FileHandle.standardError.write(Data("\(AgentProxyPaths.executableName): \(line)\n".utf8))
}

nonisolated(unsafe) var server: AgentProxyServer?
let configuration = AgentProxyServer.Configuration(
    stateDirectory: stateDirectory, controlSocketPath: controlSocket, recorderCommand: [executable, "recorder"], build: build,
    log: { log($0) },
    onExitRequest: { code in
        // Off the event loop: shutting down waits for it.
        DispatchQueue.global().async {
            server?.shutdown()
            exit(code)
        }
    })
server = AgentProxyServer(configuration: configuration)
do {
    try server?.start()
} catch {
    fail("cannot start: \(error)")
}

signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
termination.setEventHandler {
    log("stopping")
    server?.shutdown()
    exit(0)
}
termination.resume()
dispatchMain()
