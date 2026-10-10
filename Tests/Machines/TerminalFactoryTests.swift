import Foundation
import NIOCore
import SwiftTerm

func connectionFailureDescription(_ error: any Error) -> String { "owned-factory-failure" }

actor OwnedTerminal: TerminalSessionProviding {
    var starts = 0
    var stops = 0
    private var continuation: AsyncStream<ByteBuffer>.Continuation?
    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer> {
        starts += 1
        return AsyncStream { continuation in
            self.continuation = continuation
            var first = ByteBuffer(); first.writeString("owned")
            continuation.yield(first)
        }
    }
    func write(_ data: Data) async throws {}
    func resize(columns: Int, rows: Int) async throws {}
    func stop() async { stops += 1; continuation?.finish(); continuation = nil }
}

@main @MainActor enum TerminalFactoryTests {
    enum Rejected: Error { case staleOrUnavailableCredential }
    static func main() async {
        var calls = 0
        var fails = true
        let terminal = OwnedTerminal()
        let view = TerminalView()
        let model = AgentTerminalViewModel(makeSession: {
            calls += 1
            if fails { throw Rejected.staleOrUnavailableCredential }
            return terminal
        })
        model.attach(terminalView: view)
        await model.start()
        guard case .failed("owned-factory-failure") = model.connectionState else { preconditionFailure("factory error must be visible") }
        precondition(view.bytes.isEmpty, "failure must not turn into canned terminal output")
        let failedStarts = await terminal.starts
        precondition(failedStarts == 0)
        fails = false
        await model.start()
        guard case .connected = model.connectionState else { preconditionFailure("retry should use fresh factory") }
        precondition(view.bytes == Array("owned".utf8))
        let connectedStarts = await terminal.starts
        precondition(connectedStarts == 1)
        model.stop()
        fails = true
        await model.start()
        guard case .failed = model.connectionState else { preconditionFailure("changed credential factory must fail closed") }
        let stops = await terminal.stops
        precondition(stops > 0, "old session must retire before next factory")
        let previousCalls = calls
        let cancelled = Task { @MainActor in await model.start() }
        cancelled.cancel()
        await cancelled.value
        precondition(calls == previousCalls, "cancelled task must not read credentials or make a session")
        model.stop()
        print("PASS terminal factory rejection, fresh retry, retired session and pre-cancel checks; no real terminal/network")
    }
}
