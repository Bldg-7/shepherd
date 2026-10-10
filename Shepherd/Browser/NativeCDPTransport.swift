#if os(macOS)
import Foundation

/// One trusted native dispatch registry per engine generation. Retiring owners
/// stay registered until every attach and detach is acknowledged. Observer
/// removal is never treated as inspector teardown.
@MainActor final class NativeCDPTransport {
    enum State { case active, retiring, quarantined, retired }
    final class Owner {
        let id = UUID()
        var state = State.active
        var sessions = Set<String>()
        var acquisitions = 0
        var events: (([String: Any]) -> Void)?
        var failed: (() -> Void)?
        var retired: (() -> Void)?
    }
    private struct Pending {
        let owner: Owner
        let method: String
        let detach: String?
        var continuation: CheckedContinuation<Data, Error>?
        var timer: Task<Void, Never>?
    }
    let generation: UInt
    private let allocateID: () -> Int
    private let sendMessage: (String) -> Bool
    private let timeout: Duration
    private var pending: [Int: Pending] = [:]
    private var owners: [UUID: Owner] = [:]
    private var sessionOwners: [String: Owner] = [:]
    private var sessionParents: [String: String] = [:]
    #if DEBUG
    var delayNextAttachReplyForTest: Duration?
    private(set) var deferredAttachRepliesForTest = 0
    private var delayedAttachSessionForTest: String?
    private(set) var delayedAttachDetachesAcknowledgedForTest = 0
    #endif
    private(set) var failed = false
    var hasUnretiredOwners: Bool { !owners.isEmpty }

    func retireActiveOwners() {
        for owner in Array(owners.values) where owner.state == .active { retire(owner) {} }
    }

    init(generation: UInt, timeout: Duration = .seconds(10), allocateID: @escaping () -> Int,
         sendMessage: @escaping (String) -> Bool) {
        self.generation = generation; self.timeout = timeout
        self.allocateID = allocateID; self.sendMessage = sendMessage
    }

    func makeOwner() throws -> Owner {
        guard !failed else { throw ProxyError("Native controller unavailable.") }
        let owner = Owner(); owners[owner.id] = owner; return owner
    }

