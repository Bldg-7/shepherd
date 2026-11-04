import Foundation
#if os(macOS)

/// Starts an owned private hc core and negotiates a connection, in one place,
/// so the app and every test share the same isolation policy. This is the local
/// direct-startup path only: it never registers a machine-wide launchd job, and
/// it never touches a running user core. The caller owns the returned
/// connection/transport and must stop the core it started.
public nonisolated enum HcCoreBootstrap {
    public enum Failure: Error, Equatable, Sendable {
        case invalidScope, socketPathTooLong, versionMismatch
    }
    public struct Scope: Sendable {
        public let root: URL
        public let state: URL
        public let config: URL
        public let runtime: URL
        public let socket: URL
        public init(root: URL) throws {
            guard root.isFileURL, root.path.hasPrefix("/") else { throw Failure.invalidScope }
            self.root = root
            state = root.appendingPathComponent("state", isDirectory: true)
            config = root.appendingPathComponent("config", isDirectory: true)
            runtime = root.appendingPathComponent("runtime", isDirectory: true)
            socket = root.appendingPathComponent("c.sock")
            guard socket.path.utf8.count < 104 else { throw Failure.socketPathTooLong }
        }
    }
    /// The private core environment. `SSH_CONNECTION` is a fixture marker that
    /// keeps `serve` on the direct path instead of escaping to launchd; it is
    /// not a claim that a launchd lifecycle was exercised. The app's real local
    /// launch must still handle startup-as-a-service separately.
    public static func environment(for scope: Scope) -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": scope.root.path,
         "XDG_STATE_HOME": scope.state.path, "XDG_CONFIG_HOME": scope.config.path,
         "XDG_RUNTIME_DIR": scope.runtime.path, "HC_SESSION": "owned", "HC_SOCKET": scope.socket.path,
         "SSH_CONNECTION": "owned-fixture-no-launchd", "LANG": "en_US.UTF-8", "DO_NOT_TRACK": "1"]
    }
    /// Starts the core and returns the live connection plus its hello. The
    /// caller owns all three and stops the core through `server.stop` before
    /// closing. The hello version must match the binary's own report; generation
    /// and required methods are enforced by the handshake decoder, never by
    /// trusting a package version string.
    public static func connect(binary: URL, scope: Scope, requiredMethods: Set<String> = ["terminal.list", "terminal.attach", "terminal.run", "events.subscribe", "server.stop"]) async throws -> (CoreProcessTransport, CoreRPCConnection, CoreHello) {
        try FileManager.default.createDirectory(at: scope.state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scope.config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scope.runtime, withIntermediateDirectories: true)
        let transport = try CoreProcessTransport(configuration: .init(executable: binary, environment: environment(for: scope), directory: scope.root))
        let connection = try CoreRPCConnection(transport: transport, requiredMethods: requiredMethods)
        do {
            let hello = try await connection.connect()
            return (transport, connection, hello)
        } catch {
            try? await connection.close()
            throw error
        }
    }
}
#endif
