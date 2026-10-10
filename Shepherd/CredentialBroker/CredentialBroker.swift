import Foundation

actor CredentialBroker: CredentialAgentOperating, CredentialProxyConsuming {
    private struct Entry {
        let grant: HumanCredentialGrant
        let deadline: UInt64
        let revocation = CredentialRevocationLease()
        var state: CredentialState = .approved
        var binding: CredentialBinding?
        var ticket: CredentialRequestTicket?
        var invalidated = false
    }
    private struct TicketEntry {
        let handle: CredentialHandle
        let evidence: NativeCredentialRequestEvidence
        let deadline: UInt64
    }
    private let inspector: any CredentialElementInspecting
    private let clock: any CredentialMonotonicClock
    private let capacity: Int
    private var enabled = false
    private var provider: TrustedCredentialProviderLease?
    private var entries: [CredentialHandle: Entry] = [:]
    private var tickets: [CredentialRequestTicket: TicketEntry] = [:]
    private var usedRequests = Set<String>()

    init(inspector: any CredentialElementInspecting, clock: any CredentialMonotonicClock = CredentialSystemClock(), capacity: Int = 1024) {
        self.inspector = inspector; self.clock = clock; self.capacity = min(max(capacity, 1), 4096)
    }
    // Trusted lifecycle only; must run BEFORE selected provider lock/disconnect.
    func setAvailability(browserEnabled: Bool, provider: TrustedCredentialProviderLease?) {
        invalidateAll()
        enabled = browserEnabled; self.provider = provider
    }
    private func invalidateAll() {
        for key in Array(entries.keys) { invalidate(key) }
        tickets.removeAll()
    }
    private func invalidate(_ handle: CredentialHandle) {
        guard var entry = entries[handle] else { return }
        entry.revocation.revoke()
        entry.invalidated = true
        if entry.state != .consumed { entry.state = .revoked }
        if let ticket = entry.ticket { tickets.removeValue(forKey: ticket) }
        entries[handle] = entry
    }
    func revoke(owner: CredentialOwner) {
        for (key, entry) in entries where entry.grant.owner == owner { invalidate(key) }
    }
    func documentDetached(owner: CredentialOwner, pageID: String, frameID: String) {
        for (key, entry) in entries where entry.grant.owner == owner {
            if entry.binding == nil { invalidate(key) }
            else if let s = entry.binding?.snapshot, s.pageID == pageID && s.frameID == frameID { invalidate(key) }
        }
    }
    // Invoke periodically from app lifecycle; every operation also reaps. Retains
    // terminal status until original deadline, with fixed upper bound on memory.
    func reap() {
        let now = clock.nowNanoseconds()
        for (key, entry) in entries where now >= entry.deadline {
            entry.revocation.revoke()
            if let ticket = entry.ticket { tickets.removeValue(forKey: ticket) }
            entries.removeValue(forKey: key)
        }
        for (key, ticket) in tickets where now >= ticket.deadline { tickets.removeValue(forKey: key) }
        if entries.isEmpty { usedRequests.removeAll() }
    }
    func createHumanGrant(_ grant: HumanCredentialGrant) throws -> CredentialHandle {
        reap()
        guard enabled, let provider, provider.revocation.isValid, provider.epoch == grant.providerEpoch,
              provider.providerID == grant.reference.provider, provider.accountID == grant.reference.accountID else { throw CredentialBrokerError.unavailable }
        guard grant.lifetimeNanoseconds > 0, grant.lifetimeNanoseconds <= 300_000_000_000 else { throw CredentialBrokerError.denied }
        guard entries.count < capacity else { throw CredentialBrokerError.capacity }
        let (deadline, overflow) = clock.nowNanoseconds().addingReportingOverflow(grant.lifetimeNanoseconds)
        guard !overflow else { throw CredentialBrokerError.denied }
        let handle = CredentialHandle(opaqueID: try credentialOpaqueID())
        entries[handle] = Entry(grant: grant, deadline: deadline)
        return handle
    }
    private func live(_ handle: CredentialHandle, owner: CredentialOwner? = nil, allowConsumed: Bool = false) throws -> Entry {
        guard let entry = entries[handle], owner == nil || owner == entry.grant.owner else { throw CredentialBrokerError.denied }
        guard clock.nowNanoseconds() < entry.deadline else { throw CredentialBrokerError.expired }
        guard !entry.invalidated, enabled, provider?.revocation.isValid == true, provider?.epoch == entry.grant.providerEpoch else { throw CredentialBrokerError.cancelled }
        guard allowConsumed || entry.state != .consumed else { throw CredentialBrokerError.consumed }
        return entry
    }
    func status(_ handle: CredentialHandle, owner: CredentialOwner) throws -> CredentialState {
        guard let e = entries[handle], e.grant.owner == owner else { throw CredentialBrokerError.denied }
        if clock.nowNanoseconds() >= e.deadline { return e.state == .consumed ? .consumed : .expired }
        return e.state
    }
    func cancel(_ handle: CredentialHandle, owner: CredentialOwner) throws {
        guard entries[handle]?.grant.owner == owner else { throw CredentialBrokerError.denied }
        invalidate(handle)
    }
    private func checkSnapshot(_ snapshot: TrustedElementSnapshot, input: CredentialBindInput, owner: CredentialOwner) throws {
        guard snapshot.owner == owner, snapshot.pageID == input.pageID, snapshot.frameID == input.frameID,
              snapshot.backendNodeID == input.backendNodeID, snapshot.backendNodeID > 0,
              snapshot.engineGeneration > 0, snapshot.documentGeneration > 0, snapshot.executionContextGeneration > 0,
              !snapshot.browserID.isEmpty, snapshot.connected, snapshot.ordinaryForm,
              ["password", "text"].contains(snapshot.inputType), snapshot.name == input.requestField,
              snapshot.formDestination == input.destinationProposal,
              snapshot.origin == "https://" + input.destinationProposal.host + (input.destinationProposal.effectivePort == 443 ? "" : ":\(input.destinationProposal.effectivePort)"),
              !snapshot.value.isEmpty, snapshot.value.utf8.count <= 4096, !snapshot.value.utf8.contains(0)
        else { throw CredentialBrokerError.invalidElement }
    }
    func bind(_ input: CredentialBindInput, owner: CredentialOwner) async throws -> CredentialBindingID {
        let e = try live(input.handle, owner: owner)
        guard e.state == .approved, e.grant.destination == input.destinationProposal,
              input.requestField == e.grant.destination.field else { throw CredentialBrokerError.denied }
        let snapshot: TrustedElementSnapshot
        do { snapshot = try await inspector.snapshot(input, owner: owner) }
        catch { invalidate(input.handle); throw CredentialBrokerError.invalidElement }
        let current = try live(input.handle, owner: owner)
        guard current.state == .approved else { throw CredentialBrokerError.denied }
        do { try checkSnapshot(snapshot, input: input, owner: owner) }
        catch { invalidate(input.handle); throw CredentialBrokerError.invalidElement }
        // Initial subset allows only one live binding per document/frame:
        // multi-field substitutions cannot be attributed unambiguously yet.
        guard !entries.values.contains(where: {
            guard !$0.invalidated, let s = $0.binding?.snapshot else { return false }
            return s.owner == owner && s.pageID == snapshot.pageID && s.frameID == snapshot.frameID && s.documentGeneration == snapshot.documentGeneration
        }) else { throw CredentialBrokerError.denied }
        let id = CredentialBindingID(opaqueID: try credentialOpaqueID())
        let binding = CredentialBinding(id: id, input: input, snapshot: snapshot)
        try await revalidate(input.handle, binding: binding)
        guard entries[input.handle]?.state == .approved,
              !entries.values.contains(where: {
                  guard !$0.invalidated, let s = $0.binding?.snapshot else { return false }
                  return s.owner == owner && s.pageID == snapshot.pageID && s.frameID == snapshot.frameID && s.documentGeneration == snapshot.documentGeneration
              }) else { throw CredentialBrokerError.denied }
        entries[input.handle]?.binding = binding
        entries[input.handle]?.state = .bound
        return id
    }
    private func revalidate(_ handle: CredentialHandle, binding: CredentialBinding, allowConsumed: Bool = false) async throws {
        let snapshot: TrustedElementSnapshot
        do { snapshot = try await inspector.revalidate(binding) }
        catch { invalidate(handle); throw CredentialBrokerError.invalidElement }
        _ = try live(handle, allowConsumed: allowConsumed)
        guard snapshot == binding.snapshot else { invalidate(handle); throw CredentialBrokerError.invalidElement }
    }
    private func checkBody(_ body: Data, binding: CredentialBinding) throws {
        let fields = try CredentialForm.fields(body)
        guard fields.filter({ $0.0 == binding.input.requestField }).count == 1,
              fields.first(where: { $0.0 == binding.input.requestField })?.1 == binding.snapshot.value else { throw CredentialBrokerError.invalidRequest }
    }
    func authorizeRequest(_ evidence: NativeCredentialRequestEvidence, body: Data) async throws -> CredentialRequestTicket {
        reap()
        guard let (handle, e) = entries.first(where: { $0.value.binding?.id == evidence.bindingID }),
              e.state == .bound, e.grant.owner == evidence.owner, let binding = e.binding,
              binding.snapshot == evidence.snapshot, evidence.destination == e.grant.destination,
              !evidence.requestID.isEmpty, evidence.requestID.utf8.count <= 256,
              evidence.bodyDigest == NativeCredentialRequestEvidence.digest(body),
              !usedRequests.contains(evidence.requestID) else { throw CredentialBrokerError.invalidRequest }
        _ = try live(handle)
        try checkBody(body, binding: binding)
        try await revalidate(handle, binding: binding)
        guard entries[handle]?.state == .bound, !usedRequests.contains(evidence.requestID) else { throw CredentialBrokerError.denied }
        guard usedRequests.count < capacity else { throw CredentialBrokerError.capacity }
        let ticket = CredentialRequestTicket(opaqueID: try credentialOpaqueID())
        let now = clock.nowNanoseconds()
        let shortDeadline = now.addingReportingOverflow(10_000_000_000)
        guard !shortDeadline.overflow else { throw CredentialBrokerError.expired }
        tickets[ticket] = TicketEntry(handle: handle, evidence: evidence, deadline: min(e.deadline, shortDeadline.partialValue))
        usedRequests.insert(evidence.requestID)
        entries[handle]?.state = .authorized; entries[handle]?.ticket = ticket
        return ticket
    }
    func consumeRequest(_ ticket: CredentialRequestTicket, observed: CredentialObservedRequest, transport: any CredentialSecretTransport) async throws {
        guard let t = tickets[ticket], clock.nowNanoseconds() < t.deadline else { throw CredentialBrokerError.denied }
        let e = try live(t.handle)
        guard e.state == .authorized, e.ticket == ticket, let binding = e.binding else { throw CredentialBrokerError.invalidRequest }
        guard observed.destination == t.evidence.destination,
              NativeCredentialRequestEvidence.digest(observed.body) == t.evidence.bodyDigest else {
            invalidate(t.handle); throw CredentialBrokerError.invalidRequest
        }
        do { try checkBody(observed.body, binding: binding) }
        catch { invalidate(t.handle); throw CredentialBrokerError.invalidRequest }
        try await revalidate(t.handle, binding: binding)
        // Actor-atomic consume BEFORE async provider lookup. Never restore on failure.
        guard tickets.removeValue(forKey: ticket) != nil, entries[t.handle]?.state == .authorized,
              let provider, provider.revocation.isValid, provider.epoch == e.grant.providerEpoch else { throw CredentialBrokerError.consumed }
        entries[t.handle]?.state = .consumed
        do {
            try Task.checkCancellation()
            let secret = try await provider.resolver.resolveApprovedPassword(e.grant.reference)
            _ = try live(t.handle, allowConsumed: true)
            try Task.checkCancellation()
            try await revalidate(t.handle, binding: binding, allowConsumed: true)
            _ = try live(t.handle, allowConsumed: true)
            try Task.checkCancellation()
            // No await between final validity check and trusted transport start.
            let authorization = CredentialWriteAuthorization(provider: provider.revocation,
                grant: e.revocation, clock: clock, deadline: min(e.deadline, t.deadline))
            try transport.beginWrite(CredentialSecretLease(secret.bytes, authorization: authorization), request: observed)
        } catch {
            invalidate(t.handle)
            // Never propagate vendor/transport errors (may contain secret bytes).
            throw CredentialBrokerError.cancelled
        }
    }
}