    func call(_ owner: Owner, _ method: String, params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        guard owner.state == .active, !failed else { throw ProxyError("Native lease retired.") }
        // Only these trusted root operations exist. Agent browser-root commands
        // are virtualized before reaching here; global discovery is never set.
        if session == nil {
            guard ["Browser.getVersion", "Target.getTargets", "Target.attachToTarget", "Target.detachFromTarget"].contains(method) else {
                throw ProxyError("Native root method denied.")
            }
        } else if sessionOwners[session!] !== owner { throw ProxyError("Foreign native session.") }
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            submit(owner, method, params: params, session: session, continuation: continuation)
        }
        // Continuation storage transports immutable bytes, not an Any object
        // graph shared with the native receive callback across suspension.
        guard let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw ProxyError("Native reply encoding failed.")
        }
        return result
    }

    private func submit(_ owner: Owner, _ method: String, params: [String: Any], session: String? = nil,
                        continuation: CheckedContinuation<Data, Error>? = nil) {
        let id = allocateID()
        guard id > 0, pending[id] == nil, pending.count < 256, !failed else {
            continuation?.resume(throwing: ProxyError("Native pending limit.")); quarantine(owner); return
        }
        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let session { message["sessionId"] = session }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            continuation?.resume(throwing: ProxyError("Native encoding failed.")); return
        }
        let detach = method == "Target.detachFromTarget" ? params["sessionId"] as? String : nil
        if method == "Target.attachToTarget" { owner.acquisitions += 1 }
        pending[id] = Pending(owner: owner, method: method, detach: detach, continuation: continuation)
        pending[id]?.timer = Task { [weak self] in
            do { try await Task.sleep(for: self?.timeout ?? .seconds(10)) } catch { return }
            guard let self, var request = self.pending[id] else { return }
            request.continuation?.resume(throwing: ProxyError("Native response timeout."))
            request.continuation = nil; request.timer = nil; self.pending[id] = request
            // Keep uncertain acquisitions/detaches and their IDs in quarantine.
            // A late successful attach is still explicitly detached below.
            #if DEBUG
            NSLog("Native CDP timeout: %@ id=%d", request.method, id)
            #endif
            if request.method == "Target.attachToTarget" || request.detach != nil {
                self.quarantine(request.owner)
            } else {
                self.pending[id] = nil
                self.finishRetirement(request.owner)
            }
        }
        if !sendMessage(String(decoding: data, as: UTF8.self)) {
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timer?.cancel()
            request.continuation?.resume(throwing: ProxyError("Native submission failed."))
            if method == "Target.attachToTarget" { owner.acquisitions -= 1 }
            quarantine(owner)
        }
    }

    func receive(_ message: [String: Any], generation: UInt) {
        guard generation == self.generation, !failed else { return }
        if message["nativeAgentDetached"] as? Bool == true { invalidate(); return }
        if let id = message["id"] as? Int {
            #if DEBUG
            if pending[id]?.method == "Target.attachToTarget", let delay = delayNextAttachReplyForTest {
                delayNextAttachReplyForTest = nil
                deferredAttachRepliesForTest += 1
                delayedAttachSessionForTest = (message["result"] as? [String: Any])?["sessionId"] as? String
                Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self else { return }
                    deferredAttachRepliesForTest -= 1
                    self.receive(message, generation: generation)
                }
                return
            }
            #endif
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timer?.cancel()
            let owner = request.owner
            let error = message["error"] as? [String: Any]
            let result = message["result"] as? [String: Any] ?? [:]
            if request.method == "Target.attachToTarget" {
                owner.acquisitions -= 1
                if let session = result["sessionId"] as? String, error == nil {
                    owner.sessions.insert(session); sessionOwners[session] = owner
                    if owner.state != .active { detach(owner, session) }
                } else if error == nil { quarantine(owner) }
            }
            var detachAlreadyGone = false
            if let session = request.detach {
                let alreadyGone = error?["code"] as? Int == -32001 ||
                    (error?["message"] as? String == "No session with given id")
                detachAlreadyGone = alreadyGone
                #if DEBUG
                if session == delayedAttachSessionForTest, error == nil || alreadyGone {
                    delayedAttachDetachesAcknowledgedForTest += 1
                    delayedAttachSessionForTest = nil
                }
                #endif
                if error == nil || alreadyGone { removeSession(session, owner: owner) }
                else {
                    #if DEBUG
                    NSLog("Native CDP detach rejected code=%d", error?["code"] as? Int ?? 0)
                    #endif
                    quarantine(owner)
                }
            }
            if owner.state == .active {
                if error != nil && !detachAlreadyGone { request.continuation?.resume(throwing: ProxyError("Native command rejected.")) }
                else if let bytes = try? JSONSerialization.data(withJSONObject: result) {
                    request.continuation?.resume(returning: bytes)
                } else { request.continuation?.resume(throwing: ProxyError("Native reply encoding failed.")) }
            } else { request.continuation?.resume(throwing: ProxyError("Native lease retired.")) }
            finishRetirement(owner)
            return
        }
        guard let session = message["sessionId"] as? String, let owner = sessionOwners[session] else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        if message["method"] as? String == "Target.attachedToTarget", let child = params["sessionId"] as? String {
            sessionOwners[child] = owner
            sessionParents[child] = session
        }
        if message["method"] as? String == "Target.detachedFromTarget", let child = params["sessionId"] as? String {
            forgetNativeSession(child)
        }
        if owner.state == .active { owner.events?(message) }
    }

    func retire(_ owner: Owner, completion: @escaping () -> Void) {
        guard owner.state != .retired else { completion(); return }
        owner.retired = completion
        if owner.state == .active { owner.state = .retiring }
        owner.events = nil
        for id in Array(pending.keys) where pending[id]?.owner === owner {
            pending[id]?.continuation?.resume(throwing: ProxyError("Native lease retired."))
            pending[id]?.continuation = nil
            if pending[id]?.method != "Target.attachToTarget", pending[id]?.detach == nil {
                pending.removeValue(forKey: id)?.timer?.cancel()
            }
        }
        for session in owner.sessions { detach(owner, session) }
        finishRetirement(owner)
    }

    private func detach(_ owner: Owner, _ session: String) {
        guard !pending.values.contains(where: { $0.owner === owner && $0.detach == session }) else { return }
        submit(owner, "Target.detachFromTarget", params: ["sessionId": session])
    }

    private func forgetNativeSession(_ session: String) {
        for child in Array(sessionParents.keys) where sessionParents[child] == session { forgetNativeSession(child) }
        sessionParents[session] = nil
        sessionOwners[session] = nil
    }

    private func removeSession(_ session: String, owner: Owner) {
        owner.sessions.remove(session)
        forgetNativeSession(session)
    }

    private func finishRetirement(_ owner: Owner) {
        guard owner.state == .retiring, owner.sessions.isEmpty, owner.acquisitions == 0,
              !pending.values.contains(where: { $0.owner === owner }) else { return }
        owner.state = .retired; owners[owner.id] = nil
        let done = owner.retired; owner.retired = nil; done?()
    }

    private func quarantine(_ owner: Owner) {
        guard owner.state != .retired else { return }
        owner.state = .quarantined; owner.events = nil; owner.failed?()
    }

    func invalidate() {
        guard !failed else { return }
        failed = true
        for request in pending.values { request.timer?.cancel(); request.continuation?.resume(throwing: ProxyError("Native controller lost.")) }
        pending = [:]
        for owner in Array(owners.values) { quarantine(owner) }
    }
}
#endif
