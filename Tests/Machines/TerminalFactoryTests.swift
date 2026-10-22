import Foundation
import NIOCore
import SwiftTerm

func connectionFailureDescription(_ error: any Error) -> String { "owned-factory-failure" }

actor OwnedTerminal: TerminalSessionProviding {
    var starts = 0
    var stops = 0
    /// Each write, as the attach would get it.
    var writes: [[UInt8]] = []
    private var continuation: AsyncStream<ByteBuffer>.Continuation?
    func start(columns: Int, rows: Int) async throws -> AsyncStream<ByteBuffer> {
        starts += 1
        return AsyncStream { continuation in
            self.continuation = continuation
            var first = ByteBuffer(); first.writeString("owned")
            continuation.yield(first)
        }
    }
    func write(_ data: Data) async throws { writes.append(Array(data)) }
    func resize(columns: Int, rows: Int) async throws {}
    func stop() async { stops += 1; continuation?.finish(); continuation = nil }
}

@main @MainActor enum TerminalFactoryTests {
    enum Rejected: Error { case staleOrUnavailableCredential }
    /// What the view model is told of the attach's herdr: 0.9.0 or later.
    static var takesEncodedPrefix = true
    static func main() async {
        var calls = 0
        var fails = true
        let terminal = OwnedTerminal()
        let view = TerminalView()
        let model = AgentTerminalViewModel(makeSession: {
            calls += 1
            if fails { throw Rejected.staleOrUnavailableCredential }
            return terminal
        }, takesEncodedPrefix: { takesEncodedPrefix })
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
        await writes(model, terminal)
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
        print("PASS terminal factory rejection, fresh retry, retired session and pre-cancel checks; the view model writes a Ctrl+B press twice (only 0x02 for herdr 0.8.2, asked at each write) and other bytes and pastes as they are, its paste state per attach; no real terminal/network")
    }

    /// The writes `terminal` has once it has `count` of them.
    static func waitForWrites(_ terminal: OwnedTerminal, count: Int) async -> [[UInt8]] {
        var yields = 0
        while await terminal.writes.count < count, yields < 10_000 {
            yields += 1
            await Task.yield()
        }
        return await terminal.writes
    }

    /// What the view model writes to the attach for what the terminal view
    /// sends (HerdrAttachInput): a Ctrl+B press herdr would take as its
    /// prefix twice, everything else as it is, a paste included.
    static func writes(_ model: AgentTerminalViewModel, _ terminal: OwnedTerminal) async {
        let csi: [UInt8] = [0x1b, 0x5b]
        let press = csi + Array("98;5u".utf8), release = csi + Array("98;5:3u".utf8)
        let start = csi + Array("200~".utf8), end = csi + Array("201~".utf8), text: [UInt8] = [0x61, 0x02, 0x71]
        let sends: [(sent: [UInt8], written: [UInt8])] = [
            ([0x02], [0x02, 0x02]),
            (Array("a".utf8), Array("a".utf8)),
            (press, press + press),
            (release, release),
            // SwiftTerm's ⌘V paste, in three writes, and a drop's, in one.
            (start, start), (text, text), (end, end),
            (start + text + end, start + text + end),
            (Array("é\u{2}".utf8), Array("é\u{2}\u{2}".utf8)),
        ]
        let before = await terminal.writes.count
        for send in sends { model.send(send.sent[...]) }
        let written = await waitForWrites(terminal, count: before + sends.count)
        precondition(Array(written.dropFirst(before)) == sends.map(\.written), "the view model writes \(sends.map(\.written)), not \(written.dropFirst(before))")
        // For a herdr older than 0.9.0, asked at each write: only 0x02 twice.
        takesEncodedPrefix = false
        model.send(press[...])
        model.send([0x02])
        takesEncodedPrefix = true
        model.send(press[...])
        let older = await waitForWrites(terminal, count: before + sends.count + 3)
        precondition(Array(older.suffix(3)) == [press, [0x02, 0x02], press + press], "for herdr 0.8.2 a kitty Ctrl+B is written once and 0x02 twice, and for 0.9 again twice: \(older.suffix(3))")
        // A paste left open when the attach ends doesn't carry over to the next one.
        model.send(start[...])
        model.stop()
        await model.start()
        guard case .connected = model.connectionState else { preconditionFailure("the attach starts again") }
        model.send([0x02])
        let again = await waitForWrites(terminal, count: before + sends.count + 5)
        precondition(again.last == [0x02, 0x02], "after a new attach, a Ctrl+B is written twice again, not as part of a paste")
    }
}
