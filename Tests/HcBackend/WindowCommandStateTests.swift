import Foundation
import Combine
import Darwin

@main @MainActor private struct WindowCommandStateTests {
    static func main() {
        do { try run() } catch { print("FAIL command owner: \(error)"); exit(1) }
    }
    static func run() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws { guard value else { throw NSError(domain:name,code:1) }; checks += 1 }
        let state = HcWindowCommandState(), a = UUID(), b = UUID()
        var values: [Bool?] = [], oldCalls = 0, newCalls = 0
        let subscription = state.$actions.sink { values.append($0?.canLaunch) }
        defer { subscription.cancel() }
        func actions(_ enabled: Bool, old: Bool) -> HcWindowActions {
            let call: () -> Void = { if old { oldCalls += 1 } else { newCalls += 1 } }
            return HcWindowActions(canLaunch:enabled,canClose:enabled,canSwitch:enabled,canSettings:enabled,
                closeTitle:"Close Tab View",launch:call,close:call,switcher:call,settings:call)
        }
        try check(!state.perform(.launch),"no owner cannot dispatch")
        state.claim(a,actions:actions(false,old:true))
        try check(state.actions?.canLaunch == false,"initial disabled snapshot")
        try check(!state.perform(.launch),"disabled owner cannot dispatch")
        state.update(a,actions:actions(true,old:true))
        try check(state.actions?.canLaunch == true && values.count == 3,"publisher emits updated command values")
        state.update(b,actions:actions(false,old:false));state.release(b)
        try check(state.actions?.canLaunch == true && values.count == 3,"other owner's update/release ignored")
        try check(state.perform(.launch) && oldCalls == 1,"current enabled owner dispatches once")
        state.claim(b,actions:actions(false,old:false))
        state.update(a,actions:actions(true,old:true));state.release(a)
        try check(state.actions?.canLaunch == false,"stale owner cannot overwrite replacement")
        try check(!state.perform(.close) && oldCalls == 1 && newCalls == 0,"stale/disabled menu invocation does not call old closure")
        state.update(b,actions:actions(true,old:false))
        for action in [HcWindowCommandState.Action.launch,.close,.switcher,.settings] { try check(state.perform(action),"enabled action dispatch") }
        try check(oldCalls == 1 && newCalls == 4,"all actions route to current owner")
        state.release(b)
        try check(state.actions == nil && !state.perform(.settings),"release retires command actions")
        try check(values.count == 6 && values.last! == nil,"publisher includes replacement/update/retirement")
        var blank = 0, current = 0
        let distinct = HcWindowActions(canLaunch:true,canClose:false,canSwitch:false,canSettings:false,
            closeTitle:"Close Tab",launch:{ blank += 1 },close:{},switcher:{},settings:{},launchCurrentWorkspace:{ current += 1 })
        state.claim(a,actions:distinct)
        try check(state.perform(.launch) && blank == 1 && current == 0,"CmdN retains blank launcher intent")
        try check(state.perform(.launchCurrentWorkspace) && blank == 1 && current == 1,"CmdT preserves current-workspace intent without fake target")
        state.release(a)
        try check(!state.perform(.launchCurrentWorkspace),"retired current-workspace command cannot dispatch")
        print("PASS explicit command publication/ownership: \(checks) checks")
    }
}
