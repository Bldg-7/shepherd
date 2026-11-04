import Foundation

/// Paired Mac health check over the new pinned SSH session/exec hc protocol.
/// The resolved numeric address is range-checked again, never re-resolved.
/// `herdrReached` remains the v1 pairing report's wire field for core health;
/// it no longer causes a legacy herdr socket request.
struct SSHPairedMacChecker: PairedMacChecking {
    var connectTimeout: Duration = .seconds(25)
    var herdrTimeout: Duration = .seconds(15)

    func check(_ machine: Machine, credential: Data, at address: PairingIPv4) async -> PairingConnectionCheck {
        var connection: CoreRPCConnection?
        var beganRPC = false
        do {
            guard let pin = machine.pinnedHostKeyFingerprint, let kind = machine.addressKind else { throw CoreSSHFailure.invalidConfiguration }
            _ = try PairingAddress(kind: kind, hostname: machine.hostname)
            guard kind.allows(address) else { throw PairingAddressResolutionError.noAddressInRange(kind, name: machine.hostname, found: [address]) }
            let factory = try HostCredential(authMethod: machine.authMethod, secretData: credential).authenticationFactory(username: machine.username)
            let transport = CoreSSHTransport(configuration: try .init(host: address.description, port: machine.port,
                pinnedFingerprint: pin, discoverExecutable: true, session: HcConnectionPolicy.session(machine.sessionName)), authentication: { factory() })
            let rpc = try CoreRPCConnection(transport: transport, requiredMethods: HcConnectionPolicy.requiredMethods)
            connection = rpc; beganRPC = true
            _ = try await PairingDeadline.run(connectTimeout) { try await rpc.connect() }
            _ = try await PairingDeadline.run(herdrTimeout) { try await HcTerminalBoard(connection: rpc).list() }
            try await rpc.close()
            return PairingConnectionCheck(sshConnected: true, herdrReached: true)
        } catch {
            try? await connection?.close()
            let sshReached = beganRPC && !(error is CoreSSHFailure) && !(error is PairingDeadline.Missed)
            return PairingConnectionCheck(sshConnected: sshReached, herdrReached: false, failure: Self.describe(error), keyRefused: false)
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case PairedConnectionError.accessRemoved:
            // Right after the Mac approved it, this isn't a removal: the
            // line may not have been written, and the Mac shows a command.
            String(localized: "The Mac turned this device's key down.")
        case is PairingDeadline.Missed:
            String(localized: "The Mac didn't answer in time.")
        default:
            connectionFailureDescription(error)
        }
    }
}

/// Runs work for at most a given time. The work is cancelled when the time
/// runs out, but not waited for: an SSH connection being made doesn't stop
/// at once.
nonisolated enum PairingDeadline {
    struct Missed: Error {}

    static func run<Value: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = Race<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                race.wait(with: continuation)
                let work = Task.detached {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                }
                Task.detached {
                    try? await Task.sleep(for: limit)
                    if race.finish(.failure(Missed())) { work.cancel() }
                }
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// Whichever of the work, the time limit and cancellation comes first.
    private final class Race<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, any Error>?
        private var early: Result<Value, any Error>?
        private var isFinished = false

        func wait(with continuation: CheckedContinuation<Value, any Error>) {
            lock.lock()
            if let early {
                lock.unlock()
                continuation.resume(with: early)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        @discardableResult
        func finish(_ result: Result<Value, any Error>) -> Bool {
            lock.lock()
            guard !isFinished else {
                lock.unlock()
                return false
            }
            isFinished = true
            let waiting = continuation
            continuation = nil
            if waiting == nil { early = result }
            lock.unlock()
            waiting?.resume(with: result)
            return true
        }
    }
}
