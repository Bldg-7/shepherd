import Foundation
import CoreGraphics

// Only an unrelated legacy enum needed to compile the production request's
// legacy initializer. Actual hc store, request, preview model and nodes used.
public nonisolated enum AgentKind: String, Sendable {
    case claude, codex, pi
    var supportsLegacySessionInspection: Bool { self != .pi }
}
private final class PreviewNoSecrets: MachineSecretStore {
    func saveSecret(_ data: Data, tag: String) throws { preconditionFailure("no credential write") }
    func loadSecret(tag: String) throws -> Data? { preconditionFailure("no credential read") }
    func deleteSecret(tag: String) throws { preconditionFailure("no credential delete") }
}
@main @MainActor private struct HcPanePresentationTests {
    static func main() async throws {
        var count = 0
        func check(_ b: Bool, _ text: String) { precondition(b,text); count += 1 }
        let epoch = UUID(), tab = UUID(), other = UUID()
        let a = CoreWorkspaceDocument.Pane(terminal:.init(coreID:"core",terminalID:"t1"))
        let b = CoreWorkspaceDocument.Pane(terminal:.init(coreID:"core",terminalID:"t2"))
        let machine = Machine(displayName:"Owned",hostname:"owned.invalid",username:"owned")
        let request = FilePreviewRequest(machine:machine,hcPaneID:a.id,terminalID:"t1",directory:"/owned",link:"a.md")
        let store = HcPanePresentationStore()
        let shared = store.entry(epoch:epoch,pane:a,tabID:tab)
        shared.open(request,from:a)
        let read = shared.previewModel
        read.showsSource = true; read.scrollOffset = CGPoint(x:0,y:70)
        read.find.query = "owned"
        check(store.entry(epoch:epoch,pane:b,tabID:tab) === shared,"tab mode keeps preview when focused child changes")
        check(store.entry(epoch:epoch,pane:a) !== shared,"pane and tab modes have independent preview state")
        let elsewhere = store.entry(epoch:epoch,pane:b,tabID:other)
        check(elsewhere.preview == nil,"another tab does not borrow preview")
        shared.expanded = true; store.collapsePreviews(epoch:epoch)
        let returned = store.entry(epoch:epoch,pane:b,tabID:tab)
        check(returned.preview?.id == request.id && returned.previewModel === read && !returned.expanded,"tab history comes back at side with its same read")
        check(read.showsSource && read.scrollOffset == CGPoint(x:0,y:70) && read.find.query == "owned","source, scroll and find survive selection")
        shared.hide()
        check(shared.preview?.id == request.id && !shared.isShown && shared.previewModel !== read,"close keeps file but retires old read")
        let fresh = shared.previewModel
        shared.show()
        check(shared.isShown && shared.previewModel === fresh && !fresh.showsSource && fresh.scrollOffset == nil,"show reads anew rather than reusing old file data")
        let next = request.following("next.md",directory:"/owned")
        shared.expanded = true
        shared.follow(next)
        check(shared.expanded,"following a file link within the expanded preview does not collapse it")
        check(shared.preview?.id == next.id && shared.previewModel !== fresh,"follow creates a new file read")
        func doc(_ panes:[CoreWorkspaceDocument.Pane],tabID:UUID = tab) throws -> CoreWorkspaceDocument {
            let layout: CoreWorkspaceDocument.Layout? = panes.reduce(nil) { current,pane in
                if let current { return .split(axis:.horizontal,ratio:0.5,first:current,second:.leaf(pane)) }
                return .leaf(pane)
            }
            return try .init(workspaces:[.init(name:"w",tabs:[.init(id:tabID,name:"t",layout:layout)])])
        }
        store.retain(epoch:epoch,document:try doc([b,a]))
        check(shared.preview != nil,"reordering leaves exact source reference valid")
        let renamed = CoreWorkspaceDocument.Pane(id:a.id,title:"New title",terminal:a.terminal)
        store.retain(epoch:epoch,document:try doc([renamed,b]))
        check(shared.preview != nil,"title is not preview authority")
        store.retain(epoch:epoch,document:nil)
        check(store.entry(epoch:epoch,pane:a,tabID:tab) === shared && shared.preview != nil,"unavailable metadata is not missing membership")
        let rebound = CoreWorkspaceDocument.Pane(id:a.id,terminal:.init(coreID:"foreign",terminalID:"t1"))
        store.retain(epoch:epoch,document:try doc([rebound,b]))
        check(shared.preview == nil && !shared.isShown,"same pane and terminal ID under another origin invalidate history")
        shared.open(request,from:a)
        store.retain(epoch:epoch,document:try doc([b]))
        check(shared.preview == nil,"removing source child invalidates tab preview")
        let before = store.entry(epoch:epoch,pane:a)
        before.open(request,from:a)
        store.retain(epoch:epoch,document:try doc([a],tabID:other))
        check(store.entry(epoch:epoch,pane:a) === before && before.preview != nil,"pane history survives a move while old tab history retires")
        store.retain(epoch:UUID(),document:nil)
        check(store.entry(epoch:epoch,pane:a) !== before,"epoch reset cannot restore old cached reads")
        let invalid = FilePreviewRequest(machine:machine,hcPaneID:b.id,terminalID:"t1",directory:nil,link:"bad.md")
        let guarded = HcPanePresentation(); guarded.open(invalid,from:a)
        check(guarded.preview == nil,"wrong source pane cannot open a preview")
        let small = HcPanePresentationStore(limit:1)
        let retained = small.entry(epoch:epoch,pane:a); retained.open(request,from:a)
        let overflow = small.entry(epoch:epoch,pane:b)
        check(!overflow.historyIsRetained && small.entry(epoch:epoch,pane:b) === overflow,"full history retains stable current presentation with explicit warning")
        check(small.entry(epoch:epoch,pane:a) === retained,"overflow never silently evicts visited history")
        check(small.entry(epoch:epoch,pane:b) !== overflow,"leaving transient preview retires only unretained history")
        let replacementEpoch = UUID()
        check(small.entry(epoch:replacementEpoch,pane:a).historyIsRetained,"new epoch cannot inherit a previous scope's capacity pressure")
        small.retain(epoch:nil,document:nil)
        check(small.entry(epoch:epoch,pane:a) !== retained,"scope retirement removes retained and transient entries")
        let gone = small.entry(epoch:epoch,pane:a)
        small.retain(epoch:epoch,document:nil,missingDocumentConfirmed:true)
        check(small.entry(epoch:epoch,pane:a) !== gone,"confirmed missing document retires history rather than treating it as unavailable")
        let files = URL(fileURLWithPath:CommandLine.arguments[1])
        let file = files.appending(path:"owned-preview.txt")
        try Data("first owned read".utf8).write(to:file)
        let suite = "owned-hc-preview-" + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let local = Machine(displayName:"Owned local",hostname:"localhost",username:"owned",isLocal:true)
        let machines = MachineStore(defaults:defaults,localMachine:local,keychain:PreviewNoSecrets())
        let localRequest = FilePreviewRequest(machine:local,hcPaneID:a.id,terminalID:"t1",directory:files.path,link:"owned-preview.txt")
        let reading = HcPanePresentation(); reading.open(localRequest,from:a)
        func contents(_ model: FilePreviewModel) -> String? {
            if case .loaded(let document) = model.state, case .text(let value,_) = document.content { return value }
            return nil
        }
        await reading.previewModel.loadIfNeeded(localRequest,store:machines)
        check(contents(reading.previewModel) == "first owned read","actual local reader loads owned file")
        let previousRead = reading.previewModel
        reading.hide()
        try Data("second owned read".utf8).write(to:file)
        reading.show()
        await reading.previewModel.loadIfNeeded(reading.preview!,store:machines)
        check(reading.previewModel !== previousRead && contents(reading.previewModel) == "second owned read","hide/show retained request performs a new actual file read")
        print("PASS hc preview history: \(count) checks; actual request/model/store/owned file reader; no credential/network/UI actions")
    }
}
