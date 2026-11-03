import Foundation

@main @MainActor private struct CoreWorkspaceLifecycleTests {
    typealias Doc = CoreWorkspaceDocument
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain: label, code: 1) }; checks += 1 }
    static func rejects(_ label: String, _ body: () async throws -> Void) async throws {
        do { try await body() } catch { checks += 1; return }; throw NSError(domain: label, code: 1)
    }
    static func record(_ state: String = "working", turn: UInt64 = 0, time: UInt64 = 1, pid: UInt32? = 10,
                       finished: Bool = false, reason: String = "exited", address: String = "t1") throws -> CoreAttentionRecord {
        let raw = "{\"address\":\"\(address)\",\"state\":\"\(finished ? "finished" : "live")\",\"pid\":\(pid.map(String.init) ?? "null"),\"created_ms\":1,\"finished_ms\":\(finished ? String(time) : "null"),\"reported\":true,\"status\":{\"state\":\"\(state)\"},\"status_ms\":\(time),\"turn\":\(turn),\"reason\":\"\(reason)\"}"
        return try JSONDecoder().decode(CoreAttentionRecord.self, from: Data(raw.utf8))
    }
    static func main() async throws {
        let a = Doc.Pane(), b = Doc.Pane(), tab = Doc.Tab(name: "t", layout: .split(axis: .horizontal, ratio: 0.5, first: .leaf(a), second: .leaf(b)))
        let workspace = Doc.Workspace(name: "w", tabs: [tab])
        let doc = try Doc(workspaces: [workspace])
        var desktop = CoreWorkspaceFocus(), mobile = CoreWorkspaceFocus()
        desktop.reconcile(document: doc); mobile.reconcile(document: doc)
        try desktop.zoom(pane: b.id, in: doc); try mobile.select(pane: a.id, in: doc)
        try check(desktop.paneByTab[tab.id] == b.id && mobile.paneByTab[tab.id] == a.id, "independent device focus")
        let renamed = try CoreWorkspaceEdit.renameTab(tab.id, "remote rename").applying(to: doc)
        desktop.reconcile(document: renamed); mobile.reconcile(document: renamed)
        try check(desktop.zoomByTab[tab.id] == b.id && mobile.paneByTab[tab.id] == a.id, "remote edit does not steal focus")
        let removed = try CoreWorkspaceEdit.removePane(b.id).applying(to: renamed)
        desktop.reconcile(document: removed)
        try check(desktop.paneByTab[tab.id] == a.id && desktop.zoomByTab[tab.id] == nil, "deleted focused pane fallback and zoom clear")
        let saved = try desktop.encoded(coreID: "c1")
        try check(try CoreWorkspaceFocus.restore(saved, coreID: "c1") == desktop, "local restore")
        try await rejects("wrong focus scope") { _ = try CoreWorkspaceFocus.restore(saved, coreID: "c2") }
        desktop.reconcile(nil); try check(desktop.workspaceID == workspace.id, "unavailable preserves focus")
        desktop.reconcile(.init(version: 4, document: nil)); try check(desktop.workspaceID == nil, "confirmed missing clears focus")
        try check(!String(decoding: try doc.encoded(), as: UTF8.self).contains("zoom"), "focus not shared")

        let epoch = UUID(); var feed = CoreAttentionFeed(coreID: "c1", epoch: epoch)
        let done = try record("done", turn: 1, time: 2)
        try check(try feed.observe([done], epoch: epoch, sequence: 10).isEmpty, "initial done is baseline")
        _ = try feed.observe([record(turn: 1, time: 3)], epoch: epoch, sequence: 11)
        let nextDone = try record("done", turn: 2, time: 4)
        let candidates = try feed.observe([nextDone], epoch: epoch, sequence: 12)
        try check(candidates.count == 1 && feed.confirm(candidates[0], fresh: nextDone, epoch: epoch), "new done candidate confirmed")
        try feed.delivered(candidates[0])
        try check(try feed.observe([nextDone], epoch: epoch, sequence: 13).isEmpty, "delivered not repeated")
        try check(try feed.observe([done], epoch: epoch, sequence: 11).isEmpty, "late snapshot ignored")
        let blocked = try record("blocked", turn: 2, time: 5)
        let block = try feed.observe([blocked], epoch: epoch, sequence: 14)
        try check(block.count == 1, "blocked after done")
        feed.markViewed("t1")
        try check(!feed.confirm(block[0], fresh: blocked, epoch: epoch), "viewed candidate suppressed")
        _ = try feed.observe([record(turn: 2, time: 6)], epoch: epoch, sequence: 15)
        let exited = try record(turn: 3, time: 7, pid: nil, finished: true)
        let exit = try feed.observe([exited], epoch: epoch, sequence: 16)
        try check(exit.count == 1 && exit[0].key.kind == .exitedWhileWorking, "unexpected working exit")
        try check(try feed.observe([exited], epoch: epoch, sequence: 17).isEmpty && feed.pendingCount == 1, "exit remains one pending candidate")
        try check(feed.confirm(exit[0], fresh: exited, epoch: epoch), "fresh exit confirms")
        _ = try feed.observe([record("done", turn: 4, time: 8, pid: 22)], epoch: epoch, sequence: 18)
        try check(feed.pendingCount == 0, "replacement program baseline clears old exit")
        try check(try feed.observe([record("blocked", turn: 5, time: 10, pid: 22)], epoch: epoch, sequence: 22).isEmpty, "gap baseline not catchup alert")
        let newEpoch = UUID(); feed.reconnect(epoch: newEpoch)
        try check(try feed.observe([nextDone], epoch: newEpoch, sequence: 100).isEmpty, "reconnect baseline")
        try await rejects("old notification epoch") { _ = try feed.observe([], epoch: epoch, sequence: 101) }
        try check(!feed.confirm(exit[0], fresh: exited, epoch: newEpoch), "old confirmation rejected")
        var killedFeed = CoreAttentionFeed(coreID: "c1", epoch: epoch)
        _ = try killedFeed.observe([record()], epoch: epoch, sequence: 0)
        try check(try killedFeed.observe([record(turn: 1, time: 2, pid: nil, finished: true, reason: "killed")], epoch: epoch, sequence: 1).isEmpty, "explicit kill not an unexpected-exit alert")

        let report = URL(fileURLWithPath: CommandLine.arguments[1]), file = report.appendingPathExtension("journal")
        let persist: @Sendable (Data) throws -> Void = { try $0.write(to: file, options: .atomic) }
        let recovery = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        let launch = try await recovery.beginLaunch(paneID: a.id, document: doc)
        try check(FileManager.default.fileExists(atPath: file.path), "journal before dispatch ticket")
        try await rejects("duplicate run reservation") { _ = try await recovery.beginLaunch(paneID: a.id, document: doc) }
        let ref = Doc.TerminalReference(coreID: "c1", terminalID: "t1")
        try await recovery.finishLaunch(launch, terminal: ref)
        let attempt = try await recovery.prepareLayoutAfterReview(launch, snapshot: .init(version: 1, document: doc))!
        try await recovery.finishLayout(attempt, result: .conflict)
        try check(await recovery.snapshot()[0].terminal == ref, "CAS conflict keeps orphan reference")
        let retry = try await recovery.prepareLayoutAfterReview(launch, snapshot: .init(version: 2, document: doc))!
        let bound = try retry.edit.applying(to: doc)
        try await recovery.finishLayout(retry, result: .uncertain)
        try await rejects("uncertain layout not blindly retried") { _ = try await recovery.prepareLayoutAfterReview(launch, snapshot: .init(version: 2, document: doc)) }
        try await recovery.reconcileLayout(operationID: launch.operationID, snapshot: .init(version: 3, document: bound))
        try check(await recovery.snapshot()[0].complete, "lost doc ACK reconciled without run replay")
        let lost = try await recovery.beginLaunch(paneID: b.id, document: bound)
        try await recovery.finishLaunch(lost, terminal: nil)
        try await rejects("lost run not repeated") { _ = try await recovery.beginLaunch(paneID: b.id, document: bound) }
        try await rejects("label is not a run receipt") { _ = try await recovery.prepareLayoutAfterReview(lost, snapshot: .init(version: 3, document: bound)) }
        let close = try await recovery.beginClose(tabID: tab.id, document: bound, endPrograms: true)
        let remove = try await recovery.prepareLayoutAfterReview(close, snapshot: .init(version: 3, document: bound))!
        try await recovery.finishLayout(remove, result: .acknowledged(version: 4))
        let closedDoc = try remove.edit.applying(to: bound)
        let stop = try await recovery.beginStop(close, terminal: ref, currentDocument: closedDoc)!
        try await recovery.finishStop(stop, confirmedEnded: false)
        try await rejects("uncertain kill never auto-retries") { _ = try await recovery.beginStop(close, terminal: ref, currentDocument: closedDoc) }
        try await recovery.confirmStoppedAfterRead(operationID: close.operationID, terminal: exited)
        try check(await recovery.snapshot().first(where: { $0.id == close.operationID })!.complete, "lost stop ACK resolved by finished read")
        let reboot = try CoreWorkspaceRecovery(coreID: "c1", epoch: newEpoch, restoring: Data(contentsOf: file), persist: persist)
        try await rejects("old ticket after restore") { try await reboot.finishLaunch(lost, terminal: ref) }
        let failing = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: { _ in throw CoreWorkspaceRecoveryFailure.invalidJournal })
        try await rejects("no dispatch if persistence fails") { _ = try await failing.beginLaunch(paneID: a.id, document: doc) }
        try check(await failing.snapshot().isEmpty, "failed persist is atomic in memory")
        let inflight = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        _ = try await inflight.beginLaunch(paneID: a.id, document: doc)
        let restored = try CoreWorkspaceRecovery(coreID: "c1", epoch: newEpoch, restoring: Data(contentsOf: file), persist: persist)
        try check(await restored.snapshot()[0].run == .uncertain, "crash while run inflight restores uncertain")
        try await rejects("wrong journal origin") { _ = try CoreWorkspaceRecovery(coreID: "c2", epoch: newEpoch, restoring: Data(contentsOf: file), persist: persist) }
        try await edgeCases(doc: doc, epoch: epoch, ref: ref, tabID: tab.id, persist: persist)
        try JSONSerialization.data(withJSONObject: ["passed":true,"checks":checks]).write(to: report)
        print("PASS focus/recovery/notification lifecycle: \(checks) checks")
    }
    static func edgeCases(doc: Doc, epoch: UUID, ref: Doc.TerminalReference, tabID: UUID,
                          persist: @escaping @Sendable (Data) throws -> Void) async throws {
        var crowded = CoreAttentionFeed(coreID: "c1", epoch: epoch)
        let waiting = try (1...130).map { try record(address: "t\($0)") }
        let done = try (1...130).map { try record("done", turn: 1, time: 2, address: "t\($0)") }
        _ = try crowded.observe(waiting, epoch: epoch, sequence: 0)
        let candidates = try crowded.observe(done, epoch: epoch, sequence: 1)
        try check(candidates.count == 128 && crowded.overflowed, "bounded notification backlog")
        for candidate in candidates { try crowded.delivered(candidate) }
        try check(try crowded.observe(done, epoch: epoch, sequence: 2).isEmpty, "overflow not replayed later")
        var exact = CoreAttentionFeed(coreID: "c1", epoch: epoch)
        let large: UInt64 = 9_007_199_254_740_993
        _ = try exact.observe([record(turn: large)], epoch: epoch, sequence: large)
        let largeEvent = try exact.observe([record("done", turn: large + 1, time: 2)], epoch: epoch, sequence: large + 1)
        try check(largeEvent[0].key.turn == large + 1, "notification UInt64 exact")
        exact.markViewed("t1")
        _ = try exact.observe([record(turn: large + 1, time: 3)], epoch: epoch, sequence: large + 2)
        try check(try exact.observe([record("done", turn: large + 2, time: 4)], epoch: epoch, sequence: large + 3).count == 1, "seen suppresses current news, not future turn")
        let p1 = Doc.Pane(terminal: ref), ref2 = Doc.TerminalReference(coreID: "c1", terminalID: "t2")
        let p2 = Doc.Pane(terminal: ref2)
        let batchTab = Doc.Tab(name: "batch", layout: .split(axis: .horizontal, ratio: 0.5, first: .leaf(p1), second: .leaf(p2)))
        let batchDoc = try Doc(workspaces: [.init(name: "batch", tabs: [batchTab])])
        let journal = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        let close = try await journal.beginClose(tabID: batchTab.id, document: batchDoc, endPrograms: true)
        try await rejects("no kill before layout commit") { _ = try await journal.beginStop(close, terminal: ref, currentDocument: try Doc()) }
        let layout = try await journal.prepareLayoutAfterReview(close, snapshot: .init(version: 1, document: batchDoc))!
        try await journal.finishLayout(layout, result: .acknowledged(version: 2))
        let empty = try layout.edit.applying(to: batchDoc)
        let one = try await journal.beginStop(close, terminal: ref, currentDocument: empty)!
        let two = try await journal.beginStop(close, terminal: ref2, currentDocument: empty)!
        try await journal.finishStop(one, confirmedEnded: true); try await journal.finishStop(two, confirmedEnded: false)
        let partial = await journal.snapshot()[0]
        try check(!partial.complete && partial.targets.map(\.state) == [.confirmed,.uncertain], "partial batch retains per-target outcome")
        try await rejects("confirmed stop not repeated") { _ = try await journal.beginStop(close, terminal: ref, currentDocument: empty) }
        let restored = try CoreWorkspaceRecovery(coreID: "c1", epoch: UUID(), restoring: await journal.encoded(), persist: persist)
        try check(await restored.snapshot()[0].targets.map(\.state) == [.confirmed,.uncertain], "partial outcomes survive restore")
        let sharedTab = Doc.Tab(name: "other view", layout: .leaf(.init(terminal: ref)))
        let sharedDoc = try Doc(workspaces: [.init(name: "w", tabs: [batchTab, sharedTab])])
        let shared = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        _ = try await shared.beginClose(tabID: batchTab.id, document: sharedDoc, endPrograms: true)
        try check(await shared.snapshot()[0].targets.first(where: { $0.terminal == ref })?.state == .shared, "existing shared view is not killed")
        let reinsertion = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        let closing = try await reinsertion.beginClose(tabID: batchTab.id, document: batchDoc, endPrograms: true)
        let attempt = try await reinsertion.prepareLayoutAfterReview(closing, snapshot: .init(version: 3, document: batchDoc))!
        try await reinsertion.finishLayout(attempt, result: .acknowledged(version: 4))
        let concurrentlyViewed = try Doc(workspaces: [.init(name: "new", tabs: [sharedTab])])
        try check(try await reinsertion.beginStop(closing, terminal: ref, currentDocument: concurrentlyViewed) == nil, "reintroduced view suppresses pending stop")
        let quota = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: { _ in })
        let manyTabs = (0..<65).map { Doc.Tab(name: String($0)) }
        let many = try Doc(workspaces: [.init(name: "many", tabs: manyTabs)])
        for tab in manyTabs.prefix(64) { _ = try await quota.beginClose(tabID: tab.id, document: many, endPrograms: false) }
        try await rejects("no implicit journal eviction") { _ = try await quota.beginClose(tabID: manyTabs[64].id, document: many, endPrograms: false) }
        try check(await quota.snapshot().count == 64, "quota failure preserves pending records")
    }
}
