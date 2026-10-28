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
// AgentProxyPaths under the user's home. A path may start with `~/` for that
// home: the Debug build's LaunchAgent passes its own paths this way, since
// launchd puts no home folder into a LaunchAgent's arguments.

setvbuf(stderr, nil, _IOLBF, 0)
umask(0o077)
signal(SIGPIPE, SIG_IGN)

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("\(AgentProxyPaths.executableName): \(message)\n".utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "storage-owner" {
    if arguments.count == 5 && arguments[1] == "--state-dir" && arguments[2].hasPrefix("/") && arguments[3] == "--producer-fd" && arguments[4] == "4" {
        exit(AgentProxyRecorder.storageOwner(stateDirectory: arguments[2], descriptor: 3, producerDescriptor: 4))
    }
    if arguments.count == 7 && arguments[1] == "--maintenance-clear" && arguments[2] == "--confirmed" && arguments[3] == "--state-dir" &&
       arguments[4].hasPrefix("/") && arguments[5] == "--socket" && AgentProxyPaths.socketPathFits(arguments[6]) {
        exit(AgentProxyRecorder.storageOwnerMaintenance(stateDirectory: arguments[4], socketPath: arguments[6]))
    }
    fail("usage: storage-owner --state-dir DIR --producer-fd 4 | --maintenance-clear --confirmed --state-dir DIR --socket PATH", code: 64)
}
if arguments.first == "recorder" {
    guard arguments.count == 1 || (arguments.count == 3 && arguments[1] == "--socket" && AgentProxyPaths.socketPathFits(arguments[2])) ||
          ((arguments.count == 5 || arguments.count == 7) && arguments[1] == "--socket" && AgentProxyPaths.socketPathFits(arguments[2]) && arguments[3] == "--state-dir" && arguments[4].hasPrefix("/") &&
           (arguments.count == 5 || (arguments[5] == "--producer-fd" && arguments[6] == "4"))) else {
        fail("usage: recorder [--socket PATH [--state-dir DIR [--producer-fd 4]]]", code: 64)
    }
    exit(AgentProxyRecorder.run(socketPath: arguments.count >= 3 ? arguments[2] : nil,
                                stateDirectory: arguments.count >= 5 ? arguments[4] : nil,
                                inheritedProducerDescriptor: arguments.count == 7 ? 4 : nil))
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
if arguments.first == "show" {
    arguments.removeFirst()
    var socket = AgentProxyPaths.recorderSocket(home: home)
    var terminal: String?
    var seen = Set<String>()
    while !arguments.isEmpty {
        let name = arguments.removeFirst()
        guard ["--socket", "--terminal"].contains(name), seen.insert(name).inserted, !arguments.isEmpty else {
            fail("usage: show --terminal ID [--socket PATH]", code: 64)
        }
        let value = arguments.removeFirst()
        if name == "--terminal" { terminal = value }
        else { socket = value.hasPrefix("~/") ? home + value.dropFirst() : value }
    }
    guard let terminal else { fail("show requires --terminal ID", code: 64) }
    do {
        let bytes = try AgentProxyConversationCLI.show(socketPath: socket, terminalID: terminal)
        FileHandle.standardOutput.write(bytes)
        exit(0)
    } catch AgentProxyConversationCLI.Failure.noConversation {
        fail("no captured conversation for that terminal", code: 2)
    } catch { fail("conversation read unavailable") }
}
var stateDirectory = AgentProxyPaths.stateDirectory(home: home)
var controlSocket = AgentProxyPaths.controlSocket(home: home)
while !arguments.isEmpty {
    let name = arguments.removeFirst()
    guard ["--state-dir", "--control-socket"].contains(name), !arguments.isEmpty else {
        fail("usage: \(AgentProxyPaths.executableName) [--state-dir DIR] [--control-socket PATH] | recorder", code: 64)
    }
    var value = arguments.removeFirst()
    if value.hasPrefix("~/") { value = home + value.dropFirst() }
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
    stateDirectory: stateDirectory, controlSocketPath: controlSocket, recorderCommand: [executable, "recorder", "--socket", AgentProxyPaths.recorderSocket(forControlSocket: controlSocket), "--state-dir", stateDirectory, "--producer-fd", "4"], build: build,
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
