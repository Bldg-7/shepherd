import Foundation

extension MachineStore {
    /// A transport to `machine`'s herdr: this Mac's own socket, SSH with the
    /// machine's stored credential, or — with no Citadel, or no credential
    /// on file — the stub, so that the UI flow stays testable either way.
    ///
    /// Throws when the machine's credential can't be read. That is not the
    /// same as there being none: the Keychain refuses reads for reasons that
    /// pass (the device being locked, for one), and the machine is as real
    /// as it was a moment ago.
    func makeHerdrTransport(for machine: Machine) throws -> any HerdrTransport {
        #if os(macOS)
        if machine.isLocal {
            if let localSocketPath { return LocalHerdrTransport(socketPath: localSocketPath) }
            return LocalHerdrTransport()
        }
        #endif
        #if canImport(Citadel)
        if let secret = try secret(for: machine) {
            let credential = HostCredential(authMethod: machine.authMethod, secretData: secret)
            return SSHHerdrTransport(
                host: machine.hostname,
                port: machine.port,
                username: machine.username,
                credential: credential,
                sessionName: machine.sessionName,
                pinnedFingerprint: machine.pinnedHostKeyFingerprint
            )
        }
        #endif
        return StubHerdrTransport()
    }
}
