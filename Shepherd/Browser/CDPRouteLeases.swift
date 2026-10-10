#if os(macOS)
import Foundation

/// A Pi reservation excludes the legacy unleased route for this pane until its
/// owner is explicitly released. Revocation never makes the legacy route usable.
@MainActor final class CDPRouteLeases {
    struct Claim: Equatable {
        let id: UUID
        let route: CDPRoute
        let terminalID: String
    }
    private struct State {
        let claim: Claim
        let authorize: () -> Bool
        var lease: String?
        var retired = false
    }
    private var claims: [String: State] = [:]
    private func key(_ route: CDPRoute) -> String { route.basePath }

    func claim(_ route: CDPRoute, terminalID: String, authorize: @escaping () -> Bool) throws -> Claim {
        guard route.leaseID == nil, !terminalID.isEmpty, claims[key(route)] == nil else { throw LeaseError.conflict }
        let claim = Claim(id: UUID(), route: route, terminalID: terminalID)
        claims[key(route)] = State(claim: claim, authorize: authorize)
        return claim
    }
    func open(_ claim: Claim) throws -> CDPRoute {
        guard var state = claims[key(claim.route)], state.claim == claim, !state.retired, state.lease == nil else { throw LeaseError.conflict }
        let id = UUID().uuidString.lowercased()
        state.lease = id; claims[key(claim.route)] = state
        return CDPRoute(claim.route.basePath + "/lease/" + id)!
    }
    func revoke(_ route: CDPRoute) {
        guard var state = claims[key(route)], let id = route.leaseID, state.lease == id else { return }
        state.lease = nil; claims[key(route)] = state
    }
    func retire(_ claim: Claim) {
        guard var state = claims[key(claim.route)], state.claim == claim else { return }
        state.lease = nil; state.retired = true; claims[key(claim.route)] = state
    }
    /// Caller must first prove no pending/retiring native work and exact owner disappearance.
    func release(_ claim: Claim) throws {
        guard let state = claims[key(claim.route)], state.claim == claim, state.retired, state.lease == nil else { throw LeaseError.conflict }
        claims[key(claim.route)] = nil
    }
    func permits(_ route: CDPRoute, terminalID: String) -> Bool {
        guard let state = claims[key(route)] else { return route.leaseID == nil }
        return !state.retired && state.claim.terminalID == terminalID && route.leaseID != nil && state.lease == route.leaseID && state.authorize()
    }
    enum LeaseError: Error { case conflict }
}
#endif
