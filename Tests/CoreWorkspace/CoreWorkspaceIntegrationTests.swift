import Foundation

private nonisolated struct Status: Decodable, Sendable {
    struct Holder: Decodable, Sendable { let pid: UInt32 }
    let pid: UInt32; let live: Int; let holders: [Holder]
}
private nonisolated struct RunReceipt: Decodable, Sendable { let address: String; let pid: UInt32? }
private nonisolated struct Stored: Decodable, Sendable {
    // The fixture writes these exact values. Production storage decoding must
    // use the strict document codec, not this fixture-only wire convenience.
    struct Value: Decodable, Sendable { let schemaVersion: UInt32; let workspaces: [CoreWorkspaceDocument.Workspace] }
    let version: UInt64
    let value: Value?
    func document() throws -> CoreWorkspaceDocument? {
        guard let value else { return nil }
        guard value.schemaVersion == 1 else { throw CoreWorkspaceFailure.unsupportedSchema }
        return try CoreWorkspaceDocument(workspaces: value.workspaces)
    }
}
private nonisolated struct Written: Decodable, Sendable { let version: UInt64 }
private nonisolated struct Stopped: Decodable, Sendable { let stopped: Bool }
private nonisolated struct Notice: Decodable, Sendable {
    struct Params: Decodable, Sendable {
        struct Change: Decodable, Sendable { let name: String?; let version: UInt64? }
        let type: String?
        let data: Change?
    }
    let method: String
    let params: Params
}

