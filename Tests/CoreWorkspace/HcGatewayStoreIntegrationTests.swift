import Foundation
import ShepherdKit

private nonisolated enum Failure: Error { case assertion(String) }
@main @MainActor private struct HcGatewayStoreIntegrationTests {
    static var checks = 0
    static func check(_ value: Bool, _ label: String) throws { guard value else { throw Failure.assertion(label) }; checks += 1 }
    static func params(_ value: [String:String]) throws -> Data { try JSONSerialization.data(withJSONObject:value) }
    static func main() async throws {
        let binary = URL(fileURLWithPath:CommandLine.arguments[1]), root = URL(fileURLWithPath:CommandLine.arguments[2])
        let report = URL(fileURLWithPath:CommandLine.arguments[3])
        var controls: [(CoreProcessTransport,CoreRPCConnection,CoreHello)] = []
        var stores: [CoreWorkspaceStore] = [], owned: [Int32] = [], failure: (any Error)?
        do {
            for name in ["h","r","q"] {
                let scope = try HcCoreBootstrap.Scope(root:root.appending(path:name))
                let connected = try await HcCoreBootstrap.connect(binary:binary,scope:scope)
                controls.append(connected)
                guard let pid = await connected.0.snapshot().childPID else { throw Failure.assertion("connect PID missing") }
                owned.append(pid)
            }
            let h = controls[0].1, r = controls[1].1, q = controls[2].1
            let aID = controls[1].2.core.id, bID = controls[2].2.core.id
            let directA = try await CoreWorkspaceStore(connection:r), directB = try await CoreWorkspaceStore(connection:q)
            let local = try await CoreWorkspaceStore(connection:h)
            let gatewayA = try await CoreWorkspaceStore(connection:h,gatewayCoreID:aID)
            let gatewayB = try await CoreWorkspaceStore(connection:h,gatewayCoreID:bID)
            stores = [directA,directB,local,gatewayA,gatewayB]
            for store in stores { _ = try await store.start() }
            let baseline = await gatewayA.view()
            try check(baseline.originCoreID == aID && baseline.epoch == h.epoch && baseline.canWrite && baseline.snapshot?.version == 0, "explicit remote document owner, actual hub transport epoch")
            try check(await h.hello?.core.id == controls[0].2.core.id, "never impersonates remote hello on hub connection")
            let docA = try CoreWorkspaceDocument(workspaces:[.init(name:"Owned origin A")])
            let docB = try CoreWorkspaceDocument(workspaces:[.init(name:"Owned origin B")])
            try check(try await gatewayA.commit(docA,expectedVersion:0) == .acknowledged(version:1), "gateway A CAS acknowledgement")
            let a = try await directA.refresh(), hub = try await local.refresh()
            try check(a.snapshot?.document == docA && a.snapshot?.version == 1, "write lands on actual origin A")
            try check(hub.snapshot?.document == nil && hub.snapshot?.version == 0, "gateway host document untouched")
            try check(try await directB.commit(docB,expectedVersion:0) == .acknowledged(version:1), "separate origin B baseline")
            _ = try await gatewayA.refresh(); _ = try await gatewayB.refresh()
            // Configuration collision is introduced only in these private cores.
            // Without preflight, on=bID would select A with matching version 1.
            _ = try await h.call("machine.rename",parameters:params(["machine":"owned-after","new_name":bID]))
            let attempted = try CoreWorkspaceDocument(workspaces:[.init(name:"Must never be written")])
            do { _ = try await gatewayB.commit(attempted,expectedVersion:1); throw Failure.assertion("ambiguous selector admitted") }
            catch CoreWorkspaceStoreFailure.originUnavailable { checks += 1 }
            let untouchedA = try await directA.refresh(), untouchedB = try await directB.refresh()
            try check(untouchedA.snapshot?.document == docA && untouchedA.snapshot?.version == 1, "blocked edit cannot overwrite wrong origin")
            try check(untouchedB.snapshot?.document == docB && untouchedB.snapshot?.version == 1, "blocked edit cannot overwrite selected origin")
            try check(await !gatewayB.view().canWrite, "cached remote document retires writable state on ambiguous metadata")
            _ = try await h.call("machine.rename",parameters:params(["machine":bID,"new_name":"owned-after"]))
            let recovered = try await gatewayB.refresh()
            try check(recovered.canWrite && recovered.snapshot?.document == docB && recovered.snapshot?.version == 1, "read retry after repair does not replay rejected mutation")
            for version in UInt64(1)...5 {
                _ = try await directB.refresh()
                try check(try await directB.commit(docB,expectedVersion:version) == .acknowledged(version:version+1), "foreign origin version increment")
            }
            let freshA = try await gatewayA.refresh()
            try check(freshA.snapshot?.document == docA && freshA.snapshot?.version == 1 && freshA.canWrite, "foreign doc versions never become selected origin's CAS floor")
        } catch { failure = error }
        for store in stores { do { try await store.close() } catch { failure = failure ?? error } }
        for (transport,rpc,_) in controls {
            do { try await rpc.close() } catch { failure = failure ?? error }
            do { try check(await transport.snapshot().reaped, "owned connect child reaped, daemon left to fixture owner") } catch { failure = failure ?? error }
        }
        try JSONSerialization.data(withJSONObject:["passed":failure == nil,"checks":checks,"ownedPIDs":owned,
            "failure":failure.map{String(describing:$0)} ?? "","productGatewayUIQualified":false]).write(to:report)
        if let failure { throw failure }
        print("PASS scoped gateway document SDK: \(checks) checks; not product gateway UI qualification")
    }
}
