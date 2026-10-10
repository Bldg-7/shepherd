import Foundation

struct ProxyError: Error { init(_ message: String) {} }

@MainActor final class AutoAttachHarness {
    var sequence = 0
    var sent: [[String: Any]] = []
    lazy var transport = NativeCDPTransport(generation: 1, allocateID: {
        self.sequence += 1; return self.sequence
    }, sendMessage: { text in
        self.sent.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]); return true
    })
    func wait(_ count: Int) async {
        for _ in 0..<100 {
            if sent.count >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        fatalError("Missing native request")
    }
    func reply(_ index: Int, _ result: [String: Any] = [:]) {
        transport.receive(["id": sent[index]["id"]!, "result": result], generation: 1)
    }
}

@main struct CDPPageSessionStateTests {
    @MainActor static func main() async throws {
        let state = CDPPageSessionState()
        let automatic = CDPPageSessionState.Key(target: "page", kind: .automatic)
        let manual = CDPPageSessionState.Key(target: "page", kind: .manual)
        let oldEpoch = state.setAutoAttach(true)
        state.record("auto-page", for: automatic)
        state.record("manual-page", for: manual)
        state.setAutoAttach(false)
        assert(state.session(for: automatic) == nil)
        assert(state.session(for: manual) == "manual-page")
        assert(state.retiringAutomatic == ["auto-page"])
        let newEpoch = state.setAutoAttach(true)
        assert(newEpoch != oldEpoch && !state.canPublish(automatic, epoch: oldEpoch))
        assert(state.canPublish(manual, epoch: oldEpoch))
        assert(state.retiringAutomatic.contains("auto-page"))
        state.remove("auto-page")
        assert(state.session(for: manual) == "manual-page")
        print("PASS: disable invalidates auto routes/acquisition epoch, preserving independent manual ownership")

        let h = AutoAttachHarness(), owner = try h.transport.makeOwner()
        let pendingState = CDPPageSessionState(), epoch = pendingState.setAutoAttach(true)
        pendingState.acquiring.insert(automatic)
        let acquire = Task { () -> String? in
            defer { pendingState.acquiring.remove(automatic) }
            let result = try! await h.transport.call(owner, "Target.attachToTarget")
            let session = result["sessionId"] as! String
            if !pendingState.canPublish(automatic, epoch: epoch) {
                _ = try! await h.transport.call(owner, "Target.detachFromTarget", params: ["sessionId": session])
                return nil
            }
            pendingState.record(session, for: automatic)
            return session
        }
        await h.wait(1)
        pendingState.setAutoAttach(false)
        h.reply(0, ["sessionId": "late-auto"])
        await h.wait(2)
        assert(pendingState.hasAutomaticAcquisition)
        assert(pendingState.session(for: automatic) == nil)
        assert(h.sent[1]["method"] as? String == "Target.detachFromTarget")
        h.reply(1)
        let late = await acquire.value
        assert(late == nil && !pendingState.hasAutomaticAcquisition && owner.sessions.isEmpty)
        print("PASS: delayed automatic success is detached/acknowledged before acquisition retirement and never published")

        let h2 = AutoAttachHarness(), owner2 = try h2.transport.makeOwner()
        let auto = Task { try! await h2.transport.call(owner2, "Target.attachToTarget") }
        await h2.wait(1); h2.reply(0, ["sessionId": "auto"]); _ = await auto.value
        let explicit = Task { try! await h2.transport.call(owner2, "Target.attachToTarget") }
        await h2.wait(2); h2.reply(1, ["sessionId": "manual"]); _ = await explicit.value
        h2.transport.receive(["sessionId": "auto", "method": "Target.attachedToTarget", "params": ["sessionId": "old-child"]], generation: 1)
        h2.transport.receive(["sessionId": "old-child", "method": "Target.attachedToTarget", "params": ["sessionId": "old-grandchild"]], generation: 1)
        let detach = Task { try! await h2.transport.call(owner2, "Target.detachFromTarget", params: ["sessionId": "auto"]) }
        await h2.wait(3); h2.reply(2); _ = await detach.value
        assert(owner2.sessions == ["manual"])
        do { _ = try await h2.transport.call(owner2, "Runtime.evaluate", session: "old-grandchild"); fatalError("Retired descendant allowed") } catch {}
        let continuing = Task { try! await h2.transport.call(owner2, "Runtime.evaluate", session: "manual") }
        await h2.wait(4); h2.reply(3, ["value": "manual-alive"]); _ = await continuing.value
        print("PASS: auto page detach removes the native descendant tree without resetting the manual session")

        let h3 = AutoAttachHarness(), owner3 = try h3.transport.makeOwner()
        let first = Task { try! await h3.transport.call(owner3, "Target.attachToTarget") }
        await h3.wait(1); h3.reply(0, ["sessionId": "uncertain"]); _ = await first.value
        let failed = Task { try? await h3.transport.call(owner3, "Target.detachFromTarget", params: ["sessionId": "uncertain"]) }
        await h3.wait(2)
        h3.transport.receive(["id": h3.sent[1]["id"]!, "error": ["code": -32000]], generation: 1)
        let failure = await failed.value
        assert(failure == nil && owner3.state == .quarantined && owner3.sessions.contains("uncertain"))
        print("PASS: failed auto-session detach remains quarantined and cannot be acknowledged as success")
    }
}
