import Foundation
#if canImport(Citadel) && canImport(NIOSSH)
@preconcurrency import NIOSSH
#endif

extension MachineStore {
    /// Capture history belongs to the selected account's independent read-only
    /// socket. It never discovers sessions by a new hc ID, starts a proxy,
    /// connects to herdr.sock or grants browser authority.
    public func makeConversationByteTransport(for machine: Machine, endpoint: HerdrLineEndpoint,
                                             addressResolver: PairingAddressResolver = PairingAddressResolver()) async throws -> any CoreByteTransport {
        try Task.checkCancellation()
        let current = try currentMachine(matching: machine)
        if current.isLocal {
            #if os(macOS)
            let home = HcExecutable.homeDirectory()
            let path = try endpoint.path(home: home)
            let environment = ["PATH": "/usr/bin:/bin", "HOME": home, "LANG": "en_US.UTF-8"]
            return try CoreProcessTransport(configuration: .init(executable: URL(fileURLWithPath: "/usr/bin/nc"),
                arguments: ["-U", path], environment: environment, directory: URL(fileURLWithPath: home)))
            #else
            throw HcConnectionPolicy.Failure.localUnavailable
            #endif
        }
        // Preserve the existing paired-Mac-only remote capture contract.
        // Other SSH hosts can run hc, but no capture service is assumed there.
        guard current.authMethod == .secureEnclaveKey, let kind = current.addressKind,
              let pin = current.pinnedHostKeyFingerprint else { throw HerdrLineStreamError.unsupported }
        #if canImport(Citadel) && canImport(NIOSSH)
        let host = try await addressResolver.resolve(hostname: current.hostname, kind: kind).description
        try Task.checkCancellation()
        let fresh = try currentMachine(matching: current)
        guard fresh.pinnedHostKeyFingerprint == pin else { throw EditError.settingsChanged }
        guard let bytes = try secret(for: fresh) else { throw EditError.missingCredential }
        let authentication = try HostCredential(authMethod: fresh.authMethod, secretData: bytes).authenticationFactory(username: fresh.username)
        let config = try CoreSSHTransport.Configuration.conversationHistory(host: host, port: fresh.port,
            pinnedFingerprint: pin, debug: endpoint == .debugConversations)
        return CoreSSHTransport(configuration: config, authentication: authentication)
        #else
        throw HcConnectionPolicy.Failure.sshUnavailable
        #endif
    }
}
