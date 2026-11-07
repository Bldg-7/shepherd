import Foundation

@main @MainActor private struct HcCaptureScopeTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value,message); checks += 1 }
        func rejected(_ action: () throws -> Void) { do { try action(); preconditionFailure("invalid scope admitted") } catch { checks += 1 } }
        let launch = UUID(), pane = UUID()
        let a = try AgentProxyHcCaptureIntent(originCoreID:"core-A",launchID:launch,paneID:pane)
        let b = try AgentProxyHcCaptureIntent(originCoreID:"core-B",launchID:launch,paneID:pane)
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let encoded = try encoder.encode(a)
        check(try decoder.decode(AgentProxyHcCaptureIntent.self,from:encoded) == a,"explicit hc scope roundtrips")
        var object = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        check(Set(object.keys) == ["kind","schemaVersion","originCoreID","launchID","paneID"],"intent contains no fake legacy/terminal/native/secret identity")
        for key in ["session","herdrSession","terminalID"] {
            var poisoned = object; poisoned[key] = "t1"
            rejected { _ = try decoder.decode(AgentProxyHcCaptureIntent.self,from:JSONSerialization.data(withJSONObject:poisoned)) }
        }
        object["schemaVersion"] = 2
        rejected { _ = try decoder.decode(AgentProxyHcCaptureIntent.self,from:JSONSerialization.data(withJSONObject:object)) }
        object["schemaVersion"] = 1; object["kind"] = "herdr"
        rejected { _ = try decoder.decode(AgentProxyHcCaptureIntent.self,from:JSONSerialization.data(withJSONObject:object)) }
        for invalid in [""," ","alias/core","core\n","한글","é",String(repeating:"x",count:257)] {
            rejected { _ = try AgentProxyHcCaptureIntent(originCoreID:invalid,launchID:launch,paneID:pane) }
        }
        _ = try AgentProxyHcCaptureIntent(originCoreID:String(repeating:"x",count:256),launchID:launch,paneID:pane)
        checks += 1
        rejected { _ = try AgentProxyHcCaptureBinding(intent:a,receiptOriginCoreID:b.originCoreID,terminalID:"t1") }
        let boundA = try AgentProxyHcCaptureBinding(intent:a,receiptOriginCoreID:a.originCoreID,terminalID:"t1")
        let boundB = try AgentProxyHcCaptureBinding(intent:b,receiptOriginCoreID:b.originCoreID,terminalID:"t1")
        check(boundA != boundB && Set([boundA,boundB]).count == 2,"same canonical terminal on different origins never shares capture identity")
        check(try decoder.decode(AgentProxyHcCaptureBinding.self,from:encoder.encode(boundA)) == boundA,"bound value roundtrips without claiming receipt/native authority")
        for bad in ["","t0","t01","alias/t1","t1/foo","t1a","t9zzzzzzz",String(repeating:"t",count:100)] {
            rejected { _ = try AgentProxyHcCaptureBinding(intent:a,receiptOriginCoreID:a.originCoreID,terminalID:bad) }
        }
        var route = try AgentProxyHcRouteState(kind:.claude,intent:a,cliVersion:"2.1.fixture")
        check(route.binding == nil,"pending route has no fabricated terminal identity")
        let pendingObject = try JSONSerialization.jsonObject(with:encoder.encode(route)) as! [String:Any]
        check(pendingObject["binding"] == nil && pendingObject["session"] == nil && pendingObject["terminalID"] == nil,"pending wire state cannot masquerade as a legacy/bound route")
        check(try decoder.decode(AgentProxyHcRouteState.self,from:encoder.encode(route)) == route,"pending state roundtrips")
        rejected { try route.bind(boundB) }
        check(route.binding == nil,"foreign origin rejection leaves state unchanged")
        let later = try AgentProxyHcCaptureIntent(originCoreID:a.originCoreID,launchID:UUID(),paneID:pane)
        let unrelated = try AgentProxyHcCaptureBinding(intent:later,receiptOriginCoreID:a.originCoreID,terminalID:"t1")
        rejected { try route.bind(unrelated) }
        check(route.binding == nil,"same terminal and origin never adopt a different launch nonce")
        try route.bind(boundA)
        check(route.binding == boundA,"exact intent binds one known canonical target")
        rejected { try route.bind(boundA) }
        check(try decoder.decode(AgentProxyHcRouteState.self,from:encoder.encode(route)) == route,"bound state roundtrips")
        var wrong = pendingObject; wrong["binding"] = try JSONSerialization.jsonObject(with:encoder.encode(unrelated))
        rejected { _ = try decoder.decode(AgentProxyHcRouteState.self,from:JSONSerialization.data(withJSONObject:wrong)) }
        for version in ["bad\nversion",String(repeating:"x",count:65)] {
            rejected { _ = try AgentProxyHcRouteState(kind:.codex,intent:a,cliVersion:version) }
        }
        let alphabet = Array("0123456789bcdfghjkmnpqrstvwxyzab/é".map(String.init))
        var seed: UInt64 = 117
        for i in 0..<6000 {
            seed = seed &* 6364136223846793005 &+ 1
            var value = "t" + String((seed >> 32) % 10)
            for n in 0..<(i % 10) { value += alphabet[Int((seed >> (n * 3 % 48)) % UInt64(alphabet.count))] }
            check(AgentProxyHcCaptureBinding.isCanonicalTerminal(value) == CoreTerminalID.isCanonical(value),"wire validation stays in parity with actual SDK terminal rule")
        }
        let legacy = AgentProxyRouteCreate(kind:.claude,session:"legacy-session",paneID:"9",terminalID:"legacy-terminal",cliVersion:"fixture")
        check(try decoder.decode(AgentProxyRouteCreate.self,from:encoder.encode(legacy)) == legacy,"legacy archive/control values are not silently converted into hc identity")
        print("PASS \(checks) hc capture scope syntax/origin/legacy compatibility checks; no proxy/CLI/native-session dispatch")
    }
}
