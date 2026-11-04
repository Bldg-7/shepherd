import Foundation
#if canImport(Citadel) && canImport(NIOSSH)
import Citadel
@preconcurrency import NIOSSH
import NIOCore

private nonisolated final class HcNoCredential: NIOSSHClientUserAuthenticationDelegate {
    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        nextChallengePromise.succeed(nil)
    }
}
#endif

extension MachineStore {
    /// Production single-backend factory. No legacy socket/fallback, browser,
    /// injected agent runtime, provider login, install or core stop. A private
    /// fixture may supply its own local transport; normal callers never do.
    /// Returned connections are owned by the screen and must be closed.
    public func makeHcConnection(for machine: Machine, localTransport: (any CoreByteTransport)? = nil,
                                 addressResolver: PairingAddressResolver = PairingAddressResolver()) async throws -> CoreRPCConnection {
        let current = try currentMachine(matching: machine)
        let session = try HcConnectionPolicy.session(current.sessionName)
        let transport: any CoreByteTransport
        if current.isLocal {
            #if os(macOS)
            if let localTransport { transport = localTransport }
            else {
                let home = HcExecutable.homeDirectory()
                let environment = try HcConnectionPolicy.localEnvironment(home: home, session: session, source: ProcessInfo.processInfo.environment)
                guard let binary = HcExecutable.resolve(candidates: HcExecutable.candidates(home: home, environment: environment)) else { throw HcConnectionPolicy.Failure.noExecutable }
                transport = try CoreProcessTransport(configuration: .init(executable: binary, environment: environment, directory: URL(fileURLWithPath: home)))
            }
            #else
            throw HcConnectionPolicy.Failure.localUnavailable
            #endif
        } else {
            guard localTransport == nil else { throw EditError.invalidFields }
            #if canImport(Citadel) && canImport(NIOSSH)
            // Resolve once, connect to that exact allowed IPv4. Never hand the
            // paired hostname back to NIO for a second, unchecked DNS lookup.
            let host: String
            if let kind = current.addressKind { host = try await addressResolver.resolve(hostname: current.hostname, kind: kind).description }
            else { host = current.hostname }
            try Task.checkCancellation()
            let fresh = try currentMachine(matching: current)
            guard fresh.pinnedHostKeyFingerprint == current.pinnedHostKeyFingerprint else { throw EditError.settingsChanged }
            let authentication: @Sendable () -> any NIOSSHClientUserAuthenticationDelegate
            if current.pinnedHostKeyFingerprint == nil {
                // Discovery is fail-closed. It cannot authenticate or execute;
                // no Keychain read until the user approved this fingerprint.
                authentication = { HcNoCredential() }
            } else {
                guard let bytes = try secret(for: fresh) else { throw EditError.missingCredential }
                let factory = try HostCredential(authMethod: current.authMethod, secretData: bytes).authenticationFactory(username: current.username)
                authentication = { factory() }
            }
            transport = CoreSSHTransport(configuration: try .init(host: host, port: current.port,
                pinnedFingerprint: current.pinnedHostKeyFingerprint, requestHostKeyApproval: current.pinnedHostKeyFingerprint == nil,
                discoverExecutable: true, session: session), authentication: authentication)
            #else
            throw HcConnectionPolicy.Failure.sshUnavailable
            #endif
        }
        let connection = try CoreRPCConnection(transport: transport, requiredMethods: HcConnectionPolicy.requiredMethods)
        do {
            _ = try await connection.connect()
            try Task.checkCancellation()
            let fresh = try currentMachine(matching: current)
            guard fresh.pinnedHostKeyFingerprint == current.pinnedHostKeyFingerprint else { throw EditError.settingsChanged }
            return connection
        } catch {
            try? await connection.close()
            throw error
        }
    }
}
