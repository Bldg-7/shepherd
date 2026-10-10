import Foundation

@main struct PiRouteLeaseTests {
    @MainActor static func main() throws {
        let registry = CDPRouteLeases()
        let base = CDPRoute("/v1/herdr/owned/pane/w1:p1")!
        let other = CDPRoute("/v1/herdr/owned/pane/w1:p2")!
        precondition(registry.permits(base, terminalID: "t1"))
        var live = true
        let claim = try registry.claim(base, terminalID: "t1", authorize: { live })
        precondition(!registry.permits(base, terminalID: "t1"))
        let first = try registry.open(claim)
        precondition(registry.permits(first, terminalID: "t1"))
        precondition(!registry.permits(first, terminalID: "different"))
        precondition(registry.permits(other, terminalID: "t2"))
        precondition(CDPRoute(first.versionedPath) == first)
        live = false
        precondition(!registry.permits(first, terminalID: "t1")) // no sweep/timer needed
        live = true
        precondition(CDPRoute(base.basePath + "/lease/../") == nil)
        precondition(CDPRoute(base.basePath + "/lease/00000000-0000-4000-8000-00000000000A") == nil)
        precondition(CDPRoute(first.versionedPath + "?token=anything") == nil)
        registry.revoke(first)
        precondition(!registry.permits(first, terminalID: "t1") && !registry.permits(base, terminalID: "t1"))
        let second = try registry.open(claim)
        precondition(second != first && registry.permits(second, terminalID: "t1"))
        registry.revoke(first) // late old retirement cannot revoke a replacement
        precondition(registry.permits(second, terminalID: "t1"))
        registry.retire(claim)
        precondition(!registry.permits(second, terminalID: "t1") && !registry.permits(base, terminalID: "t1"))
        do { _ = try registry.open(claim); preconditionFailure("retired claim reopened") } catch {}
        try registry.release(claim)
        precondition(registry.permits(base, terminalID: "t1"))
        precondition(!registry.permits(first, terminalID: "t1") && !registry.permits(second, terminalID: "t1"))
        print("PASS route claims: terminal binding, revoke-before-detach admission, no legacy fallback, stale revoke, replay, release")
    }
}
