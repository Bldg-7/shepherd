import Foundation

@main @MainActor private struct HcSwitcherCandidateTests {
    static func main() throws {
        var n = 0
        func check(_ condition: Bool, _ label: String) { precondition(condition,label); n += 1 }
        func record(_ address: String, state: String = "live", name: String? = nil) throws -> HcTerminalRecord {
            var value: [String:Any] = ["address":address,"state":state,"created_ms":1]
            if let name { value["name"] = name }
            return try JSONDecoder().decode(HcTerminalRecord.self,from:JSONSerialization.data(withJSONObject:value))
        }
        let a = try record("t1"), b = try record("t2"), ended = try record("t3",state:"finished")
        let routed = try record("peer/t4"), alias = try record("my-terminal",name:"t5")
        let pane = CoreWorkspaceDocument.Pane(terminal:.init(coreID:"core",terminalID:"t1"))
        let doc = try CoreWorkspaceDocument(workspaces:[.init(name:"main",tabs:[.init(name:"placed",layout:.leaf(pane))])])
        func ids(_ records: [HcTerminalRecord], core: String = "core", document: CoreWorkspaceDocument? = nil,
                 available: Bool = true) -> [String] {
            HcWorkspaceSwitcherCandidates.unplaced(records,coreID:core,document:document,snapshotAvailable:available).map(\.address)
        }
        check(ids([a,b],document:doc) == ["t2"],"only canonical unplaced records")
        check(ids([a,b]) == ["t1","t2"],"known missing document is discoverable, not unavailable")
        check(ids([a,b],available:false).isEmpty,"unavailable metadata never becomes empty/adoptable")
        check(ids([a,b],document:doc,available:false).isEmpty,"stale document does not authorize attachment")
        check(ids([a,b],core:"").isEmpty,"unknown origin is unavailable")
        check(ids([ended,routed,alias]).isEmpty,"finished/remote-qualified/mutable-name selectors refused")
        check(ids([b,b]).isEmpty,"ambiguous duplicate canonical record refused")
        check(ids([a,b,b]) == ["t1"],"ambiguity does not invent another selector")
        let foreign = try CoreWorkspaceDocument(workspaces:[.init(name:"elsewhere",tabs:[.init(name:"other",layout:.leaf(.init(terminal:.init(coreID:"other",terminalID:"t1"))))])])
        check(ids([a,b],document:foreign) == ["t1","t2"],"another origin's same terminal ID does not hide local records")
        check(ids([try record("t2",name:"t1")],document:doc) == ["t2"],"labels/names are never adoption identity")
        check(ids(Array(repeating:a,count:4097)).isEmpty,"bounded candidate list")
        check(HcWorkspaceSwitcherTarget.pane(pane.id) != .terminal(pane.id.uuidString),"typed UI choices never fabricate legacy pane identity")
        print("PASS switcher candidate policy: \(n) checks; no terminal mutation or GUI approval")
    }
}
