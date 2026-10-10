#if DEBUG && os(macOS)
import AppKit

/// Explicit owned UI-test initialization only. Invalid bindings terminate
/// before any default socket, user defaults or runtime context is selected.
@MainActor enum OwnedOperatorFixture {
    struct Configuration {
        let root: URL
        let home: URL
        let socket: String
        let defaults: UserDefaults
        let domain: String
        let machine: Machine
    }
    private struct Input: Decodable {
        let marker: String
        let machineID: UUID
        let defaultsDomain: String
    }
    static let configuration: Configuration? = {
        let environment = ProcessInfo.processInfo.environment
        guard let binding = environment["SHEPHERD_OWNED_OPERATOR_ROOT"] else { return nil }
        do {
            let canonicalRoot = try OwnedOperatorPaths.existing(binding)
            guard canonicalRoot.hasPrefix("/private/tmp/shepherd-operator-owned-") else { throw Failure.invalidBinding }
            try OwnedOperatorPaths.owned(canonicalRoot, type: .typeDirectory, mode: 0o700)
            let root = URL(fileURLWithPath: canonicalRoot, isDirectory: true)
            let markerPath = try OwnedOperatorPaths.descendant(canonicalRoot + "/owned-operator.json", root: canonicalRoot)
            guard markerPath == canonicalRoot + "/owned-operator.json" else { throw Failure.invalidBinding }
            try OwnedOperatorPaths.owned(markerPath, type: .typeRegular, mode: 0o600)
            let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: URL(fileURLWithPath: markerPath)))
            let homePath = try OwnedOperatorPaths.descendant(canonicalRoot + "/home", root: canonicalRoot)
            let profilePath = try OwnedOperatorPaths.descendant(canonicalRoot + "/browser", root: canonicalRoot)
            let socketPath = try OwnedOperatorPaths.descendant(homePath + "/.config/herdr/herdr.sock", root: canonicalRoot)
            let configPath = try OwnedOperatorPaths.descendant(homePath + "/.config/herdr/config.toml", root: canonicalRoot)
            try OwnedOperatorPaths.owned(homePath, type: .typeDirectory)
            try OwnedOperatorPaths.owned(profilePath, type: .typeDirectory)
            try OwnedOperatorPaths.owned(socketPath, type: .typeSocket)
            try OwnedOperatorPaths.owned(configPath, type: .typeRegular)
            guard input.marker == "owned-operator-v1",
                  input.defaultsDomain == "com.bldg-7.shepherd.operator-fixture." + input.machineID.uuidString,
                  Bundle.main.bundleIdentifier == "com.bldg-7.shepherd.operator-fixture",
                  try OwnedOperatorPaths.existing(environment["HOME"] ?? "") == homePath,
                  try OwnedOperatorPaths.existing(environment["SHEPHERD_BROWSER_TEST_ROOT"] ?? "") == profilePath,
                  try OwnedOperatorPaths.existing(environment["HERDR_CONFIG_PATH"] ?? "") == configPath else { throw Failure.invalidBinding }
            for path in [canonicalRoot + "/runtime", homePath + "/.claude/settings.json", homePath + "/.claude/skills", homePath + "/.codex"] {
                _ = try OwnedOperatorPaths.descendant(path, root: canonicalRoot, allowMissingLeaf: true)
            }
            let home = URL(fileURLWithPath: homePath, isDirectory: true)
            let defaults = UserDefaults(suiteName: input.defaultsDomain)!
            defaults.removePersistentDomain(forName: input.defaultsDomain)
            defaults.register(defaults: [AgentBoardView.showsTabsKey: true])
            let machine = Machine(id: input.machineID, displayName: "Owned Operator Mac", hostname: "localhost", username: "owned", isLocal: true)
            return Configuration(root: root, home: home, socket: socketPath, defaults: defaults, domain: input.defaultsDomain, machine: machine)
        } catch { fatalError("Owned operator fixture bindings could not be verified") }
    }()
    private enum Failure: Error { case invalidBinding }

    static func machineStore() -> MachineStore {
        guard let configuration else { return MachineStore() }
        return MachineStore(defaults: configuration.defaults, localMachine: configuration.machine, localSocketPath: configuration.socket)
    }
    static func launchService() -> AgentLaunchService {
        guard let configuration else { return AgentLaunchService() }
        return AgentLaunchService(context: {
            AgentLaunchService.HostContext(root: configuration.root.appending(path: "runtime").path,
                resources: try AgentSkillSetup.bundledResourceDirectory(), node: "node",
                claudeSettings: configuration.home.appending(path: ".claude/settings.json").path,
                claudeSkills: configuration.home.appending(path: ".claude/skills").path,
                codexHome: configuration.home.appending(path: ".codex").path)
        }, defaults: configuration.defaults, makeLocalClient: { machine in
            precondition(machine.id == configuration.machine.id, "Only the owned fixture machine is admitted")
            return HerdrClient(transport: LocalHerdrTransport(socketPath: configuration.socket))
        })
    }
    private static var snapshotObserver: NSObjectProtocol?
    private static func captureWindowSnapshot() {
        guard let configuration else { return }
        do {
            let root = try OwnedOperatorPaths.existing(configuration.root.path)
            let command = try OwnedOperatorPaths.descendant(root + "/window-snapshot-command.json", root: root)
            try OwnedOperatorPaths.owned(command, type: .typeRegular, mode: 0o600)
            let attributes = try FileManager.default.attributesOfItem(atPath: command)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 4097) <= 4096 else { throw Failure.invalidBinding }
            let input = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: command))) as? [String: Any]
            guard input?["command"] as? String == "window-snapshot", let request = input?["requestID"] as? String,
                  UUID(uuidString: request) != nil else { throw Failure.invalidBinding }
            let result: [String: Any] = ["requestID": request, "pid": ProcessInfo.processInfo.processIdentifier,
                "capturedAtEpochSeconds": Date().timeIntervalSince1970, "systemUptimeSeconds": ProcessInfo.processInfo.systemUptime,
                "mainThread": Thread.isMainThread, "isRunning": NSApp.isRunning, "isActive": NSApp.isActive,
                "activationPolicy": NSApp.activationPolicy().rawValue, "windowCount": NSApp.windows.count,
                "windows": NSApp.windows.map { ["className": String(describing: type(of: $0)), "styleMask": $0.styleMask.rawValue,
                    "frameEmpty": $0.frame.isEmpty, "frameWidth": $0.frame.width, "frameHeight": $0.frame.height,
                    "accessibilityRole": $0.accessibilityRole()?.rawValue ?? "", "number": $0.windowNumber, "visible": $0.isVisible,
                    "miniaturized": $0.isMiniaturized, "key": $0.isKeyWindow, "main": $0.isMainWindow] }]
            let response = try OwnedOperatorPaths.descendant(root + "/window-snapshot.json", root: root, allowMissingLeaf: true)
            try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: URL(fileURLWithPath: response), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: response)
        } catch { NSLog("Owned window snapshot command rejected") }
    }
    static func didLaunch() {
        guard let configuration else { return }
        snapshotObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(configuration.domain + ".window-snapshot"), object: configuration.domain, queue: .main
        ) { _ in MainActor.assumeIsolated { captureWindowSnapshot() } }
        let result: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleIdentifier!, "machineID": configuration.machine.id.uuidString,
            "featureEnabled": ShepherdBrowserFeature.shared.isEnabled, "nodeAbsent": ProcessInfo.processInfo.environment["PATH"] == "/usr/bin:/bin"]
        try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: configuration.root.appending(path: "app-ready.json"))
    }
    static func cleanUp() {
        guard let configuration else { return }
        if let snapshotObserver { DistributedNotificationCenter.default().removeObserver(snapshotObserver) }
        snapshotObserver = nil
        configuration.defaults.removePersistentDomain(forName: configuration.domain)
        UserDefaults.standard.removePersistentDomain(forName: "com.bldg-7.shepherd.operator-fixture")
    }
}
#endif
