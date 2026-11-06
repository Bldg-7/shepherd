import Foundation

@main @MainActor private struct HcRecoveryPresentationTextTests {
    static func main() async throws {
        var n = 0
        func check(_ value: Bool, _ label: String) { precondition(value,label); n += 1 }
        let outcomes: [(CoreWorkspaceRecovery.Stop,String)] = [
            (.pending,"No stop dispatched"),(.inFlight,"Stop in flight — do not retry"),
            (.uncertain,"Stop unconfirmed — read/review only"),(.confirmed,"Ended confirmed"),
            (.shared,"Program retained: shared view"),(.foreign,"Program retained: different origin")]
        for (state,text) in outcomes {
            check(HcRecoveryPresentationText.stop(state) == text,"truthful per-target stop outcome")
        }
        let pane = CoreWorkspaceDocument.Pane(terminal:.init(coreID:"core",terminalID:"t1"))
        let tab = CoreWorkspaceDocument.Tab(name:"t",layout:.leaf(pane))
        let doc = try CoreWorkspaceDocument(workspaces:[.init(name:"w",tabs:[tab])])
        let journal = try CoreWorkspaceRecovery(coreID:"core",epoch:UUID(),persist:{ _ in })
        let ticket = try await journal.beginClose(paneID:pane.id,document:doc,endPrograms:true)
        let initial = await journal.snapshot()[0]
        check(HcRecoveryPresentationText.title(initial) == "Close pane","partial close is not labeled a tab removal")
        check(HcRecoveryPresentationText.explanation(initial,canApplyLayout:true).contains("only that view"),"partial layout explanation does not promise whole-tab action")
        let attempt = try await journal.prepareLayoutAfterReview(ticket,snapshot:.init(version:0,document:doc))!
        try await journal.finishLayout(attempt,result:.acknowledged(version:1))
        let pending = await journal.snapshot()[0]
        check(HcRecoveryPresentationText.explanation(pending,canApplyLayout:false).contains("outcomes remain unconfirmed"),"layout confirmed is not process ended")
        let full = try CoreWorkspaceRecovery(coreID:"core",epoch:UUID(),persist:{ _ in })
        let fullTicket = try await full.beginClose(tabID:tab.id,document:doc,endPrograms:false)
        check(HcRecoveryPresentationText.title(await full.snapshot()[0]) == "Close tab","full close title stays distinct")
        let fullAttempt = try await full.prepareLayoutAfterReview(fullTicket,snapshot:.init(version:0,document:doc))!
        try await full.finishLayout(fullAttempt,result:.acknowledged(version:1))
        check(HcRecoveryPresentationText.explanation(await full.snapshot()[0],canApplyLayout:false).contains("No program termination was requested"),"view-only history does not claim a stop")
        let empty = CoreWorkspaceDocument.Pane()
        let launchDoc = try CoreWorkspaceDocument(workspaces:[.init(name:"l",tabs:[.init(name:"l",layout:.leaf(empty))])])
        let launch = try CoreWorkspaceRecovery(coreID:"core",epoch:UUID(),persist:{ _ in })
        let launchTicket = try await launch.beginLaunch(paneID:empty.id,document:launchDoc)
        check(HcRecoveryPresentationText.explanation(await launch.snapshot()[0],canApplyLayout:false).contains("outcome is unknown"),"uncertain run is never described as failed or adoptable")
        try await launch.finishLaunch(launchTicket,terminal:pane.terminal)
        let launchAttempt = try await launch.prepareLayoutAfterReview(launchTicket,snapshot:.init(version:0,document:launchDoc))!
        try await launch.finishLayout(launchAttempt,result:.acknowledged(version:1))
        check(HcRecoveryPresentationText.explanation(await launch.snapshot()[0],canApplyLayout:false).contains("will not be restarted"),"known run layout receipt grants no replay")
        print("PASS recovery presentation: \(n) checks; pure descriptions, not physical UI or dispatch authority")
    }
}
