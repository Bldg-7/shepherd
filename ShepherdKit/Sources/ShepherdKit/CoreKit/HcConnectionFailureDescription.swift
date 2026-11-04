import Foundation

/// Bounded public failure categories only: no server free-text, command lines,
/// provider replies or terminal content in connection errors.
public nonisolated func hcConnectionFailureDescription(_ error: any Error) -> String {
    if error is CancellationError { return "Connection canceled." }
    if let remote = error as? CoreRPCRemoteFailure {
        return "hc rejected the request (" + (remote.kind ?? String(remote.code)) + "). Nothing was automatically replayed."
    }
    if case CoreWire.Failure.unsupportedGeneration(let generation) = error {
        return "hc uses API generation \(generation); this app supports \(CoreWire.generation). Update Shepherd before connecting."
    }
    if case CoreWire.Failure.missingMethods = error {
        return "hc is missing required API methods. Update the core on the selected host, then retry. Installation does not authorize a core restart."
    }
    if case CoreWire.Failure.helloRejected = error {
        return "hc did not accept the protocol handshake. Check core/app compatibility and update the appropriate component."
    }
    #if canImport(NIOSSH) && canImport(Citadel) && canImport(Crypto)
    if case CoreSSHFailure.hostKeyMismatch = error { return "The SSH host key does not match the approved fingerprint. Connection refused; verify the host before changing its pin." }
    if case CoreSSHFailure.authenticationFailed = error { return "SSH authentication or key exchange failed. Verify the host, username, credential and Remote Login settings." }
    if case CoreSSHFailure.timedOut = error { return "The SSH host did not answer in time. Check its address, network and Remote Login, then retry." }
    #endif
    return "The hc connection or request could not be confirmed. Check the selected host, hc installation and connection settings, then retry after reviewing any unconfirmed operation."
}
