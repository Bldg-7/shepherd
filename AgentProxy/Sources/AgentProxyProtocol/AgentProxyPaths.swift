import Foundation

/// Where the agent proxy keeps its state and its sockets, and the limits the
/// paths have to keep to. The app and the proxy both work these out from the
/// user's home folder; tests and development runs pass their own paths to the
/// executable (`--state-dir`, `--control-socket`) instead.
public nonisolated enum AgentProxyPaths {
    /// The app's folder in Application Support, shared with its other state.
    public static let applicationFolder = "com.bldg-7.shepherd"
    /// The proxy's own folder inside it: `state.json` and `routes.json`, 0700.
    public static let stateFolderName = "AgentProxy"
    /// The forwarder's control socket, next to the proxy's folder rather than
    /// in it, so its path stays short.
    public static let controlSocketName = "ap.sock"
    /// The recorder's read socket (stage 2).
    public static let recorderSocketName = "ac.sock"
    /// The LaunchAgent the app registers while the setting is on (1b).
    public static let launchAgentLabel = "com.bldg-7.shepherd.agent-proxy"
    public static let executableName = "hrdrhrdrhrdr-agent-proxy"

    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, and the path has to end
    /// with a NUL inside it.
    public static let maximumSocketPathBytes = 103

    /// The listener's port is picked once from here and kept in `state.json`,
    /// so the base URLs given to running agents stay valid when the proxy is
    /// started again. Below the Darwin ephemeral range (49152 and up).
    public static let portRange: ClosedRange<Int> = 20000...32767

    public static func applicationSupport(home: String) -> String {
        trimmed(home) + "/Library/Application Support/" + applicationFolder
    }

    public static func stateDirectory(home: String) -> String {
        applicationSupport(home: home) + "/" + stateFolderName
    }

    public static func controlSocket(home: String) -> String {
        applicationSupport(home: home) + "/" + controlSocketName
    }

    public static func recorderSocket(home: String) -> String {
        applicationSupport(home: home) + "/" + recorderSocketName
    }

    /// Whether `path` can be bound or connected to as a Unix socket: absolute,
    /// no NUL, and short enough for `sun_path`.
    public static func socketPathFits(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        return bytes.first == UInt8(ascii: "/") && !bytes.contains(0) && bytes.count <= maximumSocketPathBytes
    }

    private static func trimmed(_ home: String) -> String {
        var home = home
        while home.count > 1 && home.hasSuffix("/") { home.removeLast() }
        return home
    }
}
