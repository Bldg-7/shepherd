#if DEBUG && os(macOS)
import SwiftUI
import AppKit

/// Explicit private integration route while release UI parity is incomplete.
/// Never a user preference/backend fallback; release builds cannot select it.
/// The default app remains unchanged until installation/remote/file parity gates.
struct HcMigrationConfiguration {
    let root: URL
    let binary: URL
    static var requested: Bool { ProcessInfo.processInfo.environment["SHEPHERD_HC_UI_ROOT"] != nil }
    static var current: Self? {
        guard requested else { return nil }
        let env = ProcessInfo.processInfo.environment
        guard let root = env["SHEPHERD_HC_UI_ROOT"], root.hasPrefix("/private/tmp/hc-screen-app."),
              let binary = env["SHEPHERD_HC_UI_BINARY"], binary.hasPrefix(root + "/"),
              env["HOME"] == root + "/home" else { preconditionFailure("Explicit private hc UI fixture root/binary/HOME required") }
        return Self(root: URL(fileURLWithPath: root), binary: URL(fileURLWithPath: binary))
    }
    func machineStore() -> MachineStore {
        let defaults = UserDefaults(suiteName: "com.bldg-7.shepherd.hc-ui." + UUID().uuidString)!
        return MachineStore(defaults: defaults, localMachine: MachineStore.localMachine)
    }
}

@MainActor @Observable final class HcMigrationRenderProbe {
    static let shared = HcMigrationRenderProbe()
    private(set) var text = ""
    private(set) var bytes = 0
    func consumed(_ data: Data, rendered: String) {
        guard HcMigrationConfiguration.requested else { return }
        bytes += data.count
        text = String(rendered.suffix(16000))
    }
}

private nonisolated struct HcMigrationStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let holders: [Holder]
}

@MainActor private func hcAccessibility(_ view: NSView) -> [String: NSObject] {
    var found: [String: NSObject] = [:]
    var visited = Set<ObjectIdentifier>()
    func walk(_ node: AnyObject, _ depth: Int) {
        guard depth < 60, visited.insert(ObjectIdentifier(node)).inserted else { return }
        if let element = node as? NSAccessibilityElementProtocol, let id = element.accessibilityIdentifier?(), !id.isEmpty,
           let object = node as? NSObject { found[id] = object }
        for child in (node.accessibilityChildren?() ?? nil) ?? [] { walk(child as AnyObject, depth + 1) }
        if let view = node as? NSView { for child in view.subviews { walk(child, depth + 1) } }
    }
    walk(view, 0)
    return found
}

