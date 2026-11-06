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

        var baselineFeed = CoreAttentionFeed(coreID: "c1", epoch: epoch)
        _ = try baselineFeed.observe([record()], epoch: epoch, sequence: 0)
        let pending = try baselineFeed.observe([blocked], epoch: epoch, sequence: 1)
        try check(pending.count == 1, "candidate before missed snapshot")
        _ = try baselineFeed.observe([blocked], epoch: epoch, sequence: 1, baseline: true)
        try check(baselineFeed.pendingCount == 0 && !baselineFeed.confirm(pending[0], fresh: blocked, epoch: epoch), "same-sequence missed snapshot clears pending attention")
        try await rejects("regressing missed snapshot") { _ = try baselineFeed.observe([blocked], epoch: epoch, sequence: 0, baseline: true) }

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
        try await explicitReviewRebase(epoch: epoch)
        try await partialCloseAndStop(epoch: epoch)
        try JSONSerialization.data(withJSONObject: ["passed":true,"checks":checks]).write(to: report)
        print("PASS focus/recovery/notification lifecycle: \(checks) checks")
    }
    static func partialCloseAndStop(epoch: UUID) async throws {
        let left = Doc.Pane(terminal:.init(coreID:"c1",terminalID:"t1"))
        let right = Doc.Pane(terminal:.init(coreID:"c1",terminalID:"t2"))
        let tab = Doc.Tab(name:"partial",layout:.split(axis:.horizontal,ratio:0.5,first:.leaf(left),second:.leaf(right)))
        let doc = try Doc(workspaces:[.init(name:"w",tabs:[tab])])
        let ref = right.terminal!
        let journal = try CoreWorkspaceRecovery(coreID:"c1",epoch:epoch,persist:{ _ in })
        let ticket = try await journal.beginClose(paneID:right.id,document:doc,endPrograms:true)
        let attempt = try await journal.prepareLayoutAfterReview(ticket,snapshot:.init(version:12,document:doc))!
        let removed = try attempt.edit.applying(to:doc)
        try check(removed.pane(right.id) == nil && removed.pane(left.id)?.terminal == left.terminal,"partial close removes only its exact pane, not its sibling/tab")
        try await journal.finishLayout(attempt,result:.acknowledged(version:13))
        let stop = try await journal.beginStop(ticket,terminal:ref,currentDocument:removed)!
        let reserved = try await journal.encoded()
        try check((try JSONSerialization.jsonObject(with:reserved) as? [String:Any])?["schema"] as? Int == 2,"partial stop journal uses schema2")
        let restored = try CoreWorkspaceRecovery(coreID:"c1",epoch:UUID(),restoring:reserved,persist:{ _ in })
        try check(await restored.snapshot()[0].targets[0].state == .uncertain,"crash during partial stop restores uncertainty, never a dispatch ticket")
        try await journal.finishStop(stop,confirmedEnded:false)
        try await rejects("live done status is not proof of process termination") {
            try await journal.confirmStoppedAfterRead(operationID:ticket.operationID,terminal:record("done",address:"t2"))
        }
        let reopened = Doc.Tab(name:"reopened",layout:.leaf(.init(terminal:ref)))
        let reopenedDoc = try Doc(workspaces:[.init(name:"new",tabs:[reopened])])
        let second = try await journal.beginClose(tabID:reopened.id,document:reopenedDoc,endPrograms:true)
        let secondLayout = try await journal.prepareLayoutAfterReview(second,snapshot:.init(version:14,document:reopenedDoc))!
        let removedAgain = try secondLayout.edit.applying(to:reopenedDoc)
        try await journal.finishLayout(secondLayout,result:.acknowledged(version:15))
        try await rejects("reopened view cannot replay another ticket's uncertain kill") { _ = try await journal.beginStop(second,terminal:ref,currentDocument:removedAgain) }
        try await journal.confirmStoppedAfterRead(operationID:ticket.operationID,terminal:record(finished:true,reason:"killed",address:"t2"))
        try check(await journal.snapshot()[0].complete,"direct finished read reconciles partial close without kill replay")
        let sibling = Doc.Pane(terminal:ref)
        let sharedTab = Doc.Tab(name:"shared",layout:.split(axis:.vertical,ratio:0.5,first:.leaf(right),second:.leaf(sibling)))
        let sharedDoc = try Doc(workspaces:[.init(name:"s",tabs:[sharedTab])])
        let shared = try CoreWorkspaceRecovery(coreID:"c1",epoch:epoch,persist:{ _ in })
        let sharedTicket = try await shared.beginClose(paneID:right.id,document:sharedDoc,endPrograms:true)
        try check(await shared.snapshot()[0].targets[0].state == .shared,"sibling view protects the same program inside the tab")
        let sharedLayout = try await shared.prepareLayoutAfterReview(sharedTicket,snapshot:.init(version:1,document:sharedDoc))!
        try await shared.finishLayout(sharedLayout,result:.acknowledged(version:2))
        try check(await shared.snapshot()[0].complete,"shared program is deliberately retained, not falsely stopped")
        let stale = try CoreWorkspaceRecovery(coreID:"c1",epoch:epoch,persist:{ _ in })
        let staleTicket = try await stale.beginClose(paneID:right.id,document:doc,endPrograms:true)
        let changed = try CoreWorkspaceEdit.bindPane(right.id,expected:ref,replacement:.init(coreID:"c1",terminalID:"t3")).applying(to:doc)
        try await rejects("partial reapply cannot retarget a changed terminal reference") { _ = try await stale.prepareLayoutAfterReview(staleTicket,snapshot:.init(version:20,document:changed)) }
        let legacy = try CoreWorkspaceRecovery(coreID:"c1",epoch:epoch,persist:{ _ in })
        _ = try await legacy.beginClose(tabID:tab.id,document:doc,endPrograms:false)
        let legacyBytes = try await legacy.encoded()
        var old = try JSONSerialization.jsonObject(with:legacyBytes) as! [String:Any]
        old["schema"] = 1
        _ = try CoreWorkspaceRecovery(coreID:"c1",epoch:UUID(),restoring:JSONSerialization.data(withJSONObject:old),persist:{ _ in })
        checks += 1
        var invalidOld = try JSONSerialization.jsonObject(with:reserved) as! [String:Any]
        invalidOld["schema"] = 1
        try await rejects("schema1 never silently changes meaning to a partial close") { _ = try CoreWorkspaceRecovery(coreID:"c1",epoch:UUID(),restoring:JSONSerialization.data(withJSONObject:invalidOld),persist:{ _ in }) }
        let failure = try CoreWorkspaceRecovery(coreID:"c1",epoch:epoch,persist:{ bytes in
            let value = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            let records = value["records"] as? [[String:Any]] ?? []
            if records.contains(where:{ ($0["targets"] as? [[String:Any]] ?? []).contains(where:{ $0["state"] as? String == "inFlight" }) }) { throw CoreWorkspaceRecoveryFailure.invalidJournal }
        })
        let failTicket = try await failure.beginClose(paneID:right.id,document:doc,endPrograms:true)
        let failLayout = try await failure.prepareLayoutAfterReview(failTicket,snapshot:.init(version:1,document:doc))!
        try await failure.finishLayout(failLayout,result:.acknowledged(version:2))
        try await rejects("stop persistence failure yields no dispatch ticket") { _ = try await failure.beginStop(failTicket,terminal:ref,currentDocument:removed) }
        try check(await failure.snapshot()[0].targets[0].state == .pending,"failed durable stop mark leaves in-memory target pending")
    }
    static func explicitReviewRebase(epoch: UUID) async throws {
        let pane = Doc.Pane(), tab = Doc.Tab(name: "review", layout: .leaf(pane))
        let doc = try Doc(workspaces: [.init(name: "review", tabs: [tab])])
        let ref = Doc.TerminalReference(coreID: "c1", terminalID: "t1")
        let persist: @Sendable (Data) throws -> Void = { _ in }
        let old = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        let ticket = try await old.beginLaunch(paneID: pane.id, document: doc)
        try await old.finishLaunch(ticket, terminal: ref)
        _ = try await old.prepareLayoutAfterReview(ticket, snapshot: .init(version: 4, document: doc))
        let nextEpoch = UUID()
        let restored = try CoreWorkspaceRecovery(coreID: "c1", epoch: nextEpoch, restoring: await old.encoded(), persist: persist)
        try check(await restored.snapshot()[0].layout == .uncertain, "restored in-flight metadata needs review")
        try await rejects("layout rollback cannot be reviewed as fresh") { try await restored.reconcileLayout(operationID: ticket.operationID, snapshot: .init(version: 3, document: doc)) }
        try await restored.reconcileLayout(operationID: ticket.operationID, snapshot: .init(version: 4, document: doc))
        try check(try await restored.canReapplyLayoutAfterReview(ticket.operationID, snapshot: .init(version: 4, document: doc)), "known run receipt can be explicitly rebound after fresh read")
        let reviewedBytes = try await restored.encoded()
        let fail = try CoreWorkspaceRecovery(coreID: "c1", epoch: UUID(), restoring: reviewedBytes, persist: { _ in throw CoreWorkspaceRecoveryFailure.invalidJournal })
        try await rejects("rebase persist failure yields no dispatch ticket") { _ = try await fail.prepareRebasedLayoutAfterReview(ticket.operationID, snapshot: .init(version: 4, document: doc)) }
        try check(await fail.snapshot()[0].epoch == epoch, "failed rebase persistence does not rebind epoch")
        let attempt = try await restored.prepareRebasedLayoutAfterReview(ticket.operationID, snapshot: .init(version: 4, document: doc))
        try check(attempt.ticket.epoch == nextEpoch && attempt.expectedVersion == 4, "review mints current layout-only ticket at exact reviewed baseline")
        try check(try attempt.edit.applying(to: doc).pane(pane.id)?.terminal == ref, "rebase binds exact saved receipt, not a label")
        try await restored.finishLayout(attempt, result: .acknowledged(version: 5))
        try check(await restored.snapshot()[0].complete, "explicit rebase can complete bookkeeping")
        try await rejects("completed layout cannot be replayed") { _ = try await restored.prepareRebasedLayoutAfterReview(ticket.operationID, snapshot: .init(version: 5, document: doc)) }
        try await restored.forgetAfterUserReview(ticket.operationID)
        try check(await restored.snapshot().isEmpty, "explicit forget removes metadata only")
        let unknown = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        let lost = try await unknown.beginLaunch(paneID: pane.id, document: doc)
        try await unknown.retireInFlightForReview(lost.operationID)
        try check(await unknown.snapshot()[0].run == .uncertain, "orphaned dispatch bookkeeping is uncertain, not failed")
        try await unknown.reconcileLayout(operationID: lost.operationID, snapshot: .init(version: 0, document: doc))
        try check(try await !unknown.canReapplyLayoutAfterReview(lost.operationID, snapshot: .init(version: 0, document: doc)), "unknown run never gets a layout adoption ticket")
        try await rejects("unknown run cannot be resumed") { _ = try await unknown.prepareRebasedLayoutAfterReview(lost.operationID, snapshot: .init(version: 0, document: doc)) }
        let closing = try CoreWorkspaceRecovery(coreID: "c1", epoch: epoch, persist: persist)
        let close = try await closing.beginClose(tabID: tab.id, document: doc, endPrograms: false)
        let changed = try CoreWorkspaceEdit.splitPane(pane.id, axis: .vertical, ratio: 0.5, newPane: .init()).applying(to: doc)
        try check(try await !closing.canReapplyLayoutAfterReview(close.operationID, snapshot: .init(version: 2, document: changed)), "close rebase cannot discard concurrently changed members")
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
