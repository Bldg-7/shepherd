import Foundation

/// `PairedMacChecking` over SSH: `SSHHerdrTransport` to the address the
/// pairing resolved, held to the machine's address kind and pinned host key
/// like every connection to the Mac, logging in with the device's key, then
/// herdr's pane list over a direct-streamlocal channel to herdr.sock.
struct SSHPairedMacChecker: PairedMacChecking {
    /// For the key exchange and the login; the Mac waits a minute for the
    /// report of this and the herdr request together.
    var connectTimeout: Duration = .seconds(25)
    var herdrTimeout: Duration = .seconds(15)

    func check(_ machine: Machine, credential: Data, at address: PairingIPv4) async -> PairingConnectionCheck {
        let transport = SSHHerdrTransport(
            host: machine.hostname,
            port: machine.port,
            username: machine.username,
            credential: HostCredential(authMethod: machine.authMethod, secretData: credential),
            sessionName: machine.sessionName,
            pinnedFingerprint: machine.pinnedHostKeyFingerprint,
            addressKind: machine.addressKind,
            // Not looked up again: the address the pairing went to.
            addressResolver: PairingAddressResolver(resolver: ResolvedPairingName(address: address))
        )
        let client = HerdrClient(transport: transport)
        do {
            try await PairingDeadline.run(connectTimeout) { try await client.connect() }
        } catch {
            await client.disconnect()
            return PairingConnectionCheck(sshConnected: false, herdrReached: false, failure: Self.describe(error),
                                          keyRefused: (error as? PairedConnectionError) == .accessRemoved)
        }
        do {
            try await PairingDeadline.run(herdrTimeout) { _ = try await client.listPanes() }
        } catch {
            await client.disconnect()
            return PairingConnectionCheck(sshConnected: true, herdrReached: false, failure: Self.describe(error))
        }
        await client.disconnect()
        return PairingConnectionCheck(sshConnected: true, herdrReached: true)
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