struct HcMigrationHost: View {
    let configuration: HcMigrationConfiguration
    @State private var owner: HcMachineConnection?
    @State private var fixtureStore: MachineStore?
    @State private var fixtureTransport: CoreProcessTransport?
    @State private var failure = false
    var body: some View {
        Group {
            if let owner, let fixtureStore { HcRootView(machineStore: fixtureStore, connection: owner, localTransport: fixtureTransport) }
            else if failure { Text("Private hc integration failed") }
            else { ProgressView("Preparing private hc integration…") }
        }
        .task { await open() }
    }
    private func open() async {
        guard owner == nil else { return }
        let root = configuration.root, report = root.appending(path: "ui-report.json")
        var connection: CoreRPCConnection?, transport: CoreProcessTransport?, workspace: HcWorkspaceModel?
        var owned: [UInt32] = []
        var checks = 0
        do {
            let scope = try HcCoreBootstrap.Scope(root: root.appending(path: "core"))
            let (t, c, _) = try await HcCoreBootstrap.connect(binary: configuration.binary, scope: scope)
            connection = c; transport = t
            let status: HcMigrationStatus = try await c.call("server.status").result()
            owned = [status.pid]
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            let storage = root.appending(path: "workspace-store", directoryHint: .isDirectory)
            let owner = HcMachineConnection(directory: storage)
            let screenTransport = try CoreProcessTransport(configuration: .init(executable: configuration.binary,
                environment: HcCoreBootstrap.environment(for: scope), directory: scope.root))
            fixtureTransport = screenTransport; fixtureStore = configuration.machineStore(); self.owner = owner
            // Let the real product root's .task call the production machine
            // factory and open its model, rather than constructing a model here.
            let openingDeadline = ContinuousClock.now.advanced(by: .seconds(10))
            while owner.model == nil {
                guard owner.phase != .failed, ContinuousClock.now < openingDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            let m = owner.model!; workspace = m; checks += 1
            let id = try await m.createWorkspace(name: "Owned UI fixture"); checks += 1
            let peer = root.appending(path: "ui-peer.py").path
            try await m.launchTab(workspaceID: id, name: "Real hc terminal", argv: ["/usr/bin/python3","-I","-S","-B",peer]); checks += 1
            let running: HcMigrationStatus = try await c.call("server.status").result()
            let records = try await HcTerminalBoard(connection: c).list(all: true)
            owned += running.holders.map(\.pid) + records.compactMap(\.pid)
            try JSONSerialization.data(withJSONObject: ["ownedPIDs":owned]).write(to: report, options: .atomic)
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while !HcMigrationRenderProbe.shared.text.contains("HC-UI-RENDER-DONE") {
                guard ContinuousClock.now < deadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
            }
            checks += 1
            let persisted = FileManager.default.enumerator(at: storage, includingPropertiesForKeys: nil)?.allObjects.compactMap { ($0 as? URL)?.lastPathComponent } ?? []
            guard m.selectedTab != nil, m.focus.paneByTab[m.selectedTab!.id] != nil,
                  persisted.contains("recovery.json"), persisted.contains("focus.json") else { throw HcWorkspaceModel.Failure.unavailable }
            checks += 1
            guard let content = NSApp.windows.first(where: { $0.contentView?.bounds.width ?? 0 > 500 })?.contentView else { throw HcWorkspaceModel.Failure.unavailable }
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            _ = NSApp.perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"), with: NSNumber(value: true), with: "AXEnhancedUserInterface")
            guard let selectedTab = m.selectedTab else { throw HcWorkspaceModel.Failure.unavailable }
            let axDeadline = ContinuousClock.now.advanced(by: .seconds(4))
            var ax = hcAccessibility(content)
            while ax["hc-workspace.create-workspace"] == nil || ax["hc-workspace.tab.\(selectedTab.id)"] == nil {
                try JSONSerialization.data(withJSONObject: ax.keys.sorted()).write(to: root.appending(path: "accessibility.json"))
                guard ContinuousClock.now < axDeadline else { throw HcWorkspaceModel.Failure.unavailable }
                try await Task.sleep(for: .milliseconds(20))
                ax = hcAccessibility(content)
            }
            try JSONSerialization.data(withJSONObject: ax.keys.sorted()).write(to: root.appending(path: "accessibility.json"))
            checks += 1
            // NSView bitmap capture proves native terminal output, but may not
            // composite SwiftUI layer-backed/sidebar content. AX above checks
            // those real controls separately, without global accessibility access.
            // Screenshot of the actual SwiftUI sidebar and SwiftTerm pane,
            // rendered in this private app instance, not the user's window.
            if let window = NSApp.windows.first(where: { $0.contentView?.bounds.width ?? 0 > 500 }), let view = window.contentView,
               let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                if let png = image.representation(using: .png, properties: [:]) { try png.write(to: root.appending(path: "workspace.png")); checks += 1 }
            }
            // Only this fixture's explicitly isolated core may be stopped.
            _ = try await c.call("server.stop")
            await owner.close()
            try await c.close()
            let snapshot = await t.snapshot(), screenSnapshot = await screenTransport.snapshot()
            guard owner.phase == .idle, snapshot.reaped, screenSnapshot.reaped else { throw HcWorkspaceModel.Failure.unavailable }; checks += 1
            try JSONSerialization.data(withJSONObject: ["passed":true,"checks":checks,"ownedPIDs":owned,
                "productFactoryVerified":true,"renderedBytes":HcMigrationRenderProbe.shared.bytes,"sidebarAccessibilityVerified":true,"screenshot":FileManager.default.fileExists(atPath: root.appending(path:"workspace.png").path),
                "browserAuthorityUsed":false,"productCutover":false]).write(to: report, options: .atomic)
            NSApp.terminate(nil)
        } catch {
            failure = true
            if let connection { _ = try? await connection.call("server.stop") }
            await owner?.close()
            try? await workspace?.disconnect(); try? await connection?.close()
            let reaped = await transport?.snapshot().reaped ?? false
            try? JSONSerialization.data(withJSONObject: ["passed":false,"checks":checks,"ownedPIDs":owned,"reaped":reaped]).write(to: report, options: .atomic)
            exit(1)
        }
    }
}
#endif
