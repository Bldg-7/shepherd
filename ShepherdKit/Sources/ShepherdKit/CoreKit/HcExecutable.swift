import Foundation
#if os(macOS)

/// Where the hc (herdr-core) binary lives, mirroring the legacy herdr lookup:
/// usual install locations first, then PATH. Detection only proves the file is
/// an executable with the right command name; version/generation/method
/// compatibility is verified at hello time by `HcCoreBootstrap`, never by a
/// package version string alone.
public nonisolated enum HcExecutable {
    /// Command names the core ships under (`hc` and the archive's `herdr-core`).
    public static let commandNames = ["hc", "herdr-core"]

    /// Usual install locations, in the order tried. A path without a leading
    /// slash is relative to the home directory.
    public static let usualLocations = [
        ".local/bin/hc", ".local/bin/herdr-core",
        "/opt/homebrew/bin/hc", "/opt/homebrew/bin/herdr-core",
        "/usr/local/bin/hc", "/usr/local/bin/herdr-core",
    ]

    /// The real home directory from the password database, whatever the app's
    /// environment says (as the legacy herdr lookup did).
    public static func homeDirectory() -> String {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }

    /// Executable and a regular file: `isExecutableFile` alone returns true
    /// for directories, which are not binaries and must never be a candidate.
    public static func isExecutableRegularFile(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        // Package managers normally expose a symlink. Follow it, but still
        // reject directories, dangling links, devices and non-executables.
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return (try? FileManager.default.attributesOfItem(atPath: target)[.type] as? FileAttributeType) == .typeRegular
    }

    /// The first usual location holding an executable hc binary.
    public static func localPath() -> String? {
        let home = homeDirectory()
        return usualLocations
            .map { $0.hasPrefix("/") ? $0 : "\(home)/\($0)" }
            .first { isExecutableRegularFile($0) }
    }

    /// Candidates in order: usual locations (home-relative resolved), then each
    /// PATH entry for each command name. Duplicates are removed; a directory or
    /// non-executable is never a candidate.
    public static func candidates(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        func add(_ path: String) {
            let resolved = path.hasPrefix("/") ? path : "\(home)/\(path)"
            guard !seen.contains(resolved), isExecutableRegularFile(resolved) else { return }
            seen.insert(resolved)
            result.append(URL(fileURLWithPath: resolved))
        }
        for location in usualLocations { add(location) }
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        for entry in path.split(separator: ":").map(String.init) where entry.hasPrefix("/") {
            for name in commandNames { add("\(entry)/\(name)") }
        }
        return result
    }

    /// The first executable candidate. Does not run it: starting the binary is
    /// `HcCoreBootstrap`'s job, where the hello handshake decides compatibility.
    public static func resolve(candidates: [URL]) -> URL? {
        candidates.first { isExecutableRegularFile($0.path) }
    }
}
#endif
