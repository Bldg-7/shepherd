#if DEBUG && os(macOS)
import AppKit
import Foundation

private nonisolated struct HcDiscoveryOwnedStatus: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32
    let holders: [Holder]
}

/// Existing CmdP surface on a truly empty app document; never invokes the
/// switcher's model closure in place of the real native command/Return.
@MainActor enum HcNativeDiscoveryAudit {
    static func run(model: HcWorkspaceModel, connection: CoreRPCConnection, window: NSWindow,
                    content: NSView, root: URL) async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw HcWorkspaceLayoutAudit.Failure.assertion(label) }; checks += 1
        }
        guard let version = model.workspace?.snapshot?.version, let core = model.coreID else { throw HcWorkspaceModel.Failure.unavailable }
        try check(model.document == nil,"native discovery starts from known missing metadata")
        // Simulate a program explicitly started outside Shepherd in this owned
        // core. Its acknowledged canonical receipt is only fixture provenance.
        let acknowledged = try await HcTerminalBoard(connection:connection).run(argv:["/bin/sleep","90"],cwd:root.path)
        let external = try await HcTerminalBoard(connection:connection).get(acknowledged.address)
        let reference = CoreWorkspaceDocument.TerminalReference(coreID:core,terminalID:external.address)
        let status: HcDiscoveryOwnedStatus = try await connection.call("server.status").result()
        let records = try await HcTerminalBoard(connection:connection).list(all:true)
        let pids = Array(Set([status.pid]+status.holders.map(\.pid)+records.compactMap(\.pid))).sorted()
        try JSONSerialization.data(withJSONObject:["ownedPIDs":pids,"auditPending":true]).write(to:root.appending(path:"audit-owned-identities.json"),options:.atomic)
        try await HcWorkspaceLayoutAudit.wait("external canonical terminal appears in live model") {
            model.terminals.contains { $0.address == external.address && $0.state == "live" }
        }
        try await HcWorkspaceLayoutAudit.wait("empty board exposes existing-program shortcut") { hcAccessibilityText(content).contains("Press ⌘P") }
        checks += 1
        try hcNativeFixtureCommand("p",code:35,label:"native-empty-discovery",window:window,root:root)
        try await HcWorkspaceLayoutAudit.wait("empty-board switcher owns real editor") {
            guard let sheet = HcWorkspaceLayoutAudit.ownedSheetContent(window), let own = sheet.window else { return false }
            let tree = HcWorkspaceLayoutAudit.elements(sheet)
            guard let row = tree["workspace.switcher.terminal.\(external.address)"] else { return false }
            return own.isKeyWindow && tree["workspace.switcher.search"] != nil
                && (row as AnyObject).isAccessibilityEnabled?() == true
                && (own.firstResponder as? NSTextView)?.isFieldEditor == true
        }
        guard let choosing = HcWorkspaceLayoutAudit.ownedSheetContent(window)?.window else { throw HcWorkspaceModel.Failure.unavailable }
        try HcWorkspaceLayoutAudit.returnKey(in:choosing)
        try await HcWorkspaceLayoutAudit.wait("explicit existing terminal selection creates its view",seconds:12) {
            HcWorkspaceLayoutAudit.ownedSheetContent(window) == nil && window.isKeyWindow && !model.operationBusy
                && model.selectedTab?.layout?.panes.first?.terminal == reference
                && HcWorkspaceLayoutAudit.terminals(content).count == 1
        }
        try check(model.workspace?.snapshot?.version == version+1 && model.document?.workspaces.count == 1,
                  "missing workspace and selected view use one CAS, not a partial two-write launch")
        let after = try await HcTerminalBoard(connection:connection).get(external.address)
        try check(after.pid == external.pid && after.createdMs == external.createdMs && after.state == "live",
                  "CmdP existing-terminal attach does not start/restart a program")
        try check(model.recoveryRecords.isEmpty,"explicit view never fabricates a launch receipt or resolves a recovery ticket")
        try hcNativeFixtureCommand("w",code:13,label:"native-discovered-view-close",window:window,root:root)
        try await hcFixtureWait("hc.close.confirm",present:true,enabled:true,window:window)
        try hcFixturePress("hc.close.confirm")
        try await HcWorkspaceLayoutAudit.wait("empty board returns after discovered view closes") {
            model.document?.panes.isEmpty == true && HcWorkspaceLayoutAudit.elements(content)["workspace.board.empty"] != nil
        }
        let preserved = try await HcTerminalBoard(connection:connection).get(external.address)
        try check(preserved.pid == external.pid && preserved.createdMs == external.createdMs && preserved.state == "live",
                  "closing last discovered view preserves the unplaced native program")
        try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"core":core,"terminal":external.address,
            "initialVersion":String(version),"viewOnly":true,"nativeSessionAuthority":false,"physicalGUIQualified":false])
            .write(to:root.appending(path:"native-empty-discovery.json"),options:.atomic)
        return checks
    }
}
#endif
