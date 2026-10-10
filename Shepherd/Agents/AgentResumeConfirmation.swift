import Foundation

/// Read-only confirmation boundary, independent of app/transport models.
///
/// Adapter contract: each fetch must obtain a fresh authoritative pane identity
/// and agent observation from the same qualified owner. Never return a cached row
/// or substitute a row selected only by terminal ID. Preserve pane identity even
/// when the agent/session is absent; throw if the pane cannot be verified. Map
/// compatibleSessionID using the existing sessionReference.resumeID(for:) policy,
/// not the raw reference value. Normalize kind using the existing AgentKind policy.
///
/// Boundedness is conditional on the adapter: fetch MUST honor the supplied
/// ContinuousClock deadline and task cancellation (including all underlying RPCs).
/// This helper awaits it inline, creates no child/unstructured tasks, and cannot
/// forcibly interrupt an uncooperative provider. A transport without bounded,
/// cancellation-aware fetch is not a conforming adapter. The optional synchronous
/// diagnostic callback must be nonblocking; it receives no session IDs/content.
nonisolated enum AgentResumeConfirmation {
    struct Identity: Equatable, Sendable {
        /// Stable machine/server namespace, including local versus remote owner.
        let ownerID: String
        let paneID: String
        let terminalID: String
    }

    struct Observation: Sendable {
        let identity: Identity
        /// Nil means no agent recognized yet; a different non-nil kind rejects.
        let kind: String?
        let interactiveReady: Bool
        let launchPending: Bool
        /// Already validated for compatibility with the expected agent kind.
        let compatibleSessionID: String?
    }

    enum Failure: Error, Equatable, Sendable {
        case invalidRequest
        case identityChanged
        case kindChanged
        case timedOut
    }

    enum State: Equatable, Sendable {
        case waitingForReadiness
        case waitingForSession
        case confirmed
        case identityChanged
        case kindChanged
    }

    enum SessionStatus: Equatable, Sendable { case absent, different, exact }

    struct Diagnostic: Sendable {
        let attempt: Int
        let elapsed: Duration
        let state: State
        let interactiveReady: Bool
        let launchPending: Bool
        let sessionStatus: SessionStatus
    }

    typealias Fetch = @Sendable (ContinuousClock.Instant) async throws -> Observation
    typealias Observer = @Sendable (Diagnostic) -> Void

    static func wait(
        identity: Identity,
        expectedKind: String,
        sessionID: String,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(250),
        fetch: Fetch,
        onObservation: Observer? = nil
    ) async throws -> Observation {
        try Task.checkCancellation()
        guard !identity.ownerID.isEmpty, !identity.paneID.isEmpty,
              !identity.terminalID.isEmpty, !expectedKind.isEmpty, !sessionID.isEmpty,
              timeout > .zero, pollInterval > .zero else { throw Failure.invalidRequest }
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: timeout)
        var attempt = 0
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.timedOut }
            let observation: Observation
            do {
                observation = try await fetch(deadline)
            } catch {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw Failure.timedOut }
                throw error
            }
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.timedOut }
            attempt += 1
            let state: State
            if observation.identity != identity {
                state = .identityChanged
            } else if let kind = observation.kind, kind != expectedKind {
                state = .kindChanged
            } else if observation.kind != expectedKind || !observation.interactiveReady || observation.launchPending {
                state = .waitingForReadiness
            } else if observation.compatibleSessionID != sessionID {
                state = .waitingForSession
            } else {
                state = .confirmed
            }
            let sessionStatus: SessionStatus = observation.compatibleSessionID == nil ? .absent
                : (observation.compatibleSessionID == sessionID ? .exact : .different)
            onObservation?(Diagnostic(attempt: attempt, elapsed: start.duration(to: clock.now), state: state,
                interactiveReady: observation.interactiveReady, launchPending: observation.launchPending,
                sessionStatus: sessionStatus))
            try Task.checkCancellation()
            guard clock.now < deadline else { throw Failure.timedOut }
            switch state {
            case .identityChanged: throw Failure.identityChanged
            case .kindChanged: throw Failure.kindChanged
            case .confirmed: return observation
            case .waitingForReadiness, .waitingForSession: break
            }
            try await clock.sleep(until: min(clock.now.advanced(by: pollInterval), deadline))
        }
    }
}
