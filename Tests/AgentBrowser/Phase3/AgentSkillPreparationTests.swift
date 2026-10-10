import Foundation

@MainActor private final class HeldPreparation {
    var calls = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func run() async {
        calls += 1
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume(); started = nil
        }
    }
    func waitForStart() async {
        if calls == 0 { await withCheckedContinuation { started = $0 } }
    }
    func finish() { pending?.resume(); pending = nil }
}

@main @MainActor struct AgentSkillPreparationTests {
    enum SyntheticFailure: Error { case failed }
    static func drain(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("preparation did not settle")
    }
    static func main() async {
        let state = AgentSkillPreparation()
        precondition(state.state == .off && !state.isBusy)
        state.enable(prepare: nil)
        precondition(state.state == .waitingForHost && !state.isBusy)
        let first = HeldPreparation()
        state.enable { await first.run() }
        state.enable { preconditionFailure("duplicate enable") }
        state.retry { preconditionFailure("retry while preparing") }
        await first.waitForStart()
        precondition(first.calls == 1 && state.state == .preparing && state.isBusy)
        first.finish()
        await drain { state.state == .ready }
        state.enable { preconditionFailure("ready preparation must be idempotent") }
        await state.stop()
        precondition(state.state == .off && !state.isBusy)

        let held = HeldPreparation()
        state.enable { await held.run() }
        await held.waitForStart()
        var stop: Task<Void, Never>!
        await withCheckedContinuation { entered in
            stop = Task { entered.resume(); await state.stop() }
        }
        precondition(state.state == .stopping && state.isBusy)
        state.enable { preconditionFailure("start during teardown") }
        held.finish()
        await stop.value
        precondition(state.state == .off && !state.isBusy) // no late Ready

        var failures = 0
        state.enable { failures += 1; throw SyntheticFailure.failed }
        await drain { if case .failed = state.state { return true }; return false }
        state.enable { preconditionFailure("no implicit retry loop") }
        precondition(failures == 1 && !state.isBusy)
        var retries = 0
        state.retry { retries += 1 }
        await drain { state.state == .ready }
        precondition(retries == 1)
        await state.stop()
        state.enable(prepare: nil)
        precondition(state.state == .waitingForHost)
        await state.stop()
        precondition(state.state == .off)
        print("PASS automatic skill preparation: OFF/default, host arrival, coalescing, ready idempotence, teardown drain, stale completion, explicit retry, no implicit retry")
    }
}
