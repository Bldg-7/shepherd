import Foundation
import AgentProxyProtocol

/// Forwarding metadata, never a terminal selector. No hc core/terminal value
/// can be projected into the legacy session/pane/terminal fields.
enum CaptureForwardRoute {
    case legacy(RouteTable.Entry)
    case hc(HcCaptureRouteJournal.Entry)
    var routeID: String {
        switch self { case .legacy(let entry):entry.routeID;case .hc(let entry):entry.routeID.uuidString.lowercased() }
    }
    var kind: AgentProxyRouteKind {
        switch self { case .legacy(let entry):entry.kind;case .hc(let entry):entry.state.kind }
    }
    var legacyIdentity: AgentProxyRouteCreate? {
        guard case .legacy(let entry) = self else { return nil }
        return .init(kind:entry.kind,session:entry.session,paneID:entry.paneID,terminalID:entry.terminalID,cliVersion:entry.cliVersion)
    }
    var hcIdentity: AgentProxyHcRouteState? { guard case .hc(let entry) = self else { return nil };return entry.state }
}

/// Owning proxy loop only. The legacy writer remains separate during cutover;
/// the shared forwarder consumes tagged metadata and never fabricates old IDs.
final class CaptureRouteRegistry {
    private let legacy: RouteTable
    private let hc: HcCaptureRouteJournal?
    var onAuthorityChanged: (() -> Void)?
    init(legacy: RouteTable, directory: StateDirectory, log: (String)->Void) {
        self.legacy = legacy
        do { hc = try HcCaptureRouteJournal(directory:directory) }
        catch { hc = nil;log("hc routes: stored provenance unavailable; no reset or adoption") }
        legacy.onAuthorityChanged = { [weak self] in self?.onAuthorityChanged?() }
    }
    var hcAvailable: Bool { hc.flatMap { try? $0.snapshot() } != nil }
    var count: Int { legacy.count + ((try? hc?.snapshot())?.count ?? 0) }
    func lookup(token: String) -> CaptureForwardRoute? {
        let old = legacy.lookup(token:token), current = try? hc?.lookup(token:token)
        switch (old,current) {
        case (.some(let entry),nil): return .legacy(entry)
        case (nil,.some(let entry)): return .hc(entry)
        default: return nil // ambiguous/missing metadata is not adopted
        }
    }
    func recorderAuthority() -> [AgentProxyTeeFrame.RouteSnapshot.Route] {
        legacy.recorderAuthority() + ((try? hc?.snapshot()) ?? []).filter { !$0.oauthRejected }.map {
            .init(routeID:$0.routeID.uuidString.lowercased(),hcIdentity:$0.state)
        }
    }
    private func journal() throws -> HcCaptureRouteJournal {
        guard let hc, hcAvailable else { throw HcCaptureRouteJournal.Failure.unavailable };return hc
    }
    private func mutate<T>(_ action: (HcCaptureRouteJournal)throws->T) throws -> T {
        let journal = try journal()
        do { let value = try action(journal);onAuthorityChanged?();return value }
        catch {
            if !hcAvailable { onAuthorityChanged?() } // revoke uncertain metadata, never retry
            throw error
        }
    }
    func createLegacy(_ request: AgentProxyRouteCreate) throws -> (entry:RouteTable.Entry,token:String) {
        guard count < RouteTable.maximumRoutes else { throw AgentProxyControlError(code:.unavailable,message:"Too many routes; remove the ones whose panes are gone.") }
        let made = try legacy.create(request)
        guard (try? hc?.lookup(token:made.token)) == nil else { throw AgentProxyControlError(code:.unavailable,message:"Route capability could not be confirmed; do not replay creation.") }
        return made
    }
    func createHc(_ state: AgentProxyHcRouteState) throws -> (entry:HcCaptureRouteJournal.Entry,token:String) {
        guard count < RouteTable.maximumRoutes else { throw HcCaptureRouteJournal.Failure.limit }
        return try mutate {
            let made = try $0.create(state)
            // A post-commit collision never returns a misleading capability or
            // replays the create. The durable intent remains for explicit review.
            guard legacy.lookup(token:made.token) == nil else { throw HcCaptureRouteJournal.Failure.unavailable }
            return made
        }
    }
    func bindHc(routeID: UUID, received: AgentProxyHcCaptureBinding) throws { try mutate { try $0.bind(routeID:routeID,received:received) } }
    func removeHc(routeID: UUID) throws { try mutate { try $0.remove(routeID:routeID) } }
    func listHc() throws -> [HcCaptureRouteJournal.Entry] { try journal().snapshot() }
    func markRejected(routeID: String, log: (String)->Void) {
        if let id = UUID(uuidString:routeID), (try? hc?.snapshot())?.contains(where:{ $0.routeID == id }) == true {
            do { try mutate { try $0.markRejected(routeID:id) } }
            catch { log("hc routes: subscription rejection persistence unavailable; no retry") }
        } else { legacy.markRejected(routeID:routeID,log:log) }
    }
}
