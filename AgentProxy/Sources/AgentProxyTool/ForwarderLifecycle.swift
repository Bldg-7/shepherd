import Foundation
import Darwin
import AgentProxyForwarder

/// Process lifecycle only. All mutable state is confined to this serial queue;
/// shutdown never runs on the server's NIO loop or concurrently with start().
nonisolated final class ForwarderLifecycle: @unchecked Sendable {
    private let queue = DispatchQueue(label:"com.bldg-7.shepherd.proxy-lifecycle")
    private let onExit: @Sendable (Int32) -> Void
    private let termination: any DispatchSourceSignal
    private var server: AgentProxyServer?
    private var finished = false
    init(onExit: @escaping @Sendable (Int32) -> Void) {
        self.onExit = onExit
        signal(SIGTERM,SIG_IGN)
        termination = DispatchSource.makeSignalSource(signal:SIGTERM,queue:queue)
        // Build the callback outside top-level MainActor inference. A signal
        // arriving on this queue must not call a MainActor-inherited closure.
        termination.setEventHandler { [weak self] in self?.requestStop(code:0) }
        termination.resume()
    }
    func start(_ server: AgentProxyServer) throws {
        try queue.sync {
            guard !finished else { throw AgentProxyStartError.alreadyRunning }
            self.server = server
            do { _ = try server.start() }
            catch {
                // Partial startup must retire only its own listener/recorder/
                // loop before the CLI reports failure. Do not let a queued
                // stop callback turn that startup error into a successful exit.
                server.shutdown(); self.server = nil; finished = true
                throw error
            }
        }
    }
    func requestStop(code: Int32) {
        queue.async { [self] in
            guard !finished else { return }
            finished = true
            let current = server; server = nil
            current?.shutdown()
            onExit(code)
        }
    }
}
