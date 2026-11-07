import Foundation
import AgentProxyCore
import AgentProxyProtocol

struct HcConversationNamespaceTests {
    static func run(check: (Bool,String) -> Void) throws {
        let a = ConversationOrigin(hcCoreID:"core-A")!, b = ConversationOrigin(hcCoreID:"core-B")!
        let old = ConversationOrigin(herdrSession:"core-A")!
        check(a != b && a != old,"hc core and legacy archive namespaces cannot merge")
        check(ConversationOrigin(hcCoreID:"alias/core") == nil,"route aliases are not hc capture origins")
        check(ConversationOrigin(herdrSession:"é") != ConversationOrigin(herdrSession:"e\u{301}"),"legacy opaque namespace remains byte exact")
        let keyA = ConversationKey(agent:"claude",origin:a,nativeSession:"same-native")!
        let keyB = ConversationKey(agent:"claude",origin:b,nativeSession:"same-native")!
        let keyOld = ConversationKey(agent:"claude",origin:old,nativeSession:"same-native")!
        check(Set([keyA,keyB,keyOld]).count == 3,"identical native IDs on two cores and old archive stay distinct")
        check(keyA.herdrSession == nil && keyA.hcCoreID == "core-A","hc key never invents a legacy session")
        let intentA = try AgentProxyHcCaptureIntent(originCoreID:"core-A",launchID:UUID(),paneID:UUID())
        let intentB = try AgentProxyHcCaptureIntent(originCoreID:"core-B",launchID:UUID(),paneID:UUID())
        var routeA = try AgentProxyHcRouteState(kind:.claude,intent:intentA,cliVersion:"fixture")
        let routeB = try AgentProxyHcRouteState(kind:.claude,intent:intentB,cliVersion:"fixture")
        let pending = ConversationContext(routeID:"route-A",hc:routeA)!
        check(pending.terminalID == nil && pending.hc?.intent == intentA,"pending conversation has explicit launch origin and no terminal association")
        var store = ConversationStore()
        let created = try store.upsert(key:keyA,context:pending,items:[],status:.complete)
        _ = try store.upsert(key:keyB,context:ConversationContext(routeID:"route-B",hc:routeB)!,items:[],status:.complete)
        check(store.count == 2,"same native ID is separately admitted per actual hc namespace")
        let before = store.sequence
        do { _ = try store.upsert(key:keyA,context:ConversationContext(routeID:"wrong",hc:routeB)!,items:[],status:.complete);check(false,"foreign context accepted") }
        catch { check(store.sequence == before && store.count == 2,"wrong-origin context rejected before mutation/eviction") }
        do { _ = try store.upsert(key:keyOld,context:pending,items:[],status:.complete);check(false,"hc context attached to legacy") }
        catch { check(store.sequence == before,"legacy/hc context mismatch fails closed") }
        try routeA.bind(AgentProxyHcCaptureBinding(intent:intentA,receiptOriginCoreID:"core-A",terminalID:"t1"))
        let updated = try store.upsert(key:keyA,context:ConversationContext(routeID:"route-A",hc:routeA)!,items:[],status:.complete)
        check(updated.conversationID == created.conversationID && store.read(key:keyA)?.summary.context.terminalID == "t1","known receipt updates context without changing stable native/core key")
        let headers = [["content-type","application/json"],["x-claude-code-request-class","main"],["x-claude-code-session-id","shared-native"],["x-claude-code-agent-id","root"]]
        let openA = AgentProxyTeeFrame.Open(routeID:"capture-A",upstream:"anthropic",method:"POST",path:"/v1/messages",headers:headers,hcRouteIdentity:routeA)
        let openB = AgentProxyTeeFrame.Open(routeID:"capture-B",upstream:"anthropic",method:"POST",path:"/v1/messages",headers:headers,hcRouteIdentity:routeB)
        let request = Data("{\"messages\":[{\"role\":\"user\",\"content\":\"private fixture\"}]}".utf8)
        let classifiedA = RequestClassification.classify(openA,body:request), classifiedB = RequestClassification.classify(openB,body:request)
        check(classifiedA.kind == .main && classifiedA.mainConversationKey?.hcCoreID == "core-A","actual hc tee metadata classifies explicit MAIN in its core namespace")
        check(classifiedB.kind == .main && classifiedB.context?.terminalID == nil && classifiedA.mainConversationKey != classifiedB.mainConversationKey,"pending metadata captures without forging a terminal or merging native IDs")
        let legacy = AgentProxyRouteCreate(kind:.claude,session:"core-A",paneID:"legacy-pane",terminalID:"legacy-terminal",cliVersion:"fixture")
        let mixed = AgentProxyTeeFrame.Open(routeID:"mixed",upstream:"anthropic",method:"POST",path:"/v1/messages",headers:headers,routeIdentity:legacy,hcRouteIdentity:routeA)
        check(RequestClassification.classify(mixed,body:request).mainConversationKey == nil,"mixed tee scopes never select a legacy fallback")
        let capture = ConversationCaptureTests.Harness()
        try capture.json(.open,1,openA);try capture.request(1);try capture.head(1);try capture.answer(1,"core A response");try capture.end(1)
        try capture.json(.open,2,openB);try capture.request(2);try capture.head(2);try capture.answer(2,"core B response");try capture.end(2)
        let captured = capture.capture.reconciler.store.list()
        check(captured.count == 2 && Set(captured.compactMap { $0.key.hcCoreID }) == ["core-A","core-B"],"bounded tee ingestion keeps the same native ID separate across two hc origins")
        check(captured.contains(where:{ $0.context.hc?.binding == nil && $0.context.terminalID == nil }),"early captured request remains explicitly unbound")
        let selectedA = try ConversationReadAPITests.call("conversations.list",["hcCoreID":"core-A"],store:capture.capture.reconciler.store).result?.conversations ?? []
        check(selectedA.count == 1 && selectedA[0].herdrSession == nil && selectedA[0].origin?.value == "core-A","read API exposes explicit hc scope without fake legacy session")
        let pendingB = try ConversationReadAPITests.call("conversations.list",["hcCoreID":"core-B","hcLaunchID":intentB.launchID.uuidString],store:capture.capture.reconciler.store).result?.conversations ?? []
        check(pendingB.count == 1 && pendingB[0].terminalID == nil,"read API selects pending launch by exact core/nonce without guessing a terminal")
        check(try ConversationReadAPITests.call("conversations.list",["terminalID":"t1"],store:capture.capture.reconciler.store).result?.conversations?.isEmpty == true,"legacy unscoped terminal filter never adopts an hc record")
        check(try ConversationReadAPITests.call("conversations.list",["herdrSession":"core-A","hcCoreID":"core-A"],store:capture.capture.reconciler.store).error != nil,"mixed query namespaces are rejected")
        check(try ConversationReadAPITests.call("conversations.list",["hcLaunchID":intentA.launchID.uuidString],store:capture.capture.reconciler.store).error != nil,"launch query requires its explicit core")
        let snapshot = store.persistenceSnapshot()
        check(snapshot.schemaVersion == 2 && snapshot.records.allSatisfy({ $0.key.herdrSession == nil && $0.key.origin?.backend == .hc }),"v2 persistent hc keys do not contain fake legacy fields")
        var loaded = ConversationStore();_ = try loaded.restore(.decode(snapshot.encoded()))
        check(loaded.count == 2 && loaded.read(key:keyA)?.summary.context.hc == routeA,"v2 explicit hc context survives fresh epoch restore")
        var legacyStore = ConversationStore()
        _ = try legacyStore.upsert(key:keyOld,context:ConversationContext(routeID:"legacy",paneID:"w:p",terminalID:"legacy-terminal")!,items:[],status:.complete)
        var legacyJSON = try JSONSerialization.jsonObject(with:legacyStore.persistenceSnapshot().encoded()) as! [String:Any]
        legacyJSON["schemaVersion"] = 1
        var legacyLoaded = ConversationStore();_ = try legacyLoaded.restore(.decode(JSONSerialization.data(withJSONObject:legacyJSON)))
        check(legacyLoaded.read(key:keyOld) != nil,"old v1 archive is retained in its original namespace")
        var bad = try JSONSerialization.jsonObject(with:snapshot.encoded()) as! [String:Any]
        bad["schemaVersion"] = 1
        do { _ = try ConversationStore.PersistentSnapshot.decode(JSONSerialization.data(withJSONObject:bad));check(false,"v1 hc fields adopted") }
        catch { check(true,"v1 cannot be relabeled as a new hc archive") }
        bad["schemaVersion"] = 2
        var records = bad["records"] as! [[String:Any]], key = records[0]["key"] as! [String:Any]
        key["herdrSession"] = "core-A"; records[0]["key"] = key; bad["records"] = records
        var ambiguous = ConversationStore();let rejected = try ambiguous.restore(.decode(JSONSerialization.data(withJSONObject:bad)))
        check(rejected.rejectedRecordCount == 1 && ambiguous.count == 1,"mixed namespaces are rejected instead of choosing a fallback identity")
    }
}
