import Foundation

@main @MainActor private struct HcWorkspaceItemDragTests {
    static func main() throws {
        typealias Doc = CoreWorkspaceDocument
        let core = "core_one", version: UInt64 = 17
        let terminal = Doc.TerminalReference(coreID:core,terminalID:"t1")
        let pane = Doc.Pane(title:"real pane",terminal:terminal)
        let placeholder = Doc.Pane()
        let tab = Doc.Tab(name:"real tab",layout:.split(axis:.horizontal,ratio:0.5,first:.leaf(pane),second:.leaf(placeholder)))
        let doc = try Doc(workspaces:[.init(name:"owned",tabs:[tab])])
        let empty = try Doc()
        let row = HcWorkspaceRowReference(kind:.pane,id:pane.id,coreID:core,version:version,terminal:terminal)
        let tabRow = HcWorkspaceRowReference(kind:.tab,id:tab.id,coreID:core,version:version,terminal:nil)
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain:label,code:1) }; checks += 1
        }
        try check(row.text == pane.id.uuidString,"real metadata UUID, not fabricated legacy identity")
        try check(row.pasteText(row.text,coreID:core,version:version,document:doc) == row.text+" ","pane reference and one trailing space, never Return")
        try check(tabRow.pasteText(tabRow.text,coreID:core,version:version,document:doc) == tabRow.text+" ","tab metadata UUID")
        for text in ["t1","w1:p4",row.text+" ",row.text+"\n",row.text+"\u{1b}","\u{1b}[201~",UUID().uuidString,""] {
            try check(row.pasteText(text,coreID:core,version:version,document:doc) == nil,"unmarked/mismatched/control text rejected")
        }
        for origin in ["", "core_two", "alias"] {
            try check(row.pasteText(row.text,coreID:origin,version:version,document:doc) == nil,"other origin rejected")
        }
        for revision in [UInt64(0),16,18,UInt64.max] {
            try check(row.pasteText(row.text,coreID:core,version:revision,document:doc) == nil,"different exact revision rejected")
        }
        try check(row.pasteText(row.text,coreID:core,version:version,document:empty) == nil,"removed pane rejected")
        try check(tabRow.pasteText(tabRow.text,coreID:core,version:version,document:empty) == nil,"removed tab rejected")
        let replacement = try CoreWorkspaceEdit.bindPane(pane.id,expected:terminal,replacement:.init(coreID:core,terminalID:"t2")).applying(to:doc)
        try check(row.pasteText(row.text,coreID:core,version:version,document:replacement) == nil,"changed terminal reference rejected even at same supplied revision")
        let foreign = try CoreWorkspaceEdit.bindPane(pane.id,expected:terminal,replacement:.init(coreID:"core_two",terminalID:"t1")).applying(to:doc)
        try check(tabRow.pasteText(tabRow.text,coreID:core,version:version,document:foreign) == nil,"tab containing foreign terminal rejected")
        let foreignPane = HcWorkspaceRowReference(kind:.pane,id:pane.id,coreID:core,version:version,terminal:.init(coreID:"core_two",terminalID:"t1"))
        try check(foreignPane.pasteText(foreignPane.text,coreID:core,version:version,document:foreign) == nil,"foreign pane is not local metadata input")
        let pending = HcWorkspaceRowReference(kind:.pane,id:placeholder.id,coreID:core,version:version,terminal:nil)
        try check(pending.pasteText(pending.text,coreID:core,version:version,document:doc) == pending.text+" ","placeholder still has a real metadata ID")
        let malformedTab = HcWorkspaceRowReference(kind:.tab,id:tab.id,coreID:core,version:version,terminal:terminal)
        try check(malformedTab.pasteText(malformedTab.text,coreID:core,version:version,document:doc) == nil,"malformed tab reference rejected")
        print("PASS workspace row-reference policy: \(checks) checks; not a physical drag/UI qualification")
    }
}
