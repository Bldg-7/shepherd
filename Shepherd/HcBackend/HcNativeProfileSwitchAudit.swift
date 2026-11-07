#if DEBUG && os(macOS)
import AppKit
import Foundation
import ShepherdKit

@MainActor enum HcNativeProfileSwitchAudit {
    static func run(owner: HcMachineConnection, store: MachineStore, secrets: HcFixtureSecrets,
                    profile: HcFixtureRemoteProfile, control: CoreRPCConnection, root: URL) async throws -> Int {
        guard let local = store.activeMachine, local.isLocal, let initial = owner.model,
              let localCore = initial.coreID, localCore != profile.coreID,
              let window = NSApp.windows.first(where:{ $0.isKeyWindow && $0.contentView.map { HcWorkspaceLayoutAudit.split($0) != nil } == true }),
              let content = window.contentView else { throw HcWorkspaceModel.Failure.unavailable }
        var checks = 0
        func check(_ b: Bool, _ message: String) throws { guard b else { throw HcWorkspaceLayoutAudit.Failure.assertion(message) }; checks += 1 }
        func settings(_ machine: Machine, label: String) async throws {
            try hcNativeFixtureCommand(",",code:43,label:label,window:window,root:root)
            try await HcWorkspaceLayoutAudit.wait("actual machine Settings sheet") {
                HcWorkspaceLayoutAudit.ownedSheetContent(window)?.window?.isKeyWindow == true
            }
            guard let sheet = HcWorkspaceLayoutAudit.ownedSheetContent(window) else { throw HcWorkspaceModel.Failure.unavailable }
            let id = "settings.machine.activate." + machine.id.uuidString
            try await HcWorkspaceLayoutAudit.wait("actual enabled Make Active control") {
                guard let button = HcWorkspaceLayoutAudit.elements(sheet)[id] else { return false }
                return (button as AnyObject).isAccessibilityEnabled?() == true
            }
            try HcWorkspaceLayoutAudit.press(id,content:sheet)
            try await HcWorkspaceLayoutAudit.wait("native Make Active selects requested profile") { store.activeMachineID == machine.id }
            try HcWorkspaceLayoutAudit.press("hc.settings.done",content:sheet)
            try await HcWorkspaceLayoutAudit.wait("Settings dismissed to owned key window") { window.attachedSheet == nil && window.isKeyWindow }
        }
        func chooseLiveRow(_ model: HcWorkspaceModel) async throws {
            guard let core = model.coreID else { throw HcWorkspaceModel.Failure.unavailable }
            let end = ContinuousClock.now.advanced(by:.seconds(8))
            while true {
                guard owner.model === model, model.state == .connected else { throw HcWorkspaceModel.Failure.stale }
                let candidates = (model.document?.workspaces.flatMap(\.tabs) ?? []).flatMap { tab in
                    (tab.layout?.panes ?? []).compactMap { pane -> (UUID,UUID)? in
                        guard let ref = pane.terminal, ref.coreID == core,
                              model.terminals.contains(where:{ $0.address == ref.terminalID && $0.state == "live" }) else { return nil }
                        return (tab.id,pane.id)
                    }
                }
                let nodes = HcWorkspaceLayoutAudit.elements(content)
                if let id = candidates.flatMap({ ["hc-workspace.tab.\($0.0)","hc-workspace.pane.\($0.1)"] }).first(where:{ nodes[$0] != nil }) {
                    try HcWorkspaceLayoutAudit.clickRow(id,content:content); return
                }
                guard ContinuousClock.now < end else { throw HcWorkspaceLayoutAudit.Failure.assertion("actual live scoped profile row") }
                try await Task.sleep(for:.milliseconds(20))
            }
        }
        let before = try await HcTerminalBoard(connection:control).list(all:true)
        try await settings(profile.machine,label:"native-profile-settings-to-ssh")
        try await HcWorkspaceLayoutAudit.wait("actual remote host-key approval UI",seconds:12) {
            owner.phase == .approveHostKey(profile.fingerprint) && HcWorkspaceLayoutAudit.elements(content)["hc.ssh.approve"] != nil
        }
        try check(initial.state == .closed && owner.model == nil && secrets.reads == 0,
                  "native profile selection retires old model and requests exact pin before credentials")
        try HcWorkspaceLayoutAudit.press("hc.ssh.approve",content:content)
        try await HcWorkspaceLayoutAudit.wait("approved remote model published",seconds:12) {
            owner.phase == .connected && owner.identity == profile.machine.connectionIdentity && owner.model?.coreID == profile.coreID
        }
        guard let remote = owner.model else { throw HcWorkspaceModel.Failure.unavailable }
        try await chooseLiveRow(remote)
        try await HcWorkspaceLayoutAudit.wait("actual SSH-origin terminal rendered",seconds:12) {
            HcWorkspaceLayoutAudit.terminals(content).contains { HcWorkspaceLayoutAudit.renderedFlatText($0).contains("HC-REMOTE-ORIGIN-B") }
        }
        try check(secrets.reads == 1 && !hcAccessibilityText(content).contains("HC-FILE-PREVIEW-CONTENT"),
                  "native approved SSH uses one private credential read and does not show the old origin preview")
        try await settings(local,label:"native-profile-settings-back-local")
        try await HcWorkspaceLayoutAudit.wait("local model republished after remote retirement",seconds:12) {
            owner.phase == .connected && owner.identity == local.connectionIdentity && owner.model?.coreID == localCore && remote.state == .closed
        }
        guard let restored = owner.model else { throw HcWorkspaceModel.Failure.unavailable }
        try await chooseLiveRow(restored)
        try await HcWorkspaceLayoutAudit.wait("local native terminal visible again") { !HcWorkspaceLayoutAudit.terminals(content).isEmpty }
        let after = try await HcTerminalBoard(connection:control).list(all:true)
        try check(after.count == before.count && after.allSatisfy { fresh in
            before.contains { $0.address == fresh.address && $0.pid == fresh.pid && $0.createdMs == fresh.createdMs && $0.state == fresh.state }
        },"native profile switching preserves every local program incarnation")
        let remoteRead = try await store.makeHcConnection(for:profile.machine)
        do {
            let record = try await HcTerminalBoard(connection:remoteRead).get(profile.terminal)
            try check(record.state == "live" && record.address == profile.terminal,
                      "retiring remote UI preserves its exact canonical program")
            try await remoteRead.close()
        } catch { try? await remoteRead.close(); throw error }
        try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"directSSHProfileUI":true,
            "distinctCoreIDs":true,"privateCredentialReads":secrets.reads,"credentialFileRemoved":!FileManager.default.fileExists(atPath:root.appending(path:"remote-sidecar/remote-profile-secret.json").path),
            "userCredentialUsed":false,"gatewayAuthorityInferred":false,"releaseCutover":false])
            .write(to:root.appending(path:"native-profile-switch.json"),options:.atomic)
        return checks
    }
}
#endif