@main @MainActor private struct CoreWorkspaceIntegrationTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws {
        guard value else { throw NSError(domain: label, code: 1) }; checks += 1
    }
    static func read(_ connection: CoreRPCConnection, _ state: inout CoreWorkspaceCAS) async throws {
        let token = try state.beginRead()
        let result: Stored = try await connection.call("doc.get", parameters: Data("{\"name\":\"\(CoreWorkspaceDocument.documentName)\"}".utf8)).result()
        try state.accept(token, version: result.version, document: result.document())
    }
    static func changed(_ stream: CoreStream, version: UInt64, lines: inout CoreEventLines) async throws {
        var found = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !found {
            guard ContinuousClock.now < deadline, let packet = try await stream.next(timeout: .seconds(3)), packet.frame.kind == .data else {
                throw NSError(domain: "missing subscribed doc notification", code: 1)
            }
            try lines.receive(packet.frame.payload) { bytes in
                let event = try JSONDecoder().decode(Notice.self, from: bytes)
                if event.method == "event", event.params.type == "doc", event.params.data?.name == CoreWorkspaceDocument.documentName,
                   event.params.data?.version == version { found = true }
            }
            try await stream.acknowledge(packet)
        }
        checks += 1
    }
    static func current(_ store: CoreWorkspaceStore, version: UInt64) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            let view = await store.view()
            if view.canWrite && view.snapshot?.version == version { checks += 1; return }
            guard ContinuousClock.now < deadline else { throw CoreWorkspaceSyncFailure.refreshRequired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func recovery(_ rpc: CoreRPCConnection, _ store: CoreWorkspaceStore, _ other: CoreWorkspaceStore,
                         home: URL, report: URL, ownedPIDs: inout [UInt32]) async throws {
        let file = home.appending(path: "recovery.json")
        let journal = try CoreWorkspaceRecovery(coreID: store.originCoreID, epoch: rpc.epoch, persist: { try $0.write(to: file, options: .atomic) })
        let initial = await store.view(), doc = initial.snapshot!.document!, tab = doc.workspaces[0].tabs[0], pane = tab.layout!.panes[0]
        func run(_ ticket: CoreWorkspaceRecovery.Ticket) async throws -> RunReceipt {
            let params = try JSONSerialization.data(withJSONObject: ["argv":["/usr/bin/python3","-I","-S","-B","-c","import time; time.sleep(60)"],
                "cwd":home.path,"keep":false,"no_parent":true,"no_notify":true,"labels":ticket.label])
            return try await rpc.call("terminal.run", parameters: params).result()
        }
        func track(_ receipt: RunReceipt) async throws {
            let status: Status = try await rpc.call("server.status").result()
            ownedPIDs = Array(Set(ownedPIDs + status.holders.map(\.pid) + [receipt.pid].compactMap { $0 }))
            try JSONSerialization.data(withJSONObject: ["corePID":status.pid,"ownedPIDs":ownedPIDs]).write(to: report, options: .atomic)
        }
        let lost = try await journal.beginLaunch(paneID: pane.id, document: doc)
        let orphan = try await run(lost); try await track(orphan)
        try await journal.finishLaunch(lost, terminal: nil) // Deliberately ignore the run ACK for recovery, not for fixture cleanup.
        do { _ = try await journal.beginLaunch(paneID: pane.id, document: doc); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreWorkspaceRecoveryFailure.busy { checks += 1 }
        let sibling = CoreWorkspaceDocument.Pane()
        _ = try await store.edit(.splitPane(pane.id, axis: .horizontal, ratio: 0.5, newPane: sibling), expectedVersion: 6)
        try await current(store, version: 7); try await current(other, version: 7)
        let unbound = await store.view().snapshot!
        let known = try await journal.beginLaunch(paneID: sibling.id, document: unbound.document!)
        let started = try await run(known); try await track(started)
        let ref = CoreWorkspaceDocument.TerminalReference(coreID: store.originCoreID, terminalID: started.address)
        try await journal.finishLaunch(known, terminal: ref)
        let attempt = try await journal.prepareLayoutAfterReview(known, snapshot: unbound)!
        _ = try await other.edit(.renameTab(tab.id, "concurrent edit"), expectedVersion: 7)
        try await current(store, version: 8)
        do { _ = try await store.edit(attempt.edit, expectedVersion: attempt.expectedVersion); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreWorkspaceStoreFailure.staleRevision { checks += 1 }
        try await journal.finishLayout(attempt, result: .conflict)
        let reviewed = try await journal.prepareLayoutAfterReview(known, snapshot: await store.view().snapshot!)!
        _ = try await store.edit(reviewed.edit, expectedVersion: reviewed.expectedVersion)
        try await journal.finishLayout(reviewed, result: .uncertain) // Simulated lost doc ACK, no retry.
        try await current(store, version: 9)
        try await journal.reconcileLayout(operationID: known.operationID, snapshot: await store.view().snapshot!)
        let live: Status = try await rpc.call("server.status").result()
        try check(live.live == 2, "CAS conflict/recovery did not duplicate either program")
        let close = try await journal.beginClose(tabID: tab.id, document: await store.view().snapshot!.document!, endPrograms: true)
        let remove = try await journal.prepareLayoutAfterReview(close, snapshot: await store.view().snapshot!)!
        let ack = try await store.edit(remove.edit, expectedVersion: remove.expectedVersion)
        try await journal.finishLayout(remove, result: ack)
        try await current(store, version: 10)
        let closedDocument = await store.view().snapshot!.document!
        let stop = try await journal.beginStop(close, terminal: ref, currentDocument: closedDocument)!
        let params = try JSONSerialization.data(withJSONObject: ["terminal":started.address])
        _ = try await rpc.call("terminal.kill", parameters: params) // Only the exact program created by this private fixture.
        try await journal.finishStop(stop, confirmedEnded: false)
        do { _ = try await journal.beginStop(close, terminal: ref, currentDocument: closedDocument); throw CoreWorkspaceFailure.invalidDocument }
        catch CoreWorkspaceRecoveryFailure.requiresReview { checks += 1 }
        let ended: CoreAttentionRecord = try await rpc.call("terminal.get", parameters: params).result()
        try await journal.confirmStoppedAfterRead(operationID: close.operationID, terminal: ended)
        let left: Status = try await rpc.call("server.status").result()
        try check(left.live == 1, "unknown run retained for review, never auto-killed or label-adopted")
        try check(await journal.snapshot().first(where: { $0.id == close.operationID })!.complete, "partial close reconciled by fresh finished read")
        // Final server.stop below owns and cleans the deliberately retained test orphan.
    }
    static func screenModel(config: CoreProcessTransport.Configuration, home: URL) async throws -> [UInt32] {
        let transport = try CoreProcessTransport(configuration: config)
        let connection = try CoreRPCConnection(transport: transport)
        let journal = home.appending(path: "model-operations.json"), focus = home.appending(path: "model-focus.json")
        let model = HcWorkspaceModel(connection: connection, saveRecovery: { try $0.write(to: journal, options: .atomic) },
                                     saveFocus: { try $0.write(to: focus, options: .atomic) })
        do {
            try await model.start()
            try check(model.state == .connected && model.canEdit, "screen model owns live RPC/storage subscriptions")
            let id = try await model.createWorkspace(name: "screen model")
            try await model.launchTab(workspaceID: id, name: "owned sleeper", argv: ["/bin/sleep","60"], cwd: home.path)
            guard let tab = model.selectedTab, let pane = tab.layout?.panes.first, let ref = pane.terminal else { throw CoreWorkspaceFailure.invalidReference }
            try check(model.focus.paneByTab[tab.id] == pane.id && ref.coreID == model.coreID, "actual launch journal binds selected pane")
            try await model.launchSplit(paneID: pane.id, axis: .horizontal, argv: ["/bin/sleep", "60"], cwd: home.path)
            guard let split = model.selectedTab?.layout?.panes.first(where: { $0.id != pane.id }), let splitRef = split.terminal else { throw CoreWorkspaceFailure.invalidReference }
            try check(model.selectedTab?.layout?.panes.count == 2 && model.focus.paneByTab[tab.id] == split.id, "split launch binds a second program and local focus")
            try await model.closePane(split.id)
            let stillLive = try await HcTerminalBoard(connection: connection).get(splitRef.terminalID)
            try check(model.selectedTab?.layout?.panes.count == 1 && stillLive.state == "live", "close pane collapses layout, keeps program alive")
            let before: Status = try await connection.call("server.status").result()
            let viewVersion = model.workspace!.snapshot!.version, workspaceCount = model.document!.workspaces.count
            let extraView = try await model.showTerminal(splitRef.terminalID,selectOnSuccess:false)
            let createdView = model.document?.workspaces.flatMap(\.tabs).first(where:{ $0.id == extraView })
            try check(model.workspace?.snapshot?.version == viewVersion + 1 && model.document?.workspaces.count == workspaceCount + 1,
                      "explicit existing-terminal workspace plus view is one exact CAS")
            try check(createdView?.layout?.panes.first?.terminal == splitRef && model.selectedTab?.id == tab.id,
                      "view-only discovery binds real reference without overriding newer UI focus")
            let afterDiscovery: Status = try await connection.call("server.status").result()
            try check(afterDiscovery.live == before.live,"existing-terminal discovery never starts or kills a program")
            try await model.closeTab(extraView)
            let beforeAlias = model.workspace?.snapshot?.version
            do { _ = try await model.showTerminal("mutable-alias",workspaceID:id); throw CoreWorkspaceFailure.invalidDocument }
            catch HcWorkspaceModel.Failure.unavailable { checks += 1 }
            try check(model.workspace?.snapshot?.version == beforeAlias,"alias rejection does not dispatch a layout mutation")
            try await model.showTerminal(splitRef.terminalID, workspaceID: id)
            let shown = model.selectedTab!
            let afterShow: Status = try await connection.call("server.status").result()
            try check(shown.layout?.panes.first?.terminal == splitRef && afterShow.live == before.live, "explicit new view of fresh canonical terminal, no rerun or label adoption")
            try await model.closeTab(shown.id)
            try model.select(tab: tab.id)
            try await model.closeTab(tab.id)
            let after: Status = try await connection.call("server.status").result()
            try check(before.live == after.live, "screen close only removes layout; program survives")
            try check(model.recoveryRecords.allSatisfy(\.complete), "screen journal reconciles successful run/bind/close")
            let restored = try CoreWorkspaceFocus.restore(Data(contentsOf: focus), coreID: model.coreID!)
            try check(restored == model.focus, "screen persists device-local focus")
            guard let completed = model.recoveryRecords.first else { throw CoreWorkspaceFailure.invalidDocument }
            let history = try await model.prepareOperationReview(completed.id)
            try check(!history.canApplyLayout && history.record.layout == .confirmed && !model.canEdit, "completed history never reapplies later-removed layout and disables editing during review")
            model.cancelOperationReview(history)
            try check(model.canEdit, "cancel review restores layout controls without dispatch")
            do { try await model.forgetOperationReview(history); throw CoreWorkspaceFailure.invalidDocument }
            catch HcWorkspaceModel.Failure.stale { checks += 1 }
            try await reviewedModel(config: config, home: home, connection: connection, model: model, workspaceID: id, reference: ref)
            let all = try await HcTerminalBoard(connection: connection).list(all: true)
            try await model.disconnect()
            try check(model.state == .closed && !model.canEdit, "screen disconnect retires writes")
            let snapshot = await transport.snapshot()
            try check(snapshot.reaped, "screen releases owned connect process, not core")
            // Keep the actual launched process in the outer fixture's cleanup
            // set too; a holder/core exit alone is not a process-retirement check.
            return before.holders.map(\.pid) + all.compactMap(\.pid)
        } catch { try? await model.disconnect(); throw error }
    }
    static func reviewedModel(config: CoreProcessTransport.Configuration, home: URL, connection: CoreRPCConnection,
                              model: HcWorkspaceModel, workspaceID: UUID, reference: CoreWorkspaceDocument.TerminalReference) async throws {
        let outside = try await CoreWorkspaceStore(connection: connection)
        _ = try await outside.start()
        let pane = CoreWorkspaceDocument.Pane(), tab = CoreWorkspaceDocument.Tab(name: "review placeholder", layout: .leaf(pane))
        let start = try await outside.refresh()
        guard let startVersion = start.snapshot?.version else { throw CoreWorkspaceFailure.invalidDocument }
        _ = try await outside.edit(.appendTab(workspace: workspaceID, tab: tab), expectedVersion: startVersion)
        let current = try await outside.refresh()
        guard let snap = current.snapshot, let doc = snap.document, let coreID = model.coreID else { throw CoreWorkspaceFailure.invalidDocument }
        let old = try CoreWorkspaceRecovery(coreID: coreID, epoch: UUID(), persist: { _ in })
        let ticket = try await old.beginLaunch(paneID: pane.id, document: doc)
        try await old.finishLaunch(ticket, terminal: reference) // Exact earlier owned run receipt, never a label.
        let attempt = try await old.prepareLayoutAfterReview(ticket, snapshot: snap)!
        try await old.finishLayout(attempt, result: .uncertain) // No write dispatched by this controlled fixture.
        let transport = try CoreProcessTransport(configuration: config), rpc = try CoreRPCConnection(transport: transport)
        let file = home.appending(path: "review-model-journal.json")
        let restored = HcWorkspaceModel(connection: rpc, savedRecovery: try await old.encoded(),
            saveRecovery: { try $0.write(to: file, options: .atomic) }, saveFocus: { _ in })
        var failure: (any Error)?
        do {
            try await restored.start()
            let before: Status = try await connection.call("server.status").result()
            let plan = try await restored.prepareOperationReview(ticket.operationID)
            try check(plan.canApplyLayout && !restored.canEdit && restored.operationReview?.id == plan.id, "explicit fresh review offers layout-only recovery after reconnect")
            _ = try await outside.edit(.renameTab(tab.id, "concurrent rename"), expectedVersion: plan.expectedVersion)
            let end = ContinuousClock.now.advanced(by: .seconds(5))
            while restored.document?.workspaces.flatMap(\.tabs).first(where: { $0.id == tab.id })?.name != "concurrent rename" {
                guard ContinuousClock.now < end else { throw CoreWorkspaceFailure.invalidDocument }
                try await Task.sleep(for: .milliseconds(5))
            }
            try check(!restored.canApply(plan), "newer document cannot authorize an old review")
            do { try await restored.applyOperationReview(plan); throw CoreWorkspaceFailure.invalidDocument }
            catch HcWorkspaceModel.Failure.stale { checks += 1 }
            restored.cancelOperationReview(plan)
            let fresh = try await restored.prepareOperationReview(ticket.operationID)
            try check(fresh.expectedVersion > plan.expectedVersion && fresh.canApplyLayout, "another user review explicitly selects the new baseline")
            try await restored.applyOperationReview(fresh)
            try check(restored.document?.pane(pane.id)?.terminal == reference && restored.recoveryRecords[0].complete, "one explicit reviewed CAS binds saved reference")
            let done = try await restored.prepareOperationReview(ticket.operationID)
            try check(!done.canApplyLayout, "completed recovery has no replay action")
            try await restored.forgetOperationReview(done)
            try check(restored.recoveryRecords.isEmpty, "explicit forget releases history quota")
            let after: Status = try await connection.call("server.status").result()
            let stillLive = try await HcTerminalBoard(connection: connection).get(reference.terminalID)
            try check(before.live == after.live && stillLive.state == "live", "review/rebase/forget never launch or terminate programs")
        } catch { failure = error }
        try await restored.disconnect(); try await outside.close()
        try check(await transport.snapshot().reaped, "recovery review owner releases only its own connect child")
        if let failure { throw failure }
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { throw CoreWorkspaceFailure.invalidDocument }
        let binary = URL(fileURLWithPath: args[1]), home = URL(fileURLWithPath: args[2]), report = URL(fileURLWithPath: args[3])
        for part in ["", "state", "config", "runtime"] { try FileManager.default.createDirectory(at: home.appending(path: part), withIntermediateDirectories: true) }
        let env = ["PATH":"/usr/bin:/bin", "HOME":home.path, "XDG_STATE_HOME":home.appending(path:"state").path,
                   "XDG_CONFIG_HOME":home.appending(path:"config").path, "XDG_RUNTIME_DIR":home.appending(path:"runtime").path,
                   "HC_SESSION":"owned", "HC_SOCKET":home.appending(path:"c.sock").path, "SSH_CONNECTION":"owned-fixture-no-launchd", "DO_NOT_TRACK":"1"]
        let config = CoreProcessTransport.Configuration(executable: binary, environment: env, directory: home)
        let ta = try CoreProcessTransport(configuration: config), tb = try CoreProcessTransport(configuration: config)
        let required: Set<String> = ["doc.get","doc.set","events.subscribe","server.status","server.stop"]
        let a = try CoreRPCConnection(transport: ta, requiredMethods: required), b = try CoreRPCConnection(transport: tb, requiredMethods: required)
        var streams: [CoreStream] = [], stores: [CoreWorkspaceStore] = [], pid: UInt32?, ownedPIDs: [UInt32] = [], failure: (any Error)?
        do {
            let ha = try await a.connect(), hb = try await b.connect()
            let status: Status = try await a.call("server.status").result(); pid = status.pid; ownedPIDs = [status.pid]
            try JSONSerialization.data(withJSONObject: ["corePID":status.pid]).write(to: report, options: .atomic)
            try check(ha.version == args[4] && hb.core.id == ha.core.id && status.live == 0, "two clients one fresh pinned core")
            var sa = try CoreWorkspaceCAS(originCoreID: ha.core.id, epoch: a.epoch), sb = try CoreWorkspaceCAS(originCoreID: hb.core.id, epoch: b.epoch)
            let ea = try await a.openStream("events.subscribe"), eb = try await b.openStream("events.subscribe")
            streams = [ea, eb]
            var linesA = try CoreEventLines(), linesB = try CoreEventLines()
            try sa.didSubscribe(coreID: ha.core.id, epoch: a.epoch); try sb.didSubscribe(coreID: hb.core.id, epoch: b.epoch)
            try await read(a, &sa); try await read(b, &sb)
            try check(sa.snapshot?.version == 0 && sb.snapshot?.document == nil, "confirmed missing, no automatic write")
            let firstTab = CoreWorkspaceDocument.Tab(name: "first", layout: .leaf(.init()))
            let first = try CoreWorkspaceDocument(workspaces: [.init(name: "macOS fixture", tabs: [firstTab])])
            let other = try CoreWorkspaceDocument(workspaces: [.init(name: "mobile fixture")])
            let wa = try sa.beginWrite(first), wb = try sb.beginWrite(other)
            let accepted: Written = try await a.call("doc.set", parameters: wa.parameters()).result()
            try sa.finish(wa, result: .acknowledged(version: accepted.version))
            let rejected = try await b.call("doc.set", parameters: wb.parameters())
            try check(rejected.error?.kind == "conflict", "real concurrent baseline conflict")
            try sb.finish(wb, result: .conflict)
            try await changed(ea, version: 1, lines: &linesA); try await changed(eb, version: 1, lines: &linesB)
            try sa.invalidate(epoch: a.epoch); try sb.invalidate(epoch: b.epoch)
            try await read(a, &sa); try await read(b, &sb)
            try check(sa.snapshot == sb.snapshot && sb.snapshot?.document == first, "losing writer refetches winner without overwrite")
            let mutation = try sa.beginWrite(other)
            // Deliberately discard an actual success reply. This exercises an
            // uncertain client outcome, not a claim of injected transport loss.
            _ = try await a.call("doc.set", parameters: mutation.parameters())
            try sa.finish(mutation, result: .uncertain)
            try await changed(ea, version: 2, lines: &linesA)
            try sa.invalidate(epoch: a.epoch); try await read(a, &sa)
            try check(sa.snapshot?.version == 2 && sa.snapshot?.document == other, "uncertain outcome resolved by read, not replay")
            let deletion = Data("{\"name\":\"\(CoreWorkspaceDocument.documentName)\",\"version\":2,\"value\":null}".utf8)
            let deleted: Written = try await b.call("doc.set", parameters: deletion).result()
            try check(deleted.version == 3, "foreign device deletion retains version")
            try await changed(eb, version: 3, lines: &linesB)
            try sb.invalidate(epoch: b.epoch); try await read(b, &sb)
            let recreate = try sb.beginWrite(first)
            try check(recreate.expectedVersion == 3 && sb.snapshot?.document == nil, "recreate uses tombstone version, not zero")

            // Exercise the production owner, not the manual fixture reducer.
            let ownerA = try await CoreWorkspaceStore(connection: a), ownerB = try await CoreWorkspaceStore(connection: b)
            stores = [ownerA, ownerB]
            let started = try await ownerA.start(); _ = try await ownerB.start()
            try check(started.canWrite && started.snapshot?.version == 3, "production owner subscribed/read")
            let pane = CoreWorkspaceDocument.Pane(), tabID = UUID()
            let workspace = CoreWorkspaceDocument.Workspace(name: "owner", tabs: [.init(id: tabID, name: "t", layout: .leaf(pane))])
            let saved = try await ownerA.edit(.appendWorkspace(workspace), expectedVersion: 3)
            try check(saved == .acknowledged(version: 4), "owner explicit create uses tombstone")
            try await current(ownerB, version: 4)
            do { _ = try await ownerB.edit(.renameWorkspace(workspace.id, "stale"), expectedVersion: 3); throw CoreWorkspaceFailure.invalidDocument }
            catch CoreWorkspaceStoreFailure.staleRevision { checks += 1 }
            try await current(ownerA, version: 4)
            let sibling = CoreWorkspaceDocument.Pane()
            _ = try await ownerA.edit(.splitPane(pane.id, axis: .horizontal, ratio: 0.4, newPane: sibling), expectedVersion: 4)
            try await current(ownerA, version: 5)
            _ = try await ownerA.edit(.removePane(sibling.id), expectedVersion: 5)
            try await current(ownerB, version: 6)
            try await current(ownerA, version: 6)
            let collapsed = await ownerB.view()
            try check(collapsed.snapshot?.document?.workspaces.first?.tabs.first?.layout == .leaf(pane), "automatic event read and split collapse")
            let live: Status = try await a.call("server.status").result()
            try check(live.live == 0, "layout edits never launch or kill programs")
            try await ownerA.close(); try await ownerB.close()
            let remainingA = await a.snapshot(), remainingB = await b.snapshot()
            try check(remainingA.streams == 1 && remainingB.streams == 1, "owners close only own subscriptions")
            let closed = await ownerA.view()
            try check(!closed.canWrite && closed.snapshot?.version == 6, "retired owner keeps read-only cache")
            let lifecycle = try await CoreWorkspaceStore(connection: a), competitor = try await CoreWorkspaceStore(connection: b)
            stores += [lifecycle, competitor]; _ = try await lifecycle.start(); _ = try await competitor.start()
            try await recovery(a, lifecycle, competitor, home: home, report: report, ownedPIDs: &ownedPIDs)
            ownedPIDs += try await screenModel(config: config, home: home)
            let finalOwned: Status = try await a.call("server.status").result()
            ownedPIDs = Array(Set(ownedPIDs + finalOwned.holders.map(\.pid)))
            try JSONSerialization.data(withJSONObject: ["corePID":finalOwned.pid,"ownedPIDs":ownedPIDs]).write(to:report,options:.atomic)
        } catch { failure = error }
        for store in stores { try? await store.close() }
        for stream in streams { try? await stream.close() }
        let stop: Stopped? = try? await a.call("server.stop").result()
        try await a.close(); try await b.close()
        let aa = await ta.snapshot(), bb = await tb.snapshot()
        let passed = failure == nil && stop?.stopped == true && aa.reaped && bb.reaped
        var result: [String: Any] = ["passed":passed,"checks":checks,"stopAcknowledged":stop?.stopped == true,
                                   "connectChildrenReaped":aa.reaped && bb.reaped,"noMutationReplay":true]
        if let pid { result["corePID"] = pid }
        result["ownedPIDs"] = ownedPIDs
        if let failure { result["failure"] = String(describing: failure) }
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]).write(to: report, options: .atomic)
        guard passed else { throw failure ?? CoreWorkspaceSyncFailure.refreshRequired }
        print("PASS owned real workspace CAS: \(checks) checks")
    }
}
