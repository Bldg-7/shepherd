import Foundation

extension MachineStore {
    /// A transport to `machine`'s herdr: this Mac's own socket, SSH with the
    /// machine's stored credential, or the stub in builds without Citadel.
    /// Missing or stale credentials never become a simulated successful connection.
    ///
    /// Throws when the machine's credential can't be read. That is not the
    /// same as there being none: the Keychain refuses reads for reasons that
    /// pass (the device being locked, for one), and the machine is as real
    /// as it was a moment ago.
    func makeHerdrTransport(for machine: Machine) throws -> any HerdrTransport {
        let current = try currentMachine(matching: machine)
        #if os(macOS)
        if current.isLocal {
            if let localSocketPath { return LocalHerdrTransport(socketPath: localSocketPath) }
            return LocalHerdrTransport()
        }
        #endif
        #if canImport(Citadel)
        if let secret = try secret(for: current) {
            let credential = HostCredential(authMethod: current.authMethod, secretData: secret)
            return SSHHerdrTransport(
                host: current.hostname,
                port: current.port,
                username: current.username,
                credential: credential,
                sessionName: current.sessionName,
                pinnedFingerprint: current.pinnedHostKeyFingerprint
            )
        }
        throw EditError.missingCredential
        #else
        return StubHerdrTransport()
        #endif
    }
}
