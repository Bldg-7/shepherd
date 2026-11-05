import Foundation

typealias Doc = CoreWorkspaceDocument

@main @MainActor private struct CoreWorkspaceTests {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) throws {
        guard condition else { throw NSError(domain: label, code: 1) }; checks += 1
    }
    static func rejects(_ label: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }
        throw NSError(domain: "accepted invalid: " + label, code: 1)
    }
    static func main() throws {
        let ref = Doc.TerminalReference(coreID: "core_123", terminalID: "t9")
        let pane = Doc.Pane(title: "한글😀", terminal: ref)
        let layout = Doc.Layout.split(axis: .horizontal, ratio: 0.4, first: .leaf(pane), second: .leaf(.init(terminal: ref)))
        let tab = Doc.Tab(name: "tab", layout: layout)
        let workspace = Doc.Workspace(name: "main", cwd: "/tmp/test cwd", tabs: [tab])
        let doc = try Doc(workspaces: [workspace]), empty = try Doc()
        let bytes = try doc.encoded()
        try check(try Doc.decode(bytes) == doc, "round trip, unicode, duplicate terminal views")
        try check(try Doc.decode(empty.encoded()) == empty, "explicit empty document")
        let json = String(decoding: bytes, as: UTF8.self)
        for excluded in ["focus", "zoom", "machineAlias", "credential", "lease"] {
            try check(!json.contains(excluded), "local/authority field not serialized: " + excluded)
        }
        try rejects("oversized wire") { _ = try Doc.decode(Data(repeating: 32, count: Doc.maximumBytes + 1)) }
        for raw in ["null", "[]", "{}", "{\"schemaVersion\":2,\"workspaces\":[]}",
                    "{\"schemaVersion\":true,\"workspaces\":[]}", "{\"schemaVersion\":1,\"workspaces\":[],\"focus\":1}"] {
            try rejects("schema/missing/unknown") { _ = try Doc.decode(Data(raw.utf8)) }
        }
        for fragment in ["\"tabs\":", "\"layout\":", "\"pane\":", "\"terminal\":"] {
            // Inject an unknown field on the enclosing object, not another schema version.
            let changed = json.replacingOccurrences(of: fragment, with: "\"futureField\":true," + fragment)
            try rejects("unknown nested field") { _ = try Doc.decode(Data(changed.utf8)) }
        }
        let repeated = Data("{\"schemaVersion\":1,\"workspaces\":[{\"id\":\"\(UUID())\",\"name\":\"x\",\"tabs\":[]}],\"workspaces\":[]}".utf8)
        let effective = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: repeated))
        try check(try Doc.decode(repeated) == Doc.decode(effective), "preflight and typed decode use the same effective object")
        try rejects("duplicate workspace") { _ = try Doc(workspaces: [workspace, workspace]) }
        try rejects("duplicate tab") { _ = try Doc(workspaces: [.init(name: "x", tabs: [tab, tab])]) }
        try rejects("duplicate pane") {
            _ = try Doc(workspaces: [.init(name: "x", tabs: [.init(name: "t", layout: .split(axis: .vertical, ratio: 0.5, first: .leaf(pane), second: .leaf(pane)))])])
        }
        for ratio in [0.0, 1, -1, .nan, .infinity] {
            try rejects("ratio") { _ = try Doc(workspaces: [.init(name: "x", tabs: [.init(name: "t", layout: .split(axis: .vertical, ratio: ratio, first: .leaf(.init()), second: .leaf(.init())))])]) }
        }
        for bad in ["", "alias/t1", "t 1", "t\u{0}1", String(repeating: "t", count: 257)] {
            try rejects("terminal ref") {
                _ = try Doc(workspaces: [.init(name: "w", tabs: [.init(name: "t", layout: .leaf(.init(terminal: .init(coreID: "c1", terminalID: bad))))])])
            }
        }
        try rejects("title utf8 bound") { _ = try Doc(workspaces: [.init(name: String(repeating: "😀", count: 257))]) }
        try rejects("cwd NUL") { _ = try Doc(workspaces: [.init(name: "w", cwd: "x\u{0}y")]) }
        try rejects("item bound") { _ = try Doc(workspaces: (0...Doc.maximumItems).map { .init(name: String($0)) }) }
        try rejects("encoded byte bound") { _ = try Doc(workspaces: (0..<1100).map { _ in .init(name: String(repeating: "x", count: 1024)) }) }
        var deep = Doc.Layout.leaf(.init())
        for _ in 1..<Doc.maximumDepth { deep = .split(axis: .vertical, ratio: 0.5, first: .leaf(.init()), second: deep) }
        let boundary = try Doc(workspaces: [.init(name: "w", tabs: [.init(name: "t", layout: deep)])])
        try check(try Doc.decode(boundary.encoded()) == boundary, "depth boundary")
        let tooDeep = Doc.Layout.split(axis: .vertical, ratio: 0.5, first: .leaf(.init()), second: deep)
        try rejects("local layout depth") { _ = try Doc(workspaces: [.init(name: "w", tabs: [.init(name: "t", layout: tooDeep)])]) }
        // Create nested untrusted JSON independently of the validated document constructor.
        let deepJSON = try JSONEncoder().encode(Doc.Workspace(name: "w", tabs: [.init(name: "t", layout: tooDeep)]))
        var wrapped = Data("{\"schemaVersion\":1,\"workspaces\":[".utf8); wrapped.append(deepJSON); wrapped.append(Data("]}".utf8))
        try rejects("wire layout depth") { _ = try Doc.decode(wrapped) }

        let epoch = UUID()
        var state = try CoreWorkspaceCAS(originCoreID: "core_123", epoch: epoch)
        try check(state.snapshot == nil && !state.canWrite, "unavailable is not empty")
        try rejects("subscribe before read") { _ = try state.beginRead() }
        try rejects("cannot overwrite unavailable") { _ = try state.beginWrite(empty) }
        try state.didSubscribe(coreID: "core_123", epoch: epoch)
        try rejects("wrong origin core") { try state.didSubscribe(coreID: "other-core", epoch: epoch) }
        let staleRead = try state.beginRead()
        try state.invalidate(epoch: epoch)
        try rejects("event invalidates pending read") { try state.accept(staleRead, version: 0, document: nil) }
        let missing = try state.beginRead(); try state.accept(missing, version: 0, document: nil)
        try check(state.snapshot != nil && state.snapshot?.document == nil && state.canWrite, "confirmed missing permits explicit create")
        let create = try state.beginWrite(doc)
        try rejects("one write at a time") { _ = try state.beginWrite(empty) }
        try rejects("no read races pending write") { _ = try state.beginRead() }
        try state.finish(create, result: .acknowledged(version: 1))
        try check(!state.canWrite && state.refreshRequired, "ack requires reread")
        let old = try state.beginRead()
        try rejects("read older than ack") { try state.accept(old, version: 0, document: nil) }
        let fresh = try state.beginRead(); try state.accept(fresh, version: 1, document: doc)
        try check(state.canWrite && state.snapshot?.document == doc, "refreshed snapshot")
        let write = try state.beginWrite(empty)
        try state.invalidate(epoch: epoch)
        try state.finish(write, result: .conflict)
        try check(!state.canWrite && state.snapshot?.document == doc && state.lastWriteResult == .conflict, "conflict retains old layout read-only")
        let latest = try state.beginRead(); try state.accept(latest, version: 2, document: empty)
        let uncertain = try state.beginWrite(doc)
        try state.finish(uncertain, result: .uncertain)
        try check(state.lastWriteResult == .uncertain && !state.canWrite, "lost reply not failed mutation")
        let unchanged = try state.beginRead(); try state.accept(unchanged, version: 2, document: empty)
        let nextWrite = try state.beginWrite(doc)
        let newEpoch = UUID(); state.reconnect(epoch: newEpoch)
        try check(!state.canWrite && state.lastWriteResult == .uncertain && state.snapshot?.version == 2, "reconnect invalidates write without blanking layout")
        try rejects("old epoch subscribe") { try state.didSubscribe(coreID: "core_123", epoch: epoch) }
        try rejects("old write reply") { try state.finish(nextWrite, result: .acknowledged(version: 3)) }
        try rejects("new subscription required") { _ = try state.beginRead() }
        try state.didSubscribe(coreID: "core_123", epoch: newEpoch)
        let failedRead = try state.beginRead(); try state.readFailed(failedRead)
        try check(state.snapshot?.document == empty && !state.canWrite, "read failure cannot clear saved document")
        let sameVersion = try state.beginRead()
        try rejects("same version different value") { try state.accept(sameVersion, version: 2, document: doc) }
        let largeVersion: UInt64 = 9_007_199_254_740_993
        let large = try state.beginRead(); try state.accept(large, version: largeVersion, document: doc)
        let largeWrite = try state.beginWrite(empty)
        struct Params: Decodable { let name: String; let version: UInt64 }
        let encoded = try JSONDecoder().decode(Params.self, from: largeWrite.parameters())
        try check(encoded.version == largeVersion && encoded.name == Doc.documentName, "exact UInt64 CAS and own namespace")
        try rejects("bad ack") { try state.finish(largeWrite, result: .acknowledged(version: 0)) }
        try check(!state.canWrite && state.lastWriteResult == .uncertain, "bad ack fail closed")
        let exhausted = try state.beginRead(); try state.accept(exhausted, version: UInt64.max, document: doc)
        try rejects("version overflow") { _ = try state.beginWrite(empty) }
        try codecEventsAndEdits(doc, empty: empty)
        let report = ["passed": true, "checks": checks, "network": false, "userCoreUsed": false] as [String: Any]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("PASS workspace schema/CAS: \(checks) checks")
    }
    static func codecEventsAndEdits(_ doc: Doc, empty: Doc) throws {
        let bytes = try doc.encoded(), raw = String(decoding: bytes, as: UTF8.self)
        let reply = Data("{\"version\":18446744073709551615,\"value\":\(raw)}".utf8)
        let decoded = try JSONDecoder().decode(CoreWorkspaceReadResult.self, from: reply)
        try check(decoded.version == UInt64.max && decoded.document == doc, "strict nested codec preserves outer UInt64")
        for bad in ["{\"version\":0}", "{\"version\":0,\"value\":{\"schemaVersion\":1,\"workspaces\":[],\"future\":true}}", "{\"version\":0,\"value\":[]}"] {
            try rejects("invalid nested doc result") { _ = try JSONDecoder().decode(CoreWorkspaceReadResult.self, from: Data(bad.utf8)) }
        }
        let missing = try JSONDecoder().decode(CoreWorkspaceReadResult.self, from: Data("{\"version\":9,\"value\":null}".utf8))
        try check(missing.version == 9 && missing.document == nil, "tombstone envelope")
        let huge = Data(("{\"version\":0,\"value\":{\"padding\":\"" + String(repeating: "x", count: Doc.maximumBytes + 1) + "\"}}").utf8)
        try rejects("bounded raw value capture") { _ = try JSONDecoder().decode(CoreWorkspaceReadResult.self, from: huge) }
        func notice(_ method: String, _ seq: UInt64, _ extra: String = "") -> Data {
            Data("{\"jsonrpc\":\"2.0\",\"method\":\"\(method)\",\"params\":{\(extra)\"seq\":\(seq)}}".utf8)
        }
        var events = CoreWorkspaceEvents(sequence: 0)
        try check(try !events.consume(notice("heartbeat", 0)).refresh, "quiet heartbeat")
        let change = "\"type\":\"doc\",\"data\":{\"name\":\"3rdr-workspace-v1\",\"version\":18446744073709551615},"
        let effect = try events.consume(notice("event", 1, change))
        try check(effect.refresh && effect.minimumVersion == UInt64.max, "event version exact")
        try check(try events.consume(notice("missed", 3)).refresh, "missed forces doc read")
        try check(try !events.consume(notice("event", 2, change)).refresh, "events below missed baseline ignored")
        try check(try !events.consume(notice("event", 4, "\"machine\":\"other\"," + change)).refresh, "remote doc not local doc")
        try check(try !events.consume(notice("event", 5, change.replacingOccurrences(of: "3rdr-workspace-v1", with: "other-doc"))).refresh, "other namespace ignored")
        try check(try events.consume(notice("heartbeat", 7)).refresh, "sequence gap triggers read")
        try check(try !events.consume(notice("event", 8, "\"type\":\"title\",\"data\":{\"version\":\"unrelated\"},")).refresh, "unrelated event data not decoded as document")
        try rejects("regressed heartbeat") { _ = try events.consume(notice("heartbeat", 1)) }
        try rejects("invalid event JSON") { _ = try events.consume(Data("!".utf8)) }
        let pane = Doc.Pane(), tab = Doc.Tab(name: "t", layout: .leaf(pane))
        let workspace = Doc.Workspace(name: "w", tabs: [tab])
        let initial = try CoreWorkspaceEdit.appendWorkspace(workspace).applying(to: empty)
        let renamed = try CoreWorkspaceEdit.renameWorkspace(workspace.id, "renamed").applying(to: initial)
        try check(renamed.workspaces[0].name == "renamed" && initial.workspaces[0].name == "w", "immutable rename")
        let sibling = Doc.Pane()
        let split = try CoreWorkspaceEdit.splitPane(pane.id, axis: .vertical, ratio: 0.5, newPane: sibling).applying(to: initial)
        let collapsed = try CoreWorkspaceEdit.removePane(sibling.id).applying(to: split)
        try check(collapsed == initial, "remove collapses only sibling split")
        let unbound = try CoreWorkspaceEdit.removePane(pane.id).applying(to: initial)
        try check(unbound.workspaces[0].tabs[0].layout == nil, "last pane leaves empty tab, no launch")
        let removed = try CoreWorkspaceEdit.removeTab(tab.id).applying(to: initial)
        try check(removed.workspaces[0].tabs.isEmpty, "layout-only remove tab")
        let ref = Doc.TerminalReference(coreID: "c1", terminalID: "t1")
        let bound = try CoreWorkspaceEdit.bindPane(pane.id, expected: nil, replacement: ref).applying(to: initial)
        try check(bound != initial, "explicit bind records reference")
        let renamedPane = try CoreWorkspaceEdit.renamePane(pane.id, "한글 name").applying(to: bound)
        try check(renamedPane.panes.first?.title == "한글 name" && renamedPane.panes.first?.terminal == ref
            && renamedPane.workspaces[0].tabs[0].name == "t", "pane rename preserves terminal and tab, no fabricated identity")
        let clearedPane = try CoreWorkspaceEdit.renamePane(pane.id, "").applying(to: renamedPane)
        try check(clearedPane == bound, "empty pane name restores automatic title")
        try rejects("missing pane rename") { _ = try CoreWorkspaceEdit.renamePane(UUID(), "x").applying(to: bound) }
        try rejects("oversized pane rename") { _ = try CoreWorkspaceEdit.renamePane(pane.id, String(repeating: "x", count: 1025)).applying(to: bound) }
        try rejects("bind precondition") { _ = try CoreWorkspaceEdit.bindPane(pane.id, expected: nil, replacement: ref).applying(to: bound) }
        try rejects("duplicate append") { _ = try CoreWorkspaceEdit.appendWorkspace(workspace).applying(to: initial) }
        try rejects("missing edit target") { _ = try CoreWorkspaceEdit.renameTab(UUID(), "x").applying(to: initial) }
        try rejects("edit retains ratio validation") { _ = try CoreWorkspaceEdit.splitPane(pane.id, axis: .vertical, ratio: 0, newPane: sibling).applying(to: initial) }
        let epoch = UUID(); var cas = try CoreWorkspaceCAS(originCoreID: "c1", epoch: epoch)
        try cas.didSubscribe(coreID: "c1", epoch: epoch); try cas.invalidate(epoch: epoch, minimumVersion: 5)
        let read = try cas.beginRead()
        try rejects("event floor rejects stale result") { try cas.accept(read, version: 4, document: empty) }
    }
}
