import Foundation

struct ProxyError: Error { init(_ message: String) {} }

@MainActor final class Harness {
    var id = 0
    var messages: [[String: Any]] = []
    lazy var transport = NativeCDPTransport(generation: 7, timeout: .milliseconds(80), allocateID: {
        self.id += 1; return self.id
    }, sendMessage: { text in
        self.messages.append(try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]); return true
    })
    func waitMessages(_ count: Int) async {
        for _ in 0..<100 { if messages.count >= count { return }; try? await Task.sleep(for: .milliseconds(2)) }
        fatalError("Missing native request")
    }
    func reply(_ index: Int, result: [String: Any] = [:], generation: UInt = 7) {
        transport.receive(["id": messages[index]["id"]!, "result": result], generation: generation)
    }
}

@main struct NativeCDPTransportTests {
    @MainActor static func main() async throws {
        let h = Harness(), owner = try h.transport.makeOwner()
        let attach = Task { try? await h.transport.call(owner, "Target.attachToTarget", params: ["targetId": "page", "flatten": true]) }
        await h.waitMessages(1)
        var retired = false
        h.transport.retire(owner) { retired = true }
        assert(!retired)
        h.reply(0, result: ["sessionId": "late-page"])
        await h.waitMessages(2)
        assert(h.messages[1]["method"] as? String == "Target.detachFromTarget")
        assert(!retired && owner.state == .retiring)
        h.reply(1)
        assert(retired && owner.state == .retired)
        let attachResult = await attach.value; assert(attachResult == nil)
        print("PASS: delayed attach after close compensates with acknowledged detach")

        let h2 = Harness(), o2 = try h2.transport.makeOwner()
        let a2 = Task { try? await h2.transport.call(o2, "Target.attachToTarget") }
        await h2.waitMessages(1)
        h2.reply(0, result: ["sessionId": "page"])
        _ = await a2.value
        let work = Task { try? await h2.transport.call(o2, "Runtime.evaluate", session: "page") }
        await h2.waitMessages(2)
        var done2 = false
        h2.transport.retire(o2) { done2 = true }
        await h2.waitMessages(3)
        h2.reply(2)
        assert(done2)
        let workResult = await work.value; assert(workResult == nil)
        h2.reply(1, result: ["stale": true])
        let replacement = try h2.transport.makeOwner()
        var events = 0
        replacement.events = { _ in events += 1 }
        h2.transport.receive(["sessionId": "page", "method": "Runtime.consoleAPICalled"], generation: 7)
        assert(events == 0)
        print("PASS: acknowledged page detach cancels pending work and filters stale events")

        let h3 = Harness(), o3 = try h3.transport.makeOwner()
        let a3 = Task { try? await h3.transport.call(o3, "Target.attachToTarget") }
        await h3.waitMessages(1)
        h3.reply(0, result: ["sessionId": "wrong-generation"], generation: 6)
        try await Task.sleep(for: .milliseconds(100))
        let timeoutResult = await a3.value; assert(o3.state == .quarantined && timeoutResult == nil)
        var done3 = false
        h3.transport.retire(o3) { done3 = true }
        h3.reply(0, result: ["sessionId": "late-timeout"])
        await h3.waitMessages(2)
        h3.reply(1)
        assert(!done3 && o3.state == .quarantined)
        assert(h3.messages[0]["id"] as! Int != h3.messages[1]["id"] as! Int)
        print("PASS: timeout retains acquisition/ID, cleans late success, and fails replacement closed")

        let h4 = Harness(), o4 = try h4.transport.makeOwner()
        let a4 = Task { try? await h4.transport.call(o4, "Target.attachToTarget") }
        await h4.waitMessages(1); h4.reply(0, result: ["sessionId": "page"]); _ = await a4.value
        var done4 = false
        h4.transport.retire(o4) { done4 = true }
        await h4.waitMessages(2)
        h4.transport.receive(["id": h4.messages[1]["id"]!, "error": ["code": -32000, "message": "uncertain"]], generation: 7)
        assert(!done4 && o4.state == .quarantined)
        print("PASS: failed detach is quarantined, never reported successfully retired")

        let h5 = Harness(), o5 = try h5.transport.makeOwner(), sibling = try h5.transport.makeOwner()
        let a5 = Task { try? await h5.transport.call(o5, "Target.attachToTarget") }
        await h5.waitMessages(1); h5.reply(0, result: ["sessionId": "gone"]); _ = await a5.value
        var done5 = false
        h5.transport.retire(o5) { done5 = true }; await h5.waitMessages(2)
        h5.transport.receive(["id": h5.messages[1]["id"]!, "error": ["code": -32001]], generation: 7)
        assert(done5 && sibling.state == .active)
        do { _ = try await h5.transport.call(sibling, "Target.setDiscoverTargets"); fatalError("Root discovery allowed") } catch {}
        do { _ = try await h5.transport.call(sibling, "Runtime.evaluate", session: "gone"); fatalError("Foreign session allowed") } catch {}
        print("PASS: already-gone detach retires only owner; global mutation and foreign sessions denied")
        h5.transport.invalidate()
        assert(sibling.state == .quarantined)
        do { _ = try h5.transport.makeOwner(); fatalError("Lost controller acquired") } catch {}
        print("PASS: controller loss invalidates all leases and blocks generation reuse")
        let exhausted = Harness(), exhaustedOwner = try exhausted.transport.makeOwner()
        exhausted.id = -1
        do { _ = try await exhausted.transport.call(exhaustedOwner, "Target.attachToTarget"); fatalError("Exhausted ID accepted") } catch {}
        assert(exhaustedOwner.state == .quarantined && exhausted.messages.isEmpty)
        print("PASS: exhausted native ID allocation fails closed without submission or reuse")
    }
}
