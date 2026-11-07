import Foundation
import AgentProxyProtocol

@main @MainActor private struct HcCaptureRouteJournalTests {
    private enum Injected: Error { case write }
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value,message); checks += 1 }
        func rejected(_ action: () throws -> Void) { do { try action(); preconditionFailure("replay/invalid mutation admitted") } catch { checks += 1 } }
        let intent = try AgentProxyHcCaptureIntent(originCoreID:"core-A",launchID:UUID(),paneID:UUID())
        let state = try AgentProxyHcRouteState(kind:.claude,intent:intent,cliVersion:"fixture")
        var saved: Data?, writes = 0
        let journal = try HcCaptureRouteJournal(restoring:nil,persist:{ saved = $0; writes += 1 })
        check(try journal.snapshot().isEmpty,"new store begins empty")
        let created = try journal.create(state)
        check(writes == 1 && saved != nil,"creation acknowledges storage before returning token")
        check(try journal.lookup(token:created.token)?.state == state,"token maps only to exact pending intent")
        let text = String(decoding:saved!,as:UTF8.self)
        check(!text.contains(created.token) && text.contains(created.entry.tokenSHA256),"persist only token hash, never the capability")
        rejected { _ = try journal.create(state) }
        let aliasPane = try AgentProxyHcCaptureIntent(originCoreID:intent.originCoreID,launchID:intent.launchID,paneID:UUID())
        rejected { _ = try journal.create(AgentProxyHcRouteState(kind:.codex,intent:aliasPane,cliVersion:"fixture")) }
        let other = try AgentProxyHcCaptureIntent(originCoreID:"core-B",launchID:UUID(),paneID:intent.paneID)
        let wrong = try AgentProxyHcCaptureBinding(intent:other,receiptOriginCoreID:"core-B",terminalID:"t1")
        rejected { try journal.bind(routeID:created.entry.routeID,received:wrong) }
        check(writes == 1,"rejected intent never writes")
        let bound = try AgentProxyHcCaptureBinding(intent:intent,receiptOriginCoreID:"core-A",terminalID:"t1")
        try journal.bind(routeID:created.entry.routeID,received:bound)
        let published = try journal.lookup(token:created.token)?.state.binding
        check(writes == 2 && published == bound,"exact receipt bind persists once")
        rejected { try journal.bind(routeID:created.entry.routeID,received:bound) }
        let restored = try HcCaptureRouteJournal(restoring:saved,persist:{ _ in })
        check(try restored.lookup(token:created.token)?.state.binding == bound,"restart restores explicit bound metadata")
        var oldEncoding = try JSONSerialization.jsonObject(with:saved!) as! [String:Any]
        var oldEntries = oldEncoding["entries"] as! [[String:Any]];oldEntries[0].removeValue(forKey:"oauthRejected");oldEncoding["entries"] = oldEntries
        let oldRestored = try HcCaptureRouteJournal(restoring:JSONSerialization.data(withJSONObject:oldEncoding),persist:{ _ in })
        check(try oldRestored.snapshot().first?.oauthRejected == false,"older staged journal lacks rejection flag without changing its binding")
        try journal.markRejected(routeID:created.entry.routeID)
        let rejectWrites = writes
        try journal.markRejected(routeID:created.entry.routeID)
        check(writes == rejectWrites,"repeated subscription rejection never rewrites or rebinds a route")
        let rejectedReload = try HcCaptureRouteJournal(restoring:saved,persist:{ _ in })
        check(try rejectedReload.snapshot().first?.oauthRejected == true,"subscription rejection persists across explicit reconstruction")
        check(try rejectedReload.lookup(token:created.token)?.state.binding == bound,"subscription rejection does not mutate terminal provenance")
        let countBeforeRemove = writes
        try journal.remove(routeID:created.entry.routeID)
        let emptyAfterRemove = try journal.snapshot().isEmpty
        check(writes == countBeforeRemove + 1 && emptyAfterRemove,"removal commits then publishes")
        check(try journal.lookup(token:created.token) == nil,"removed route cannot resolve")
        rejected { try journal.remove(routeID:created.entry.routeID) }
        check(try journal.lookup(token:"bad") == nil,"malformed token is not adopted")
        var uncertain: Data?
        let failed = try HcCaptureRouteJournal(restoring:nil,persist:{ uncertain = $0; throw Injected.write })
        rejected { _ = try failed.create(state) }
        rejected { _ = try failed.snapshot() }
        rejected { _ = try failed.lookup(token:created.token) }
        rejected { _ = try failed.create(state) }
        let afterUncertain = try HcCaptureRouteJournal(restoring:uncertain,persist:{ _ in })
        rejected { _ = try afterUncertain.create(state) }
        check(try afterUncertain.snapshot().count == 1,"explicit restart sees post-commit failure without creating another route")
        rejected { _ = try HcCaptureRouteJournal(restoring:Data("{}".utf8),persist:{ _ in }) }
        var bad = try JSONSerialization.jsonObject(with:uncertain!) as! [String:Any]
        bad["schemaVersion"] = 9
        rejected { _ = try HcCaptureRouteJournal(restoring:JSONSerialization.data(withJSONObject:bad),persist:{ _ in }) }
        bad["schemaVersion"] = 1; bad["entries"] = (bad["entries"] as! [[String:Any]]) + (bad["entries"] as! [[String:Any]])
        rejected { _ = try HcCaptureRouteJournal(restoring:JSONSerialization.data(withJSONObject:bad),persist:{ _ in }) }
        var bindSaved: Data?, failBind = false
        let bindFailure = try HcCaptureRouteJournal(restoring:nil,persist:{ bindSaved = $0; if failBind { throw Injected.write } })
        let beforeBind = try bindFailure.create(state); failBind = true
        rejected { try bindFailure.bind(routeID:beforeBind.entry.routeID,received:bound) }
        rejected { _ = try bindFailure.lookup(token:beforeBind.token) }
        let afterBindFailure = try HcCaptureRouteJournal(restoring:bindSaved,persist:{ _ in })
        check(try afterBindFailure.snapshot().first?.state.binding == bound,"restart observes possibly committed bind, never guesses pending")
        rejected { try afterBindFailure.bind(routeID:beforeBind.entry.routeID,received:bound) }
        var removeSaved: Data?, failRemove = false
        let removeFailure = try HcCaptureRouteJournal(restoring:nil,persist:{ removeSaved = $0; if failRemove { throw Injected.write } })
        let beforeRemove = try removeFailure.create(state); failRemove = true
        rejected { try removeFailure.remove(routeID:beforeRemove.entry.routeID) }
        rejected { _ = try removeFailure.snapshot() }
        let afterRemoveFailure = try HcCaptureRouteJournal(restoring:removeSaved,persist:{ _ in })
        check(try afterRemoveFailure.snapshot().isEmpty,"restart observes possibly committed remove without resurrecting route")
        rejected { try afterRemoveFailure.remove(routeID:beforeRemove.entry.routeID) }
        var capacity = try JSONSerialization.jsonObject(with:uncertain!) as! [String:Any]
        capacity["entries"] = Array(repeating:(capacity["entries"] as! [[String:Any]])[0],count:513)
        rejected { _ = try HcCaptureRouteJournal(restoring:JSONSerialization.data(withJSONObject:capacity),persist:{ _ in }) }
        let root = CommandLine.arguments[1]
        let directory = try StateDirectory.prepare(root + "/owned-ledger")
        let disk = try HcCaptureRouteJournal(directory:directory)
        let real = try disk.create(state)
        let diskReloaded = try HcCaptureRouteJournal(directory:directory)
        check(try diskReloaded.lookup(token:real.token)?.state == state,"actual atomic/fsynced file restores pending state")
        let attributes = try FileManager.default.attributesOfItem(atPath:directory.url(HcCaptureRouteJournal.filename))
        check((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,"actual ledger file is private")
        print("PASS \(checks) durable hc capture route journal checks; no proxy/listener/CLI launch")
    }
}
