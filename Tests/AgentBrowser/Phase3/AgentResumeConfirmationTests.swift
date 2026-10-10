import Foundation

private typealias Confirmation = AgentResumeConfirmation

private actor SequenceProvider {
    private var observations: [Confirmation.Observation]
    private(set) var calls = 0
    init(_ observations: [Confirmation.Observation]) { self.observations = observations }
    func next() -> Confirmation.Observation {
        calls += 1
        if observations.count > 1 { return observations.removeFirst() }
        return observations[0]
    }
}

private nonisolated final class Diagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [Confirmation.State] = []
    private var sessions: [Confirmation.SessionStatus] = []
    func record(_ value: Confirmation.Diagnostic) {
        lock.lock(); defer { lock.unlock() }
        states.append(value.state)
        sessions.append(value.sessionStatus)
    }
    func snapshot() -> [Confirmation.State] {
        lock.lock(); defer { lock.unlock() }
        return states
    }
    func sessionSnapshot() -> [Confirmation.SessionStatus] {
        lock.lock(); defer { lock.unlock() }
        return sessions
    }
}

@main
nonisolated struct AgentResumeConfirmationTests {
    private static let identity = Confirmation.Identity(ownerID: "owned-server", paneID: "pane", terminalID: "terminal")

    private static func observation(id: String?, identity: Confirmation.Identity = identity,
                            kind: String? = "codex", ready: Bool = true,
                            pending: Bool = false) -> Confirmation.Observation {
        .init(identity: identity, kind: kind, interactiveReady: ready,
              launchPending: pending, compatibleSessionID: id)
    }

    private static func run(_ provider: SequenceProvider, diagnostics: Diagnostics? = nil,
                    timeout: Duration = .milliseconds(35)) async throws -> Confirmation.Observation {
        try await Confirmation.wait(identity: identity, expectedKind: "codex", sessionID: "requested",
            timeout: timeout, pollInterval: .milliseconds(2), fetch: { _ in await provider.next() },
            onObservation: { value in diagnostics?.record(value) })
    }

    private static func expectFailure(_ expected: Confirmation.Failure,
                              _ operation: @Sendable () async throws -> Void) async throws {
        do { try await operation(); fatalError("Expected \(expected)") }
        catch let failure as Confirmation.Failure { precondition(failure == expected) }
    }

    static func main() async throws {
        let clock = ContinuousClock()
        let diagnostics = Diagnostics()
        let delayed = SequenceProvider([observation(id: nil), observation(id: "requested")])
        let confirmed = try await run(delayed, diagnostics: diagnostics)
        precondition(confirmed.compatibleSessionID == "requested")
        precondition(diagnostics.snapshot() == [.waitingForSession, .confirmed])
        precondition(diagnostics.sessionSnapshot() == [.absent, .exact])
        let delayedCalls = await delayed.calls
        precondition(delayedCalls == 2)
        print("PASS initially nil then exact ID")

        let temporaryWrong = SequenceProvider([observation(id: "wrong"), observation(id: "requested")])
        _ = try await run(temporaryWrong)
        print("PASS temporarily different ID then exact ID")

        for id in [nil, "wrong"] as [String?] {
            let provider = SequenceProvider([observation(id: id)])
            let trace = Diagnostics()
            let start = clock.now
            try await expectFailure(.timedOut) { _ = try await run(provider, diagnostics: trace) }
            let elapsed = start.duration(to: clock.now)
            precondition(elapsed >= .milliseconds(35) && elapsed < .seconds(1))
            precondition(!trace.snapshot().contains(.confirmed))
            precondition(trace.sessionSnapshot().allSatisfy { $0 == (id == nil ? .absent : .different) })
            let calls = await provider.calls
            precondition(calls > 1)
            print("PASS ready-but-\(id == nil ? "nil" : "wrong") timed out; \(elapsed), \(calls) fetches")
        }

        for changed in [
            Confirmation.Identity(ownerID: "other", paneID: "pane", terminalID: "terminal"),
            Confirmation.Identity(ownerID: "owned-server", paneID: "other", terminalID: "terminal"),
            Confirmation.Identity(ownerID: "owned-server", paneID: "pane", terminalID: "other")
        ] {
            try await expectFailure(.identityChanged) {
                _ = try await run(SequenceProvider([observation(id: "requested", identity: changed)]))
            }
        }
        try await expectFailure(.kindChanged) {
            _ = try await run(SequenceProvider([observation(id: "requested", kind: "claude")]))
        }
        print("PASS owner/pane/terminal/kind mismatch")

        for value in [observation(id: "requested", kind: nil),
                      observation(id: "requested", ready: false),
                      observation(id: "requested", pending: true)] {
            try await expectFailure(.timedOut) { _ = try await run(SequenceProvider([value])) }
        }
        print("PASS exact ID without kind/readiness or with pending never accepted")

        let cancelling = Task {
            try await Confirmation.wait(identity: identity, expectedKind: "codex", sessionID: "requested",
                timeout: .milliseconds(100), pollInterval: .milliseconds(2), fetch: { deadline in
                    try await clock.sleep(until: deadline)
                    return observation(id: "requested")
                })
        }
        try await Task.sleep(for: .milliseconds(5))
        let cancelStart = clock.now
        cancelling.cancel()
        do { _ = try await cancelling.value; fatalError("Cancellation accepted") }
        catch is CancellationError {}
        precondition(cancelStart.duration(to: clock.now) < .seconds(1))
        print("PASS cancellation during cooperative fetch")

        let sleeping = Task { try await run(SequenceProvider([observation(id: nil)]), timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(5))
        sleeping.cancel()
        do { _ = try await sleeping.value; fatalError("Cancellation accepted") }
        catch is CancellationError {}
        print("PASS cancellation during polling")

        try await expectFailure(.timedOut) {
            _ = try await Confirmation.wait(identity: identity, expectedKind: "codex", sessionID: "requested",
                timeout: .milliseconds(10), fetch: { deadline in
                    try await clock.sleep(until: deadline)
                    return observation(id: "requested")
                })
        }
        print("PASS fetch deadline exhaustion cannot accept late exact ID")

        enum FetchError: Error { case unavailable }
        do {
            _ = try await Confirmation.wait(identity: identity, expectedKind: "codex", sessionID: "requested",
                timeout: .milliseconds(20), fetch: { _ in throw FetchError.unavailable })
            fatalError("Fetch failure swallowed")
        } catch FetchError.unavailable {}
        try await expectFailure(.invalidRequest) {
            _ = try await run(SequenceProvider([observation(id: "requested")]), timeout: .zero)
        }
        print("PASS fetch errors propagate and invalid deadline rejects")
        print("AgentResumeConfirmationTests: all passed")
    }
}
