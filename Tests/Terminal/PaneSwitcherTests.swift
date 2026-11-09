import SwiftUI

@main @MainActor enum PaneSwitcherTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
    static func main() {
        let oldChoice = WorkspaceSwitcherItem(id:"old",title:"Old",location:"owned",searchTerms:[],hasAgent:false,isAvailable:true)
        let searched = WorkspaceSwitcherItem(id:"searched",title:"Searched",location:"owned",searchTerms:[],hasAgent:false,isAvailable:true)
        let disabled = WorkspaceSwitcherItem(id:"disabled",title:"Disabled",location:"owned",searchTerms:[],hasAgent:false,isAvailable:false)
        check(WorkspaceSwitcherItem.submitted(in:[searched],highlightedID:oldChoice.id)?.id == searched.id,"Return resolves current search results before asynchronous highlight reconciliation")
        check(WorkspaceSwitcherItem.submitted(in:[disabled,searched],highlightedID:disabled.id)?.id == searched.id,"stale or disabled highlight never selects unavailable choice")
        check(WorkspaceSwitcherItem.submitted(in:[oldChoice,searched],highlightedID:searched.id)?.id == searched.id,"explicit current highlight remains selected")
        check(WorkspaceSwitcherItem.submitted(in:[disabled],highlightedID:nil) == nil,"no available result never broadens selection")
        print("PASS \(checks) switcher Return/stale highlight/disabled choice checks; snapshots only, no network")
    }
}
