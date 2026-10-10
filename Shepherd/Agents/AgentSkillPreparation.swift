import Foundation
import Observation

/// Preparation is app-private resource provisioning, not agent authentication
/// or proof that a running CLI has discovered a skill. Existing CLIs are never
/// restarted implicitly. One shared task serves every Settings window.
@MainActor @Observable
final class AgentSkillPreparation {
    enum State: Equatable {
        case off, waitingForHost, preparing, ready, stopping, failed(String)
    }
    private(set) var state: State = .off
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    var isBusy: Bool { operation != nil }

    func enable(prepare: (@MainActor () async throws -> Void)?) {
        guard state == .off || state == .waitingForHost else { return }
        guard let prepare else { state = .waitingForHost; return }
        generation &+= 1
        let epoch = generation
        state = .preparing
        operation = Task {
            let result: State
            do { try await prepare(); result = .ready }
            catch { result = .failed(error.localizedDescription) }
            guard generation == epoch else { return }
            state = result
            operation = nil
        }
    }

    func retry(prepare: (@MainActor () async throws -> Void)?) {
        guard operation == nil, state != .stopping else { return }
        state = .off
        enable(prepare: prepare)
    }

    func stop() async {
        generation &+= 1
        let epoch = generation
        state = .stopping
        // Drain the finite installer: cancellation of its shell is not proof
        // that an atomic copy or the owned Node process has stopped.
        await operation?.value
        guard generation == epoch else { return }
        operation = nil
        state = .off
    }
}
