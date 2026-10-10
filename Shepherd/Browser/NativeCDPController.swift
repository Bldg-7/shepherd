#if os(macOS)
import AppKit

/// Private, non-restored in-memory controller, outside BrowserStore's panes
/// and running-browser budget. Never exposed by the public target allowlist.
@MainActor final class NativeCDPController {
    static let shared = NativeCDPController()
    private var tab: BrowserTab?
    private var profile: BrowserProfile?
    private var observer: BrowserNativeLease?
    private var transport: NativeCDPTransport?
    private var generation: UInt = 0
    private var lostGeneration: UInt?
    private var watchTask: Task<Void, Never>?
    private var cleanupConfirmed = false

    func acquire() async throws -> (NativeCDPTransport, NativeCDPTransport.Owner) {
        guard ShepherdBrowserFeature.shared.isEnabled else { throw ProxyError("Shepherd Browser is disabled.") }
        try Task.checkCancellation()
        let current = BrowserEngine.generation
        guard BrowserEngine.isRunning, lostGeneration != current else { throw ProxyError("Native controller unavailable until engine restart.") }
        if generation != current { shutDown(); generation = current; cleanupConfirmed = false }
        if tab == nil {
            // Empty cache path is CEF's memory-only context. No controller
            // folder/cookies are restored or included in browsers.json.
            let profile = BrowserProfile(folder: "")
            self.profile = profile
            let made = BrowserTab(url: "about:blank")
            tab = made
            made.start(profile: profile, parent: BrowserStore.shared.holderView)
        }
        for _ in 0..<200 {
            try Task.checkCancellation()
            guard BrowserEngine.isRunning, generation == current, lostGeneration != current else { throw ProxyError("Native generation changed.") }
            if let page = tab?.page, tab?.cdpTargetID != nil {
                if transport == nil {
                    let native = page.makeNativeLease { [weak self] text in
                        guard let self, let data = text.data(using: .utf8),
                              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                        if message["nativeAgentDetached"] as? Bool == true { self.lostGeneration = current }
                        self.transport?.receive(message, generation: current)
                    }
                    observer = native
                    watchTask = Task { [weak self] in
                        while !Task.isCancelled {
                            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                            guard let self, self.generation == current else { return }
                            if self.tab?.page == nil || self.tab?.page?.isClosed == true {
                                self.lostGeneration = current; self.transport?.invalidate(); return
                            }
                        }
                    }
                    transport = NativeCDPTransport(generation: current, allocateID: { BrowserEngine.nextDevToolsMessageID() },
                        sendMessage: { [weak native] text in native?.sendMessage(text) ?? false })
                }
                guard let transport, !page.isClosed else { break }
                cleanupConfirmed = false
                return (transport, try transport.makeOwner())
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        lostGeneration = current; transport?.invalidate()
        throw ProxyError("Native controller did not become ready.")
    }

    #if DEBUG
    func delayNextAttachReplyForTest() {
        precondition(transport != nil)
        transport?.delayNextAttachReplyForTest = .milliseconds(400)
    }
    var deferredAttachRepliesForTest: Int { transport?.deferredAttachRepliesForTest ?? 0 }
    var delayedAttachDetachesAcknowledgedForTest: Int { transport?.delayedAttachDetachesAcknowledgedForTest ?? 0 }
    #endif

    /// Keep the trusted cleanup observer alive until all native detach replies
    /// have arrived. This synchronous bounded drain is used only during quit.
    func prepareForShutdown(within timeout: TimeInterval) -> Bool {
        guard lostGeneration != BrowserEngine.generation else {
            // Retry a page-close deadline only when inspector cleanup was
            // already acknowledged before intentionally closing the controller.
            return cleanupConfirmed && transport == nil
        }
        transport?.retireActiveOwners()
        let deadline = Date(timeIntervalSinceNow: timeout)
        while transport?.hasUnretiredOwners == true, transport?.failed == false, deadline.timeIntervalSinceNow > 0 {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        cleanupConfirmed = transport?.hasUnretiredOwners != true && transport?.failed != true
        return cleanupConfirmed
    }

    /// Called before CEF shutdown, releasing registrations and the page while
    /// the message pump still exists. Engine shutdown confirms all targets gone.
    func shutDown() {
        if BrowserEngine.isRunning { lostGeneration = generation }
        watchTask?.cancel(); watchTask = nil
        transport?.invalidate(); observer?.invalidate()
        observer = nil; transport = nil
        tab?.stop(force: true); tab = nil; profile = nil
    }
}
#endif
