import Foundation

private enum Failure: Error { case assertion(String) }
@main @MainActor private struct HcGatewaySnapshotTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.assertion(label) }; checks += 1 }
    static func identity(_ id: String = "hub-id", _ name: String = "hub") throws -> CoreHello.Identity {
        try JSONDecoder().decode(CoreHello.Identity.self, from: JSONSerialization.data(withJSONObject:["id":id,"name":name]))
    }
    static func record(_ address: String) throws -> HcTerminalRecord {
        try JSONDecoder().decode(HcTerminalRecord.self, from: JSONSerialization.data(withJSONObject:["address":address,"state":"live"]))
    }
    static func rejects(_ kind: HcGatewaySnapshot.Failure, _ body: () throws -> Void) throws {
        do { try body(); throw Failure.assertion("accepted invalid gateway snapshot") }
        catch let error as HcGatewaySnapshot.Failure { try check(error == kind, "specific gateway failure") }
    }
    static func main() throws {
        let hub = try identity(), epoch = UUID()
        let a = HcGatewayMachine(id:"core-a",name:"before",state:"connected")
        let b = HcGatewayMachine(id:"core-b",name:"other",state:"needs_login")
        let snapshot = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[a,b],terminals:[record("t1"),record("before/t1"),record("other/t1"),record("before/deeper/t2")])
        let local = try snapshot.terminals(on:hub.id), selected = try snapshot.terminals(on:a.id)
        try check(local.count == 1 && selected.count == 1, "global list partitioned by same-reply metadata")
        try check(selected[0].reference == .init(coreID:a.id,terminalID:"t1"), "durable reference has permanent core/local canonical ID")
        try check(selected[0].routingAddress == "core-a/t1", "route does not persist display alias")
        try check(selected[0].observed.address == "before/t1", "observed record is not rewritten as fabricated direct provenance")
        try check(try snapshot.terminals(on:b.id).count == 1, "metadata state is not native readiness or ownership")
        try rejects(.unknownOrigin) { _ = try snapshot.terminals(on:"before") }
        try rejects(.unknownOrigin) { _ = try snapshot.terminals(on:"missing") }
        let renamed = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[.init(id:a.id,name:"after",state:"connected"),b],terminals:[record("after/t1"),record("other/t1")])
        try check(try renamed.terminals(on:a.id)[0].reference == selected[0].reference, "alias rename preserves origin reference")
        try check(try renamed.terminals(on:a.id)[0].routingAddress == selected[0].routingAddress, "alias rename preserves route selector")
        try rejects(.ambiguousSelector) {
            _ = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[.init(id:a.id,name:b.id,state:"connected"),b],terminals:[])
        }
        try rejects(.ambiguousSelector) {
            _ = try HcGatewaySnapshot(hub:identity("hub-id",a.id),epoch:epoch,machines:[a],terminals:[])
        }
        try rejects(.invalidMetadata) { _ = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[a,a],terminals:[]) }
        try rejects(.invalidMetadata) { _ = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[a,.init(id:b.id,name:a.name,state:"connected")],terminals:[]) }
        try rejects(.invalidMetadata) { _ = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[.init(id:"a/b",name:"other",state:"connected")],terminals:[]) }
        try rejects(.invalidMetadata) { _ = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[.init(id:a.id,name:"t7",state:"connected")],terminals:[]) }
        try rejects(.invalidAddress) {
            let s = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[a],terminals:[record("before/t0")]); _ = try s.terminals(on:a.id)
        }
        try rejects(.invalidAddress) {
            let s = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[a],terminals:[record("before/t1"),record("before/t1")]); _ = try s.terminals(on:a.id)
        }
        try rejects(.limit) { _ = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:Array(repeating:a,count:257),terminals:[]) }
        try rejects(.limit) { _ = try HcGatewaySnapshot(hub:hub,epoch:epoch,machines:[],terminals:Array(repeating:record("t1"),count:4097)) }
        for value in ["t1","t9","t10","t1b","t2z"] { try check(CoreTerminalID.isCanonical(value), "canonical generation-1 ID") }
        for value in ["t0","t01","ta","t1a","t1l","t1o","T1","before/t1","name","t9zzzzzzz", "t9999999999"] {
            try check(!CoreTerminalID.isCanonical(value), "mutable/invalid/out-of-range ID rejected")
        }
        var remoteEvents = CoreWorkspaceEvents(sequence: 0, remoteDocuments: true)
        let remoteNotice = Data("{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"seq\":1,\"type\":\"doc\",\"machine\":\"unrelated-alias\",\"data\":{\"name\":\"\(CoreWorkspaceDocument.documentName)\",\"version\":18446744073709551615}}}".utf8)
        let remoteEffect = try remoteEvents.consume(remoteNotice)
        try check(remoteEffect.refresh && remoteEffect.minimumVersion == nil, "foreign alias doc cannot advance selected origin's CAS version")
        let hubNotice = Data("{\"jsonrpc\":\"2.0\",\"method\":\"event\",\"params\":{\"seq\":2,\"type\":\"doc\",\"data\":{\"name\":\"\(CoreWorkspaceDocument.documentName)\",\"version\":99}}}".utf8)
        let hubEffect = try remoteEvents.consume(hubNotice)
        try check(!hubEffect.refresh && hubEffect.minimumVersion == nil, "hub doc is not selected remote doc")
        var cas = try CoreWorkspaceCAS(originCoreID: a.id, epoch: epoch)
        try cas.didSubscribe(coreID: a.id, epoch: epoch)
        let read = try cas.beginRead(); let version: UInt64 = 9007199254740999
        try cas.accept(read, version: version, document: nil)
        let write = try cas.beginWrite(CoreWorkspaceDocument())
        struct Parameters: Decodable { let on: String?; let version: UInt64 }
        let routed = try JSONDecoder().decode(Parameters.self, from: write.parameters(on: a.id))
        try check(routed.on == a.id && routed.version == version, "gateway CAS params retain exact UInt64 and permanent selector")
        let escaped = "opaque\"id\n"
        let encoded = try JSONDecoder().decode(Parameters.self, from: write.parameters(on: escaped))
        try check(encoded.on == escaped && encoded.version == version, "selector JSON encoding cannot inject params or round versions")
        try check(try JSONDecoder().decode(Parameters.self, from: write.parameters()).on == nil, "direct writes keep no on field")
        let report = URL(fileURLWithPath:CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject:["passed":true,"checks":checks,"mutationCapability":false]).write(to:report)
        print("PASS read-only gateway metadata policy: \(checks) checks")
    }
}
